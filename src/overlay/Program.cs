using System.Globalization;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Windows.Forms;

namespace DshRunBubble;

/// <summary>
/// Entry point: flag parsing, single-instance guard, demo seeding, the 500 ms
/// status.json poll (with the 2.5 s non-empty grace window), the 0.6 s pulse
/// ticker and <c>--snapshot</c> export.
/// </summary>
internal static class Program
{
    private const string StatusFileName = "status.json";
    private const string ConfigFileName = "config.json";
    private const double StatusExpirySeconds = 6.0;
    private const int ReloadIntervalMs = 500;
    private const int PulseIntervalMs = 600;
    private const int SnapshotSettleMs = 800;

    private static BubbleWindow? _window;
    private static string _statusPath = string.Empty;
    private static string _configPath = string.Empty;
    private static OverlayConfig _config = new();
    private static DateTime _configStamp = DateTime.MinValue;
    private static bool _demoMode;
    private static bool _dark;

    /// <summary>
    /// `--dark` / `--light` pin the theme instead of following the Windows
    /// personalisation setting. Used for deterministic screenshots and CI.
    /// </summary>
    private static bool? _forceDark;

    [STAThread]
    private static int Main(string[] args)
    {
        Native.TryAttachParentConsole();

        bool demo = HasFlag(args, "--demo");
        bool demoMany = HasFlag(args, "--demo-many");
        bool demoRoots = HasFlag(args, "--demo-roots");
        bool demoIdle = HasFlag(args, "--demo-idle");
        bool collapsed = HasFlag(args, "--collapsed");
        bool collapseFirst = HasFlag(args, "--collapse-first");
        string? snapshotPath = FlagValue(args, "--snapshot");
        float scroll = 0f;
        string? scrollRaw = FlagValue(args, "--scroll");
        if (!string.IsNullOrEmpty(scrollRaw))
        {
            if (!float.TryParse(scrollRaw, NumberStyles.Float, CultureInfo.InvariantCulture, out scroll))
            {
                scroll = 0f;
            }
        }

        bool anyDemo = demo || demoMany || demoRoots || demoIdle;
        _demoMode = anyDemo;
        string stateDir = ResolveStateDir();
        _statusPath = Path.Combine(stateDir, StatusFileName);
        _configPath = Path.Combine(stateDir, ConfigFileName);
        _config = ReadConfig(_configPath);
        _configStamp = ConfigStamp();

        if (HasFlag(args, "--dark"))
        {
            _forceDark = true;
        }
        else if (HasFlag(args, "--light"))
        {
            _forceDark = false;
        }

        bool anotherInstance = TryAcquireMutex(out Mutex? mutex, out bool mutexUnavailable);
        if (anotherInstance && snapshotPath == null)
        {
            // A resident overlay is already running; second launches are no-ops.
            return 0;
        }

        if (mutexUnavailable)
        {
            Stderr("warning: could not create the single-instance mutex; continuing.");
        }

        try
        {
            // Must run before any window handle exists.
            try
            {
                Application.SetHighDpiMode(HighDpiMode.PerMonitorV2);
            }
            catch
            {
                // Already initialized or unsupported; DeviceDpi fallback covers it.
            }

            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            Application.SetUnhandledExceptionMode(UnhandledExceptionMode.CatchException);
            Application.ThreadException += (_, e) => Stderr("UI thread exception: " + e.Exception);
            AppDomain.CurrentDomain.UnhandledException += (_, e) => Stderr("fatal: " + e.ExceptionObject);

            _dark = IsDarkTheme();

            Theme theme;
            try
            {
                theme = Theme.Create(_dark);
            }
            catch (Exception ex)
            {
                Stderr("failed to create theme: " + ex);
                return 1;
            }

            if (snapshotPath != null)
            {
                return RunSnapshot(theme, snapshotPath, anyDemo, demoIdle, demoMany, demoRoots, collapsed, collapseFirst, scroll);
            }

            return RunResident(theme, anyDemo, demoIdle, demoMany, demoRoots, collapsed, collapseFirst, scroll);
        }
        finally
        {
            GC.KeepAlive(mutex);
        }
    }

    // ------------------------------------------------------------------
    // Resident mode
    // ------------------------------------------------------------------

    private static int RunResident(
        Theme theme,
        bool anyDemo,
        bool demoIdle,
        bool demoMany,
        bool demoRoots,
        bool collapsed,
        bool collapseFirst,
        float scroll)
    {
        try
        {
            _window = new BubbleWindow(theme, snapshotMode: false);
            _window.EnsureReady();
            _window.SetIncludeDesktop(_config.IncludeDesktop);
            _window.SetHideOnFullscreen(_config.HideOnFullscreen);
            _window.IncludeDesktopChanged += OnIncludeDesktopToggled;
            // Resident start-up is collapsed; demo flags (and pin) open it, exactly
            // like macOS: pinned || ((demo) && !collapsed).
            _window.SetInitialExpanded(anyDemo && !collapsed);
            _window.Apply(anyDemo
                ? BuildDemoRoots(demoIdle, demoMany, demoRoots)
                : new List<RootSession>());

            if (collapseFirst)
            {
                _window.CollapseFirstRoot();
                _window.Relayout();
            }

            if (scroll > 0f)
            {
                _window.SetScroll(scroll);
                _window.Relayout();
            }

            _window.ShowBubble();
        }
        catch (Exception ex)
        {
            Stderr("failed to create the overlay window: " + ex);
            return 1;
        }

        int tick = 0;
        var pulse = new System.Windows.Forms.Timer { Interval = PulseIntervalMs };
        pulse.Tick += (_, _) =>
        {
            try
            {
                tick++;
                _window?.SetPulse(tick % 2 == 0 ? 0.55f : 1.0f);
            }
            catch (Exception ex)
            {
                Stderr("pulse tick failed: " + ex.Message);
            }
        };
        pulse.Start();

        var reload = new System.Windows.Forms.Timer { Interval = ReloadIntervalMs };
        reload.Tick += (_, _) =>
        {
            try
            {
                Reload();
            }
            catch (Exception ex)
            {
                Stderr("reload failed: " + ex.Message);
            }
        };
        reload.Start();

        Reload();

        try
        {
            Application.Run(_window);
        }
        catch (Exception ex)
        {
            Stderr("message loop terminated: " + ex);
            return 1;
        }

        return 0;
    }

    private static void Reload()
    {
        bool dark = IsDarkTheme();
        if (dark != _dark)
        {
            _dark = dark;
            try
            {
                _window?.SetTheme(Theme.Create(dark));
            }
            catch (Exception ex)
            {
                Stderr("theme rebuild failed: " + ex.Message);
            }
        }

        // Shared switches + fullscreen auto-hide run on the same 500 ms tick.
        RefreshConfigIfChanged();
        try
        {
            _window?.UpdateFullscreenVisibility();
        }
        catch (Exception ex)
        {
            Stderr("fullscreen check failed: " + ex.Message);
        }

        if (_demoMode || _window == null)
        {
            return;
        }

        _window.Apply(ReadRoots());
    }

    // ------------------------------------------------------------------
    // Snapshot mode
    // ------------------------------------------------------------------

    private static int RunSnapshot(
        Theme theme,
        string path,
        bool anyDemo,
        bool demoIdle,
        bool demoMany,
        bool demoRoots,
        bool collapsed,
        bool collapseFirst,
        float scroll)
    {
        try
        {
            // No HWND is created: rendering is pure GDI+ into an offscreen bitmap,
            // so this also works without a desktop session.
            var window = new BubbleWindow(theme, snapshotMode: true);
            window.SetIncludeDesktop(_config.IncludeDesktop);
            window.SetInitialExpanded(!collapsed);
            window.Apply(anyDemo
                ? BuildDemoRoots(demoIdle, demoMany, demoRoots)
                : ReadRoots());

            if (collapseFirst)
            {
                window.CollapseFirstRoot();
                window.Relayout();
            }

            if (scroll > 0f)
            {
                window.SetScroll(scroll);
                window.Relayout();
            }

            window.RenderNow();
            Thread.Sleep(SnapshotSettleMs);
            window.RenderNow();

            if (!window.SaveSnapshot(path))
            {
                Stderr("snapshot failed: could not render/write " + path);
                return 1;
            }

            return 0;
        }
        catch (Exception ex)
        {
            Stderr("snapshot failed: " + ex);
            return 1;
        }
    }

    // ------------------------------------------------------------------
    // Status file
    // ------------------------------------------------------------------

    private static List<RootSession> ReadRoots()
    {
        try
        {
            if (!File.Exists(_statusPath))
            {
                return new List<RootSession>();
            }

            TimeSpan age = DateTime.UtcNow - File.GetLastWriteTimeUtc(_statusPath);
            if (age.TotalSeconds > StatusExpirySeconds)
            {
                // A stale file means the daemon is gone: render idle, not the past.
                return new List<RootSession>();
            }

            string json = File.ReadAllText(_statusPath);
            List<RootSession>? parsed = StatusDoc.Parse(json);
            return parsed ?? new List<RootSession>();
        }
        catch (Exception ex)
        {
            Stderr("status read failed: " + ex.Message);
            return new List<RootSession>();
        }
    }

    /// <summary>
    /// Directory that holds status.json / config.json. <c>RUN_BUBBLE_STATUS_DIR</c>
    /// wins, then <c>DSH_HOME</c>, then <c>%USERPROFILE%\.dsh</c>; always suffixed
    /// with <c>run-bubble</c> unless the override already points at it.
    /// </summary>
    private static string ResolveStateDir()
    {
        string? dir = Environment.GetEnvironmentVariable("RUN_BUBBLE_STATUS_DIR");
        if (!string.IsNullOrEmpty(dir))
        {
            return dir;
        }

        string? home = Environment.GetEnvironmentVariable("DSH_HOME");
        if (string.IsNullOrEmpty(home))
        {
            string profile = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
            home = Path.Combine(profile, ".dsh");
        }

        return Path.Combine(home, "run-bubble");
    }

    // ------------------------------------------------------------------
    // config.json (shared with the daemon, see docs/PORT-WINDOWS.md §11.3)
    // ------------------------------------------------------------------

    private sealed class OverlayConfig
    {
        public bool IncludeDesktop;
        public bool HideOnFullscreen = true;
    }

    private static DateTime ConfigStamp()
    {
        try
        {
            return File.Exists(_configPath) ? File.GetLastWriteTimeUtc(_configPath) : DateTime.MinValue;
        }
        catch
        {
            return DateTime.MinValue;
        }
    }

    private static OverlayConfig ReadConfig(string path)
    {
        var config = new OverlayConfig();
        try
        {
            if (!File.Exists(path))
            {
                return config;
            }

            using JsonDocument doc = JsonDocument.Parse(File.ReadAllText(path));
            JsonElement root = doc.RootElement;
            if (root.ValueKind != JsonValueKind.Object)
            {
                return config;
            }

            if (root.TryGetProperty("includeDesktop", out JsonElement include)
                && (include.ValueKind == JsonValueKind.True || include.ValueKind == JsonValueKind.False))
            {
                config.IncludeDesktop = include.GetBoolean();
            }

            if (root.TryGetProperty("hideOnFullscreen", out JsonElement hide)
                && (hide.ValueKind == JsonValueKind.True || hide.ValueKind == JsonValueKind.False))
            {
                config.HideOnFullscreen = hide.GetBoolean();
            }
        }
        catch (Exception ex)
        {
            Stderr("config read failed: " + ex.Message);
        }

        return config;
    }

    /// <summary>
    /// Atomically writes the two known switches while preserving every other key
    /// the daemon or a future version may have stored.
    /// </summary>
    private static bool WriteConfig(OverlayConfig config)
    {
        try
        {
            JsonObject root;
            try
            {
                root = File.Exists(_configPath)
                    ? JsonNode.Parse(File.ReadAllText(_configPath)) as JsonObject ?? new JsonObject()
                    : new JsonObject();
            }
            catch
            {
                root = new JsonObject();
            }

            root["includeDesktop"] = config.IncludeDesktop;
            root["hideOnFullscreen"] = config.HideOnFullscreen;

            string json = root.ToJsonString(new JsonSerializerOptions { WriteIndented = true }) + "\n";
            string? dir = Path.GetDirectoryName(_configPath);
            if (!string.IsNullOrEmpty(dir))
            {
                Directory.CreateDirectory(dir);
            }

            string tmp = _configPath + ".tmp-" + Environment.ProcessId.ToString(CultureInfo.InvariantCulture);
            File.WriteAllText(tmp, json);
            File.Move(tmp, _configPath, overwrite: true);

            _configStamp = ConfigStamp();
            return true;
        }
        catch (Exception ex)
        {
            Stderr("config write failed: " + ex.Message);
            return false;
        }
    }

    private static void OnIncludeDesktopToggled(bool includeDesktop)
    {
        _config.IncludeDesktop = includeDesktop;
        WriteConfig(_config);
    }

    /// <summary>Picks up manual edits of config.json without a restart.</summary>
    private static void RefreshConfigIfChanged()
    {
        try
        {
            DateTime stamp = ConfigStamp();
            if (stamp == _configStamp)
            {
                return;
            }

            _configStamp = stamp;
            _config = ReadConfig(_configPath);
            _window?.SetIncludeDesktop(_config.IncludeDesktop);
            _window?.SetHideOnFullscreen(_config.HideOnFullscreen);
        }
        catch (Exception ex)
        {
            Stderr("config refresh failed: " + ex.Message);
        }
    }

    // ------------------------------------------------------------------
    // Demo data
    // ------------------------------------------------------------------

    private static List<RootSession> BuildDemoRoots(bool demoIdle, bool demoMany, bool demoRoots)
    {
        if (demoIdle)
        {
            return new List<RootSession>();
        }

        if (demoMany)
        {
            return DemoData.DemoManyRoots();
        }

        if (demoRoots)
        {
            return DemoData.DemoSameTitleRoots();
        }

        return DemoData.DemoRoots();
    }

    // ------------------------------------------------------------------
    // Theme
    // ------------------------------------------------------------------

    /// <summary>
    /// AppsUseLightTheme DWORD: 1 = light, 0 = dark. Missing value keeps the
    /// Windows default (light).
    /// </summary>
    private static bool IsDarkTheme()
    {
        if (_forceDark.HasValue)
        {
            return _forceDark.Value;
        }

        try
        {
            object? value = Microsoft.Win32.Registry.GetValue(
                @"HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize",
                "AppsUseLightTheme",
                null);
            if (value is int intValue && intValue == 0)
            {
                return true;
            }
        }
        catch
        {
            // Registry inaccessible: stay light.
        }

        return false;
    }

    // ------------------------------------------------------------------
    // Single instance / arguments / diagnostics
    // ------------------------------------------------------------------

    /// <summary>
    /// Takes the named mutex. Returns true when another instance already owns
    /// it, and reports whether no mutex could be created at all.
    /// </summary>
    private static bool TryAcquireMutex(out Mutex? mutex, out bool unavailable)
    {
        string[] names = { @"Global\DshRunBubbleOverlay", @"Local\DshRunBubbleOverlay" };
        bool sawPermissionFailure = false;

        foreach (string name in names)
        {
            try
            {
                var candidate = new Mutex(initiallyOwned: true, name, out bool createdNew);
                if (createdNew)
                {
                    mutex = candidate;
                    unavailable = false;
                    return false;
                }

                candidate.Dispose();
                mutex = null;
                unavailable = false;
                return true;
            }
            catch (UnauthorizedAccessException)
            {
                sawPermissionFailure = true;
            }
            catch
            {
                sawPermissionFailure = true;
            }
        }

        mutex = null;
        unavailable = sawPermissionFailure;
        return false;
    }

    private static bool HasFlag(string[] args, string flag)
    {
        for (int i = 0; i < args.Length; i++)
        {
            if (string.Equals(args[i], flag, StringComparison.Ordinal))
            {
                return true;
            }
        }

        return false;
    }

    private static string? FlagValue(string[] args, string flag)
    {
        for (int i = 0; i < args.Length; i++)
        {
            if (!string.Equals(args[i], flag, StringComparison.Ordinal))
            {
                continue;
            }

            if (i + 1 < args.Length && !args[i + 1].StartsWith("--", StringComparison.Ordinal))
            {
                return args[i + 1];
            }

            return null;
        }

        return null;
    }

    private static void Stderr(string message)
    {
        try
        {
            Console.Error.WriteLine("[overlay] " + message);
        }
        catch
        {
            // No console attached.
        }
    }
}
