using System.Runtime.InteropServices;

namespace DshLeaseProbe;

/// <summary>
/// Unmanaged entry points and x64 structure constants used by the read-only lease probe.
/// </summary>
internal static class Native
{
    /// <summary>SystemExtendedHandleInformation (SYSTEM_INFORMATION_CLASS).</summary>
    internal const int SystemExtendedHandleInformation = 64;

    /// <summary>ObjectNameInformation (OBJECT_INFORMATION_CLASS).</summary>
    internal const int ObjectNameInformation = 1;

    /// <summary>STATUS_INFO_LENGTH_MISMATCH.</summary>
    internal const uint StatusInfoLengthMismatch = 0xC0000004;

    internal const uint ProcessDupHandle = 0x0040;
    internal const uint DuplicateSameAccess = 0x0002;

    /// <summary>STATUS_ACCESS_DENIED.</summary>
    internal const uint StatusAccessDenied = 0xC0000022;

    internal const uint TokenQuery = 0x0008;
    internal const int TokenIntegrityLevel = 25;

    /// <summary>SECURITY_MANDATORY_LOW_RID.</summary>
    internal const uint MandatoryLowRid = 0x1000;

    /// <summary>SECURITY_MANDATORY_MEDIUM_RID.</summary>
    internal const uint MandatoryMediumRid = 0x2000;

    /// <summary>sizeof(SYSTEM_HANDLE_TABLE_ENTRY_INFO_EX) on x64.</summary>
    internal const int HandleEntrySize = 40;

    /// <summary>Offset of the first entry: sizeof(SYSTEM_HANDLE_INFORMATION_EX header).</summary>
    internal const int HandleSnapshotHeaderSize = 16;

    // x64 offsets inside SYSTEM_HANDLE_TABLE_ENTRY_INFO_EX.
    internal const int EntryOffsetUniqueProcessId = 8;
    internal const int EntryOffsetHandleValue = 16;
    internal const int EntryOffsetObjectTypeIndex = 30;

    /// <summary>sizeof(UNICODE_STRING) on x64: USHORT Length, USHORT MaximumLength, PWSTR Buffer.</summary>
    internal const int UnicodeStringSize = 16;

    [DllImport("ntdll.dll", ExactSpelling = true)]
    internal static extern unsafe int NtQuerySystemInformation(
        int systemInformationClass,
        byte* buffer,
        int bufferLength,
        out uint returnLength);

    [DllImport("ntdll.dll", ExactSpelling = true)]
    internal static extern unsafe int NtQueryObject(
        IntPtr handle,
        int objectInformationClass,
        byte* buffer,
        int bufferLength,
        out uint returnLength);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, ExactSpelling = true, SetLastError = true)]
    internal static extern IntPtr CreateSemaphoreW(
        IntPtr semaphoreAttributes,
        int initialCount,
        int maximumCount,
        string? name);

    [DllImport("kernel32.dll", ExactSpelling = true, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool CloseHandle(IntPtr handle);

    [DllImport("kernel32.dll", ExactSpelling = true, SetLastError = true)]
    internal static extern IntPtr OpenProcess(
        uint desiredAccess,
        [MarshalAs(UnmanagedType.Bool)] bool inheritHandle,
        uint processId);

    [DllImport("kernel32.dll", ExactSpelling = true, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool DuplicateHandle(
        IntPtr sourceProcessHandle,
        IntPtr sourceHandle,
        IntPtr targetProcessHandle,
        out IntPtr targetHandle,
        uint desiredAccess,
        [MarshalAs(UnmanagedType.Bool)] bool inheritHandle,
        uint options);

    [DllImport("kernel32.dll", ExactSpelling = true)]
    internal static extern IntPtr GetCurrentProcess();

    [DllImport("advapi32.dll", ExactSpelling = true, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool OpenProcessToken(
        IntPtr processHandle,
        uint desiredAccess,
        out IntPtr tokenHandle);

    [DllImport("advapi32.dll", ExactSpelling = true, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern unsafe bool GetTokenInformation(
        IntPtr tokenHandle,
        int tokenInformationClass,
        byte* tokenInformation,
        int tokenInformationLength,
        out int returnLength);

    [DllImport("advapi32.dll", ExactSpelling = true)]
    internal static extern IntPtr GetSidSubAuthority(IntPtr sid, uint subAuthority);

    /// <summary>
    /// The current process integrity level RID (0x1000 = Low, 0x2000 = Medium, ...), or 0 when unknown.
    /// Only used to turn STATUS_ACCESS_DENIED into an actionable diagnostic.
    /// </summary>
    internal static unsafe uint IntegrityLevelRid()
    {
        if (!OpenProcessToken(GetCurrentProcess(), TokenQuery, out IntPtr token))
        {
            return 0;
        }

        try
        {
            byte* buffer = stackalloc byte[128];
            if (!GetTokenInformation(token, TokenIntegrityLevel, buffer, 128, out _))
            {
                return 0;
            }

            // TOKEN_MANDATORY_LABEL { SID_AND_ATTRIBUTES { PSID Sid; DWORD Attributes; } }
            IntPtr sid = *(IntPtr*)buffer;
            if (sid == IntPtr.Zero)
            {
                return 0;
            }

            IntPtr rid = GetSidSubAuthority(sid, 0);
            return rid == IntPtr.Zero ? 0 : (uint)Marshal.ReadInt32(rid);
        }
        finally
        {
            CloseHandle(token);
        }
    }
}
