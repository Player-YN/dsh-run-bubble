using System.Runtime.InteropServices;
using System.Text;

namespace DshRunBubble;

/// <summary>
/// Minimal Win32 surface needed by the layered overlay window.
/// Every entry point is a raw P/Invoke: callers must treat failures as
/// non-fatal so that no interop error can escape the message loop.
/// </summary>
internal static class Native
{
    // ---- extended window styles -------------------------------------------
    public const int WS_EX_TRANSPARENT = 0x00000020;
    public const int WS_EX_TOPMOST = 0x00000008;
    public const int WS_EX_TOOLWINDOW = 0x00000080;
    public const int WS_EX_LAYERED = 0x00080000;
    public const int WS_EX_NOACTIVATE = 0x08000000;

    // ---- window messages --------------------------------------------------
    public const int WM_ERASEBKGND = 0x0014;
    public const int WM_MOUSEACTIVATE = 0x0021;
    public const int WM_WINDOWPOSCHANGED = 0x0047;
    public const int WM_DISPLAYCHANGE = 0x007E;
    public const int WM_MOUSEWHEEL = 0x020A;
    public const int WM_MOUSELEAVE = 0x02A3;
    public const int WM_DPICHANGED = 0x02E0;

    public const int MA_NOACTIVATE = 3;

    // ---- SetWindowPos -----------------------------------------------------
    public const uint SWP_NOSIZE = 0x0001;
    public const uint SWP_NOMOVE = 0x0002;
    public const uint SWP_NOZORDER = 0x0004;
    public const uint SWP_NOACTIVATE = 0x0010;
    public const uint SWP_NOOWNERZORDER = 0x0200;

    public const uint SWP_SHOWWINDOW = 0x0040;

    public static readonly IntPtr HWND_TOPMOST = new IntPtr(-1);

    // ---- ShowWindow / TrackMouseEvent ------------------------------------
    public const int SW_HIDE = 0;
    public const int SW_SHOWNOACTIVATE = 4;
    public const int TME_LEAVE = 0x00000002;

    // ---- MonitorFromWindow -----------------------------------------------
    public const uint MONITOR_DEFAULTTONEAREST = 0x00000002;

    // ---- UpdateLayeredWindow ---------------------------------------------
    public const int ULW_ALPHA = 0x00000002;
    public const byte AC_SRC_OVER = 0x00;
    public const byte AC_SRC_ALPHA = 0x01;

    public const int ATTACH_PARENT_PROCESS = -1;

    [StructLayout(LayoutKind.Sequential)]
    public struct POINT
    {
        public int X;
        public int Y;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct SIZE
    {
        public int CX;
        public int CY;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT
    {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    [StructLayout(LayoutKind.Sequential, Pack = 1)]
    public struct BLENDFUNCTION
    {
        public byte BlendOp;
        public byte BlendFlags;
        public byte SourceConstantAlpha;
        public byte AlphaFormat;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct TRACKMOUSEEVENT
    {
        public int cbSize;
        public int dwFlags;
        public IntPtr hwndTrack;
        public int dwHoverTime;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct BITMAPINFOHEADER
    {
        public int biSize;
        public int biWidth;
        public int biHeight;
        public short biPlanes;
        public short biBitCount;
        public int biCompression;
        public int biSizeImage;
        public int biXPelsPerMeter;
        public int biYPelsPerMeter;
        public int biClrUsed;
        public int biClrImportant;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct BITMAPINFO
    {
        public BITMAPINFOHEADER bmiHeader;
        public uint bmiColors;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct MONITORINFO
    {
        public int cbSize;
        public RECT rcMonitor;
        public RECT rcWork;
        public uint dwFlags;
    }

    private const string User32 = "user32.dll";
    private const string Gdi32 = "gdi32.dll";
    private const string Kernel32 = "kernel32.dll";

    [DllImport(User32, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool UpdateLayeredWindow(
        IntPtr hwnd,
        IntPtr hdcDst,
        ref POINT pptDst,
        ref SIZE psize,
        IntPtr hdcSrc,
        ref POINT pptSrc,
        int crKey,
        ref BLENDFUNCTION pblend,
        int dwFlags);

    [DllImport(User32)]
    public static extern IntPtr GetDC(IntPtr hwnd);

    [DllImport(User32)]
    public static extern int ReleaseDC(IntPtr hwnd, IntPtr hdc);

    [DllImport(User32)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool ShowWindow(IntPtr hwnd, int nCmdShow);

    [DllImport(User32)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool TrackMouseEvent(ref TRACKMOUSEEVENT tme);

    [DllImport(User32, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool SetWindowPos(
        IntPtr hWnd,
        IntPtr hWndInsertAfter,
        int x,
        int y,
        int cx,
        int cy,
        uint uFlags);

    [DllImport(User32)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);

    [DllImport(User32)]
    public static extern uint GetDpiForWindow(IntPtr hwnd);

    // ---- foreground / monitor inspection (fullscreen auto-hide) -----------
    [DllImport(User32)]
    public static extern IntPtr GetForegroundWindow();

    [DllImport(User32)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool IsWindowVisible(IntPtr hWnd);

    [DllImport(User32)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool IsIconic(IntPtr hWnd);

    [DllImport(User32, SetLastError = true)]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);

    [DllImport(User32, CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern int GetClassNameW(IntPtr hWnd, StringBuilder lpClassName, int nMaxCount);

    [DllImport(User32)]
    public static extern IntPtr MonitorFromWindow(IntPtr hwnd, uint dwFlags);

    [DllImport(User32, CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool GetMonitorInfo(IntPtr hMonitor, ref MONITORINFO lpmi);

    // ---- extended styles / process image (fullscreen false positives) -----
    public const int GWL_EXSTYLE = -20;

    [DllImport(User32, EntryPoint = "GetWindowLongPtrW", SetLastError = true)]
    public static extern IntPtr GetWindowLongPtr(IntPtr hWnd, int nIndex);

    public const uint PROCESS_QUERY_LIMITED_INFORMATION = 0x1000;

    [DllImport(Kernel32, SetLastError = true)]
    private static extern IntPtr OpenProcess(
        uint dwDesiredAccess,
        [MarshalAs(UnmanagedType.Bool)] bool bInheritHandle,
        uint dwProcessId);

    [DllImport(Kernel32, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CloseHandle(IntPtr hObject);

    [DllImport(Kernel32, CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool QueryFullProcessImageNameW(
        IntPtr hProcess,
        uint dwFlags,
        StringBuilder lpExeName,
        ref uint lpdwSize);

    /// <summary>
    /// Executable file name (no directory) for a PID, or an empty string when the
    /// process cannot be opened. Used to ignore shell/overlay hosts that stretch
    /// over the monitor without being a real fullscreen app.
    /// </summary>
    public static string GetProcessImageName(uint processId)
    {
        if (processId == 0)
        {
            return string.Empty;
        }

        IntPtr process = IntPtr.Zero;
        try
        {
            process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, processId);
            if (process == IntPtr.Zero)
            {
                return string.Empty;
            }

            var buffer = new StringBuilder(1024);
            uint size = (uint)buffer.Capacity;
            if (!QueryFullProcessImageNameW(process, 0, buffer, ref size))
            {
                return string.Empty;
            }

            string full = buffer.ToString(0, (int)Math.Min(size, (uint)buffer.Length));
            int slash = full.LastIndexOfAny(new[] { '\\', '/' });
            return slash >= 0 ? full.Substring(slash + 1) : full;
        }
        catch
        {
            return string.Empty;
        }
        finally
        {
            if (process != IntPtr.Zero)
            {
                try { CloseHandle(process); } catch { }
            }
        }
    }

    /// <summary>Window class name; empty string on any failure.</summary>
    public static string GetClassName(IntPtr hwnd)
    {
        if (hwnd == IntPtr.Zero)
        {
            return string.Empty;
        }

        try
        {
            var buffer = new StringBuilder(256);
            int length = GetClassNameW(hwnd, buffer, buffer.Capacity);
            if (length <= 0)
            {
                return string.Empty;
            }

            int take = Math.Min(length, buffer.Length);
            return take > 0 ? buffer.ToString(0, take) : string.Empty;
        }
        catch
        {
            return string.Empty;
        }
    }

    [DllImport(Gdi32)]
    public static extern IntPtr CreateCompatibleDC(IntPtr hdc);

    [DllImport(Gdi32)]
    public static extern IntPtr CreateDIBSection(
        IntPtr hdc,
        ref BITMAPINFO pbmi,
        uint usage,
        out IntPtr ppvBits,
        IntPtr hSection,
        uint offset);

    [DllImport(Gdi32)]
    public static extern IntPtr SelectObject(IntPtr hdc, IntPtr hObject);

    [DllImport(Gdi32)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool DeleteObject(IntPtr hObject);

    [DllImport(Gdi32)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool DeleteDC(IntPtr hdc);

    [DllImport(Kernel32)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool AttachConsole(int dwProcessId);

    /// <summary>
    /// Re-attach the parent console (if any) so that a WinExe build can still
    /// emit diagnostics to stderr when launched from a shell. Never throws.
    /// </summary>
    public static void TryAttachParentConsole()
    {
        try
        {
            if (!AttachConsole(ATTACH_PARENT_PROCESS))
            {
                return;
            }

            Console.SetError(new StreamWriter(Console.OpenStandardError()) { AutoFlush = true });
            Console.SetOut(new StreamWriter(Console.OpenStandardOutput()) { AutoFlush = true });
        }
        catch
        {
            // No console available: diagnostics are simply dropped.
        }
    }

    /// <summary>Arms TME_LEAVE tracking for the window; returns false on failure.</summary>
    public static bool TryTrackLeave(IntPtr hwnd)
    {
        try
        {
            if (hwnd == IntPtr.Zero)
            {
                return false;
            }

            var tme = new TRACKMOUSEEVENT
            {
                cbSize = Marshal.SizeOf<TRACKMOUSEEVENT>(),
                dwFlags = TME_LEAVE,
                hwndTrack = hwnd,
                dwHoverTime = 0,
            };
            return TrackMouseEvent(ref tme);
        }
        catch
        {
            return false;
        }
    }
}
