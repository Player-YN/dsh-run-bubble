using System.Text;
using System.Text.Json;

namespace DshLeaseProbe;

internal static class Program
{
    internal const string ProductVersion = "0.3.0";

    private const string HelpText =
        "DshLeaseProbe " + ProductVersion + " - read-only Windows kernel-object probe for DSH session write leases.\n" +
        "\n" +
        "Usage:\n" +
        "  DshLeaseProbe.exe                 Full scan: list every live Local\\dsh-session-lock-* lease.\n" +
        "  DshLeaseProbe.exe --lock <path>   Probe one session.lock path (repeatable).\n" +
        "  DshLeaseProbe.exe --json          Force JSON output (JSON is already the default).\n" +
        "  DshLeaseProbe.exe --help          Show this help.\n" +
        "  DshLeaseProbe.exe --version       Show the version.\n" +
        "\n" +
        "stdout: exactly one line of UTF-8 JSON on success or failure. stderr: diagnostics only.\n" +
        "Exit code: 0 on success, 1 on failure ({\"ok\":false,\"error\":\"...\"}).\n" +
        "The probe is read-only: it never creates, waits on, acquires or releases any\n" +
        "dsh-session-lock-* object; only its own temporary probe semaphore is created and closed.\n";

    private static int Main(string[] args)
    {
        if (!Environment.Is64BitProcess)
        {
            WriteFailure(
                "DshLeaseProbe requires a 64-bit process (x64); the handle-table structure layout is x64-only.");
            return 1;
        }

        var lockPaths = new List<string>();
        bool wantHelp = false;
        bool wantVersion = false;

        for (int i = 0; i < args.Length; i++)
        {
            string argument = args[i];
            switch (argument)
            {
                case "--help":
                case "-h":
                case "-?":
                    wantHelp = true;
                    break;
                case "--version":
                case "-V":
                    wantVersion = true;
                    break;
                case "--json":
                    break;
                case "--lock":
                    if (i + 1 >= args.Length)
                    {
                        WriteFailure("--lock requires a path argument");
                        return 1;
                    }

                    lockPaths.Add(args[++i]);
                    break;
                default:
                    if (argument.StartsWith("--lock=", StringComparison.Ordinal))
                    {
                        string value = argument["--lock=".Length..];
                        if (value.Length == 0)
                        {
                            WriteFailure("--lock requires a path argument");
                            return 1;
                        }

                        lockPaths.Add(value);
                    }
                    else
                    {
                        WriteFailure($"unknown argument: {argument}");
                        return 1;
                    }

                    break;
            }
        }

        if (wantHelp)
        {
            Console.Out.Write(HelpText);
            Console.Out.Flush();
            return 0;
        }

        if (wantVersion)
        {
            Console.Out.Write($"DshLeaseProbe {ProductVersion}\n");
            Console.Out.Flush();
            return 0;
        }

        try
        {
            return lockPaths.Count > 0 ? RunLockProbe(lockPaths) : RunFullScan();
        }
        catch (ProbeException exception)
        {
            WriteFailure(exception.Message);
            return 1;
        }
        catch (Exception exception)
        {
            WriteFailure($"{exception.GetType().Name}: {exception.Message}");
            return 1;
        }
    }

    private static int RunFullScan()
    {
        ScanResult scan = LeaseScanner.Scan();
        EmitJson(writer =>
        {
            writer.WriteBoolean("ok", true);
            writer.WriteNumber("scanMs", scan.ScanMs);
            writer.WriteNumber("handles", scan.Handles);
            writer.WriteNumber("semaphores", scan.Semaphores);
            writer.WriteStartArray("leases");
            foreach (LeaseEntry lease in scan.Leases)
            {
                writer.WriteStartObject();
                writer.WriteNumber("pid", lease.Pid);
                writer.WriteString("hash", lease.Hash);
                writer.WriteString("name", "Local\\dsh-session-lock-" + lease.Hash);
                writer.WriteEndObject();
            }

            writer.WriteEndArray();
        });
        return 0;
    }

    private static int RunLockProbe(List<string> lockPaths)
    {
        var resolved = new (string FullPath, string SemaphoreName)[lockPaths.Count];
        for (int i = 0; i < lockPaths.Count; i++)
        {
            string lockPath = lockPaths[i];
            try
            {
                resolved[i] = LeaseScanner.ResolveLease(lockPath);
            }
            catch (Exception exception) when (exception is ArgumentException
                                                  or NotSupportedException
                                                  or PathTooLongException)
            {
                throw new ProbeException($"invalid lock path '{lockPath}': {exception.Message}");
            }
        }

        ScanResult scan = LeaseScanner.Scan();
        var holders = new Dictionary<string, List<int>>(StringComparer.Ordinal);
        foreach (LeaseEntry lease in scan.Leases)
        {
            string semaphoreName = "Local\\dsh-session-lock-" + lease.Hash;
            if (!holders.TryGetValue(semaphoreName, out List<int>? pids))
            {
                pids = new List<int>();
                holders[semaphoreName] = pids;
            }

            pids.Add(lease.Pid);
        }

        EmitJson(writer =>
        {
            writer.WriteBoolean("ok", true);
            writer.WriteNumber("scanMs", scan.ScanMs);
            writer.WriteStartArray("results");
            foreach ((string fullPath, string semaphoreName) in resolved)
            {
                writer.WriteStartObject();
                writer.WriteString("lock", fullPath);
                bool held = holders.TryGetValue(semaphoreName, out List<int>? pids);
                writer.WriteBoolean("held", held);
                writer.WriteStartArray("pids");
                if (held)
                {
                    foreach (int pid in pids!)
                    {
                        writer.WriteNumberValue(pid);
                    }
                }

                writer.WriteEndArray();
                writer.WriteEndObject();
            }

            writer.WriteEndArray();
        });
        return 0;
    }

    private static void EmitJson(Action<Utf8JsonWriter> body)
    {
        using var buffer = new MemoryStream(1024);
        using (var writer = new Utf8JsonWriter(buffer, new JsonWriterOptions { Indented = false }))
        {
            writer.WriteStartObject();
            body(writer);
            writer.WriteEndObject();
        }

        buffer.WriteByte((byte)'\n');
        using Stream stdout = Console.OpenStandardOutput();
        stdout.Write(buffer.GetBuffer(), 0, (int)buffer.Length);
        stdout.Flush();
    }

    private static void WriteFailure(string message)
    {
        try
        {
            Console.Error.WriteLine("DshLeaseProbe: " + message);
        }
        catch (IOException)
        {
            // stderr may be closed; the JSON contract below still matters more.
        }

        EmitJson(writer =>
        {
            writer.WriteBoolean("ok", false);
            writer.WriteString("error", message);
        });
    }
}
