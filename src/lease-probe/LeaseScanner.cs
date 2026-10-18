using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;

namespace DshLeaseProbe;

/// <summary>Raised when the probe cannot produce a trustworthy answer.</summary>
internal sealed class ProbeException : Exception
{
    internal ProbeException(string message) : base(message)
    {
    }
}

internal readonly record struct LeaseEntry(int Pid, string Hash);

internal sealed record ScanResult(
    long ScanMs,
    long Handles,
    long Semaphores,
    IReadOnlyList<LeaseEntry> Leases);

/// <summary>
/// Reproduces DSH's lease naming and performs a single read-only pass over the system handle table.
/// The probe never creates, waits on, acquires, releases or mutates any dsh-session-lock-* object.
/// </summary>
internal static class LeaseScanner
{
    private const string LeaseNamePrefix = "Local\\dsh-session-lock-";
    private const string LeaseNameMarker = "dsh-session-lock-";
    private const string ProbeNamePrefix = "Local\\dsh-lease-probe-";
    private const int HashHexLength = 64;
    private const int InitialSnapshotSize = 8 << 20;
    private const int MaxSnapshotSize = 256 << 20;
    private const int MaxSnapshotAttempts = 8;
    private const int ObjectNameBufferSize = 4096;

    /// <summary>
    /// DSH on win32 names its session write-lease semaphore exactly like this:
    /// <c>Local\dsh-session-lock-{sha256(lower(resolve(&lt;sessionDir&gt;\session.lock)))}</c>.
    /// </summary>
    internal static (string FullPath, string SemaphoreName) ResolveLease(string lockPath)
    {
        string fullPath = Path.GetFullPath(lockPath);
        string hash = Convert.ToHexString(
                SHA256.HashData(Encoding.UTF8.GetBytes(fullPath.ToLowerInvariant())))
            .ToLowerInvariant();
        return (fullPath, LeaseNamePrefix + hash);
    }

    internal static ScanResult Scan()
    {
        var stopwatch = Stopwatch.StartNew();

        // 1. Create our own throw-away named semaphore to learn the Semaphore ObjectTypeIndex.
        //    Initial count 0: the object is created but never signalable, and we never wait on it.
        string probeName = ProbeNamePrefix + Guid.NewGuid().ToString("N");
        IntPtr probeHandle = Native.CreateSemaphoreW(IntPtr.Zero, 0, 1, probeName);
        if (probeHandle == IntPtr.Zero)
        {
            throw new ProbeException(
                $"CreateSemaphoreW failed (Win32 error {Marshal.GetLastWin32Error()})");
        }

        byte[] snapshot;
        ulong handleCount;
        int semaphoreTypeIndex;
        try
        {
            // 2. One snapshot while our probe handle is alive, then locate that entry in it.
            snapshot = SnapshotHandles(out handleCount);
            semaphoreTypeIndex = FindObjectTypeIndex(
                snapshot,
                (ulong)Environment.ProcessId,
                (ulong)probeHandle.ToInt64());
        }
        finally
        {
            // Close immediately: the probe object is destroyed with its last handle.
            Native.CloseHandle(probeHandle);
        }

        if (semaphoreTypeIndex < 0)
        {
            throw new ProbeException("semaphore ObjectTypeIndex was not found in the handle snapshot");
        }

        // 3. Walk every entry of the snapshot; only entries whose ObjectTypeIndex matches a
        //    Semaphore are worth a name query. Every failure is skipped silently.
        long semaphoreCount = 0;
        var leases = new Dictionary<(int Pid, string Hash), bool>();
        for (ulong i = 0; i < handleCount; i++)
        {
            long offset = Native.HandleSnapshotHeaderSize + (long)i * Native.HandleEntrySize;
            if (offset + Native.HandleEntrySize > snapshot.Length)
            {
                break;
            }

            int entryTypeIndex = BitConverter.ToUInt16(
                snapshot, (int)(offset + Native.EntryOffsetObjectTypeIndex));
            if (entryTypeIndex != semaphoreTypeIndex)
            {
                continue;
            }

            semaphoreCount++;
            ulong pid = BitConverter.ToUInt64(
                snapshot, (int)(offset + Native.EntryOffsetUniqueProcessId));
            ulong handleValue = BitConverter.ToUInt64(
                snapshot, (int)(offset + Native.EntryOffsetHandleValue));
            if (pid > int.MaxValue)
            {
                continue;
            }

            string? objectName = TryQueryObjectName(pid, handleValue);
            if (objectName is null)
            {
                continue;
            }

            string? hash = ExtractLeaseHash(objectName);
            if (hash is null)
            {
                continue;
            }

            leases[((int)pid, hash)] = true;
        }

        stopwatch.Stop();
        var ordered = leases.Keys
            .OrderBy(key => key.Pid)
            .ThenBy(key => key.Hash, StringComparer.Ordinal)
            .Select(key => new LeaseEntry(key.Pid, key.Hash))
            .ToArray();

        return new ScanResult(
            ScanMs: (long)Math.Round(stopwatch.Elapsed.TotalMilliseconds),
            Handles: (long)handleCount,
            Semaphores: semaphoreCount,
            Leases: ordered);
    }

    private static string DescribeSnapshotFailure(uint status)
    {
        var message = new StringBuilder();
        message.Append("NtQuerySystemInformation(SystemExtendedHandleInformation) failed with NTSTATUS 0x");
        message.Append(status.ToString("X8"));
        if (status == Native.StatusAccessDenied)
        {
            uint integrity = Native.IntegrityLevelRid();
            message.Append(" (STATUS_ACCESS_DENIED; process integrity level = ");
            message.Append(DescribeIntegrity(integrity));
            message.Append("). The handle-table query requires Medium integrity or higher. ");
            message.Append("This happens when the executable is launched from a Low-integrity-labelled ");
            message.Append("(sandboxed) workspace tree: a Low-labelled image runs at Low integrity no matter ");
            message.Append("who launches it. Run the probe from a normal folder (for example the install ");
            message.Append("directory under %LOCALAPPDATA%) or relabel the artifact: icacls \"");
            message.Append(Environment.ProcessPath ?? "DshLeaseProbe.exe");
            message.Append("\" /setintegritylevel Medium");
        }
        else if (status == Native.StatusInfoLengthMismatch)
        {
            message.Append(" (STATUS_INFO_LENGTH_MISMATCH)");
        }
        else if (status == Native.StatusInfoLengthMismatch)
        {
            message.Append(" (STATUS_INFO_LENGTH_MISMATCH)");
        }

        return message.ToString();
    }

    private static string DescribeIntegrity(uint rid) => rid switch
    {
        0 => "unknown",
        Native.MandatoryLowRid => "Low S-1-16-4096",
        Native.MandatoryMediumRid => "Medium S-1-16-8192",
        _ => $"S-1-16-{rid:X}",
    };

    private static unsafe byte[] SnapshotHandles(out ulong handleCount)
    {
        bool debug = Environment.GetEnvironmentVariable("DSH_LEASE_PROBE_DEBUG") == "1";
        int size = InitialSnapshotSize;
        for (int attempt = 0; attempt < MaxSnapshotAttempts; attempt++)
        {
            byte[] buffer = new byte[size];
            uint returnLength;
            int status;
            fixed (byte* pointer = buffer)
            {
                status = Native.NtQuerySystemInformation(
                    Native.SystemExtendedHandleInformation, pointer, size, out returnLength);
            }

            if (debug)
            {
                Console.Error.WriteLine(
                    $"[lease-probe] NtQuerySystemInformation attempt={attempt + 1} size={size} status=0x{(uint)status:X8} returnLength={returnLength}");
            }

            if (status == 0)
            {
                handleCount = BitConverter.ToUInt64(buffer, 0);
                return buffer;
            }

            if ((uint)status != Native.StatusInfoLengthMismatch)
            {
                throw new ProbeException(DescribeSnapshotFailure((uint)status));
            }

            long required = Math.Max((long)returnLength + 65536, (long)size * 2);
            if (required > MaxSnapshotSize)
            {
                throw new ProbeException(
                    $"handle snapshot would exceed {MaxSnapshotSize >> 20} MiB; refusing to allocate");
            }

            size = (int)required;
        }

        throw new ProbeException(
            $"handle snapshot buffer growth failed after {MaxSnapshotAttempts} attempts");
    }

    private static int FindObjectTypeIndex(byte[] snapshot, ulong pid, ulong handleValue)
    {
        ulong count = BitConverter.ToUInt64(snapshot, 0);
        for (ulong i = 0; i < count; i++)
        {
            long offset = Native.HandleSnapshotHeaderSize + (long)i * Native.HandleEntrySize;
            if (offset + Native.HandleEntrySize > snapshot.Length)
            {
                break;
            }

            if (BitConverter.ToUInt64(snapshot, (int)(offset + Native.EntryOffsetUniqueProcessId)) != pid)
            {
                continue;
            }

            if (BitConverter.ToUInt64(snapshot, (int)(offset + Native.EntryOffsetHandleValue)) != handleValue)
            {
                continue;
            }

            return BitConverter.ToUInt16(snapshot, (int)(offset + Native.EntryOffsetObjectTypeIndex));
        }

        return -1;
    }

    private static IntPtr OpenForDup(ulong pid)
    {
        return Native.OpenProcess(Native.ProcessDupHandle, false, (uint)pid);
    }

    private static unsafe string? TryQueryObjectName(ulong pid, ulong handleValue)
    {
        IntPtr processHandle = OpenForDup(pid);
        if (processHandle == IntPtr.Zero)
        {
            return null;
        }

        try
        {
            IntPtr duplicated;
            if (!Native.DuplicateHandle(
                    processHandle,
                    new IntPtr(unchecked((long)handleValue)),
                    Native.GetCurrentProcess(),
                    out duplicated,
                    0,
                    false,
                    Native.DuplicateSameAccess))
            {
                return null;
            }

            try
            {
                return QueryObjectName(duplicated);
            }
            finally
            {
                Native.CloseHandle(duplicated);
            }
        }
        finally
        {
            Native.CloseHandle(processHandle);
        }
    }

    private static unsafe string? QueryObjectName(IntPtr handle)
    {
        byte[] buffer = new byte[ObjectNameBufferSize];
        uint returnLength;
        int status;
        fixed (byte* pointer = buffer)
        {
            status = Native.NtQueryObject(
                handle, Native.ObjectNameInformation, pointer, buffer.Length, out returnLength);
        }

        if (status != 0)
        {
            return null;
        }

        int byteLength = BitConverter.ToUInt16(buffer, 0);
        if (byteLength == 0)
        {
            return string.Empty;
        }

        if ((byteLength & 1) != 0)
        {
            return null;
        }

        // OBJECT_NAME_INFORMATION { UNICODE_STRING Name; WCHAR NameBuffer[]; }
        // On x64 the character data normally starts at +16 and Buffer points there.
        long namePointer = (long)BitConverter.ToUInt64(buffer, 8);
        int charCount = byteLength / 2;
        if (namePointer != 0 && charCount <= (buffer.Length - Native.UnicodeStringSize) / 2)
        {
            return Marshal.PtrToStringUni(new IntPtr(namePointer), charCount);
        }

        if (byteLength <= buffer.Length - Native.UnicodeStringSize)
        {
            return Encoding.Unicode.GetString(buffer, Native.UnicodeStringSize, byteLength);
        }

        return null;
    }

    private static string? ExtractLeaseHash(string objectName)
    {
        int marker = objectName.LastIndexOf(LeaseNameMarker, StringComparison.OrdinalIgnoreCase);
        if (marker < 0)
        {
            return null;
        }

        int start = marker + LeaseNameMarker.Length;
        if (objectName.Length - start != HashHexLength)
        {
            return null;
        }

        Span<char> hash = stackalloc char[HashHexLength];
        for (int i = 0; i < HashHexLength; i++)
        {
            char c = char.ToLowerInvariant(objectName[start + i]);
            if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')))
            {
                return null;
            }

            hash[i] = c;
        }

        return new string(hash);
    }
}
