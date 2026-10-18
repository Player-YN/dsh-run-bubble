using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Drawing.Text;
using System.Globalization;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Windows.Forms;

namespace DshRunBubble;

/// <summary>
/// Borderless, never-activating layered window that hosts the run bubble.
///
/// Presentation goes through <c>UpdateLayeredWindow</c> with a 32bpp premultiplied
/// ARGB DIB section, so the rounded panel has true per-pixel alpha and the
/// transparent corners are click-through for free (Windows hit-tests layered
/// windows against the alpha channel).
///
/// Owned behaviour: DPI, anchor-based positioning, drag / hover / pin / wheel
/// interaction, position.json persistence and snapshot export. Every pixel is
/// produced by <see cref="BubbleRenderer"/>.
/// </summary>
internal sealed class BubbleWindow : Form
{
    private const int ExpandedWidth = 356;
    private const int MinCollapsedWidth = 52;
    private const int MaxCollapsedWidth = 238;
    private const float CollapsedHeight = 26f;
    private const float PinSize = 18f;
    private const float PinTop = 6f;
    private const float PinRight = 14f;
    private const double HoverSuppressSeconds = 0.35;
    private const int ResizeMargin = 6;
    private const int DragMargin = 4;
    private const double AnchorSaveMs = 200;
    private const double GraceSeconds = 2.5;
    private const float DragThresholdDip = 4f;
    private const float WheelStepPerNotch = 40f;

    private readonly BubbleState _state = new();
    private readonly bool _snapshotMode;
    private readonly System.Windows.Forms.Timer _longPressTimer;

    private Theme _theme;

    // DPI + surface ------------------------------------------------------
    private float _scale = 1f;
    private float _logicalW = MaxCollapsedWidth;
    private float _logicalH = CollapsedHeight;
    private int _pxW;
    private int _pxH;

    private Bitmap? _canvas;
    private IntPtr _memDc = IntPtr.Zero;
    private IntPtr _dib = IntPtr.Zero;
    private IntPtr _dibOld = IntPtr.Zero;
    private IntPtr _dibBits = IntPtr.Zero;

    private RenderResult? _lastRender;
    private bool _started;
    private bool _rendering;
    private bool _renderErrorLogged;
    private bool _interopErrorLogged;

    // Anchor (Right, Bottom in physical virtual-screen pixels) ------------
    private PointF _anchor;
    private bool _hasAnchor;
    private DateTime _lastAnchorSave = DateTime.MinValue;

    // Native window rect in physical pixels. WinForms' cached Bounds goes stale
    // after UpdateLayeredWindow (which repositions the HWND without a
    // WM_WINDOWPOSCHANGED WinForms can observe), so the window layer tracks the
    // real rect itself and drives every position change through the OS.
    private Rectangle _bounds = new Rectangle(0, 0, MaxCollapsedWidth, (int)CollapsedHeight);

    // Interaction --------------------------------------------------------
    private bool _trackingLeave;
    private DateTime _hoverSuppressUntil = DateTime.MinValue;
    private DateTime _lastNonEmptyAt = DateTime.MinValue;
    private bool _pendingDrag;
    private bool _isDragging;
    private Point _dragStartScreen;
    private Point _dragStartOrigin;
    private string? _toggleRootId;

    // Fullscreen auto-hide -----------------------------------------------
    private bool _hideOnFullscreen = true;
    private bool _hiddenForFullscreen;
    private bool _layoutDirty;

    /// <summary>Raised when the user flips the desktop-sessions toggle.</summary>
    public event Action<bool>? IncludeDesktopChanged;

    public BubbleWindow(Theme theme, bool snapshotMode)
    {
        _theme = theme;
        _snapshotMode = snapshotMode;

        FormBorderStyle = FormBorderStyle.None;
        ShowInTaskbar = false;
        TopMost = true;
        StartPosition = FormStartPosition.Manual;
        AutoScaleMode = AutoScaleMode.None;
        BackColor = Color.Black;
        Text = "DSH Run Bubble";
        Size = new Size(MaxCollapsedWidth, (int)CollapsedHeight);
        SetStyle(ControlStyles.Opaque, true);
        SetStyle(ControlStyles.UserPaint, true);

        _longPressTimer = new System.Windows.Forms.Timer { Interval = 350 };
        _longPressTimer.Tick += OnLongPressTick;

        LoadPosition();
        if (_state.Pinned)
        {
            _state.Expanded = true;
        }
    }

    /// <summary>Whether the pin is engaged (mirrors macOS <c>panel.pinned</c>).</summary>
    public bool Pinned => _state.Pinned;

    /// <summary>True when no external session is being displayed.</summary>
    public bool IsIdle => _state.Roots.Count == 0;

    // ------------------------------------------------------------------
    // Creation / presentation
    // ------------------------------------------------------------------

    protected override bool ShowWithoutActivation => true;

    protected override CreateParams CreateParams
    {
        get
        {
            CreateParams cp = base.CreateParams;
            cp.ExStyle |= Native.WS_EX_LAYERED
                          | Native.WS_EX_TOPMOST
                          | Native.WS_EX_TOOLWINDOW
                          | Native.WS_EX_NOACTIVATE;
            if (_snapshotMode)
            {
                // Snapshot export is headless: never intercept any clicks.
                cp.ExStyle |= Native.WS_EX_TRANSPARENT;
            }

            return cp;
        }
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        // The layered surface is the only visual; GDI painting must stay inert.
    }

    protected override void OnPaintBackground(PaintEventArgs e)
    {
    }

    /// <summary>Creates the HWND (needed before DPI queries) and resolves DPI.</summary>
    public void EnsureReady()
    {
        if (_snapshotMode)
        {
            return;
        }

        _ = Handle;
        _scale = GetScale();
    }

    /// <summary>Sets the expanded flag without laying out (used before the first Apply).</summary>
    public void SetInitialExpanded(bool expanded)
    {
        _state.Expanded = expanded || _state.Pinned;
    }

    public void SetTheme(Theme theme)
    {
        _theme = theme;
        RenderNow();
    }

    public void SetPulse(float pulse)
    {
        if (Math.Abs(_state.Pulse - pulse) < 0.001f)
        {
            return;
        }

        _state.Pulse = pulse;
        RenderNow();
    }

    /// <summary>Mirrors config.json <c>includeDesktop</c> into the shared state.</summary>
    public void SetIncludeDesktop(bool value)
    {
        if (_state.IncludeDesktop == value)
        {
            return;
        }

        _state.IncludeDesktop = value;
        RenderNow();
    }

    /// <summary>Mirrors config.json <c>hideOnFullscreen</c>.</summary>
    public void SetHideOnFullscreen(bool value)
    {
        _hideOnFullscreen = value;
    }

    /// <summary>
    /// Applies a fresh set of roots. Keeps the previous non-empty state for a
    /// short grace window (macOS parity: a single empty poll between turns must
    /// not make the bubble flash idle).
    /// </summary>
    public void Apply(List<RootSession> roots)
    {
        if (roots == null)
        {
            roots = new List<RootSession>();
        }

        if (_state.Pinned)
        {
            _state.Expanded = true;
        }

        bool changed;
        if (roots.Count == 0)
        {
            if (_state.Roots.Count > 0)
            {
                if (_lastNonEmptyAt != DateTime.MinValue
                    && (DateTime.UtcNow - _lastNonEmptyAt).TotalSeconds < GraceSeconds)
                {
                    return;
                }

                _state.Roots.Clear();
                _state.ScrollOffset = 0f;
                changed = true;
            }
            else
            {
                changed = !_started;
            }
        }
        else
        {
            _state.Roots.Clear();
            _state.Roots.AddRange(roots);
            _lastNonEmptyAt = DateTime.UtcNow;
            changed = true;
        }

        if (!changed && _started)
        {
            ShowBubble();
            return;
        }

        ApplyLayout();
        ShowBubble();
        _started = true;
    }

    public void ShowBubble()
    {
        if (_snapshotMode || _hiddenForFullscreen)
        {
            // Never resurrect the window while a fullscreen app owns the monitor.
            return;
        }

        try
        {
            if (!Visible)
            {
                Show();
            }

            Native.ShowWindow(Handle, Native.SW_SHOWNOACTIVATE);
        }
        catch (Exception ex)
        {
            LogInteropOnce(ex);
        }
    }

    // ------------------------------------------------------------------
    // Layout / rendering
    // ------------------------------------------------------------------

    /// <summary>Recomputes size from state, repositions from the anchor and redraws.</summary>
    public void Relayout()
    {
        ApplyLayout();
    }

    public void CollapseFirstRoot()
    {
        if (_state.Roots.Count > 0)
        {
            _state.CollapsedRoots.Add(_state.Roots[0].Id);
        }
    }

    public void SetScroll(float offset)
    {
        _state.ScrollOffset = offset;
        ClampScroll();
        RenderNow();
    }

    private void ApplyLayout()
    {
        // Hidden for a fullscreen foreground window: remember that a relayout is
        // due and skip the surface work; it is replayed by RestoreFromFullscreen.
        if (_hiddenForFullscreen && !_snapshotMode)
        {
            _layoutDirty = true;
            return;
        }

        _scale = _snapshotMode ? 1f : GetScale();
        _logicalW = ResolvePreferredWidth();
        _logicalH = ResolvePreferredHeight();

        int pw = Math.Max(1, (int)Math.Round(_logicalW * _scale));
        int ph = Math.Max(1, (int)Math.Round(_logicalH * _scale));
        if (_canvas == null || pw != _pxW || ph != _pxH)
        {
            _pxW = pw;
            _pxH = ph;
            CreateSurface();
        }

        // Position and surface size are applied atomically by UpdateLayeredWindow
        // (ptDst + psize). Moving/resizing the HWND before the layered surface is
        // updated makes Windows believe the cursor left the window and fire a
        // spurious WM_MOUSELEAVE, which would collapse a freshly expanded bubble.
        Rectangle? dest = _snapshotMode ? null : ComputeBounds();
        RenderFrame(dest);

        if (ClampScroll())
        {
            RenderFrame(dest);
        }
    }

    /// <summary>
    /// Collapsed width is content-adaptive (renderer decides, clamped here as a
    /// last line of defence); expanded width stays a fixed 356 DIP.
    /// </summary>
    private float ResolvePreferredWidth()
    {
        float width;
        try
        {
            width = BubbleRenderer.PreferredWidth(_state);
        }
        catch (Exception ex)
        {
            LogRenderOnce(ex);
            width = _state.Expanded ? ExpandedWidth : MaxCollapsedWidth;
        }

        if (!(width > 0f) || float.IsNaN(width) || float.IsInfinity(width))
        {
            width = _state.Expanded ? ExpandedWidth : MaxCollapsedWidth;
        }

        return Math.Clamp(width, MinCollapsedWidth, ExpandedWidth);
    }

    private float ResolvePreferredHeight()
    {
        if (!_state.Expanded)
        {
            return CollapsedHeight;
        }

        float preferred;
        try
        {
            preferred = BubbleRenderer.PreferredHeight(_state);
        }
        catch (Exception ex)
        {
            LogRenderOnce(ex);
            return CollapsedHeight;
        }

        if (!(preferred > 0f) || float.IsNaN(preferred) || float.IsInfinity(preferred))
        {
            return CollapsedHeight;
        }

        return preferred;
    }

    public void RenderNow()
    {
        try
        {
            RenderFrame(null);
        }
        catch (Exception ex)
        {
            LogRenderOnce(ex);
        }
    }

    private void RenderFrame(Rectangle? destinationOrBounds)
    {
        // Hidden for a fullscreen app: do not touch the surface at all. The
        // pending frame is produced by RestoreFromFullscreen.
        if (_hiddenForFullscreen && !_snapshotMode)
        {
            return;
        }

        Bitmap? canvas = _canvas;
        if (canvas == null || _rendering)
        {
            return;
        }

        // Guard against re-entrant paints (Show()/SetBounds can pump a paint while
        // a timer or mouse handler is already drawing).
        _rendering = true;
        try
        {
            RenderResult result;
            using (Graphics g = Graphics.FromImage(canvas))
            {
                g.Clear(Color.Transparent);
                // No ClearType on a transparent layer: subpixel AA leaves coloured fringes.
                g.TextRenderingHint = TextRenderingHint.AntiAliasGridFit;
                g.ScaleTransform(_scale, _scale);
                result = BubbleRenderer.Render(g, _logicalW, _logicalH, _state, _theme);
                g.ResetTransform();
            }

            _lastRender = result;

            if (!_snapshotMode)
            {
                Rectangle destination = destinationOrBounds ?? _bounds;
                PushLayered(destination);
                _bounds = destination;
            }
        }
        finally
        {
            _rendering = false;
        }
    }

    private void CreateSurface()
    {
        DisposeSurface();

        _canvas = new Bitmap(_pxW, _pxH, PixelFormat.Format32bppArgb);
        _canvas.SetResolution(96f, 96f);

        if (_snapshotMode)
        {
            return;
        }

        try
        {
            _memDc = Native.CreateCompatibleDC(IntPtr.Zero);
            if (_memDc == IntPtr.Zero)
            {
                return;
            }

            var bmi = new Native.BITMAPINFO
            {
                bmiHeader = new Native.BITMAPINFOHEADER
                {
                    biSize = System.Runtime.InteropServices.Marshal.SizeOf<Native.BITMAPINFOHEADER>(),
                    biWidth = _pxW,
                    biHeight = -_pxH, // top-down DIB
                    biPlanes = 1,
                    biBitCount = 32,
                    biCompression = 0, // BI_RGB
                    biSizeImage = 0,
                },
            };

            _dib = Native.CreateDIBSection(_memDc, ref bmi, 0, out _dibBits, IntPtr.Zero, 0);
            if (_dib == IntPtr.Zero)
            {
                return;
            }

            _dibOld = Native.SelectObject(_memDc, _dib);
        }
        catch (Exception ex)
        {
            LogInteropOnce(ex);
        }
    }

    private void DisposeSurface()
    {
        try
        {
            if (_memDc != IntPtr.Zero && _dibOld != IntPtr.Zero)
            {
                Native.SelectObject(_memDc, _dibOld);
                _dibOld = IntPtr.Zero;
            }

            if (_dib != IntPtr.Zero)
            {
                Native.DeleteObject(_dib);
                _dib = IntPtr.Zero;
            }

            if (_memDc != IntPtr.Zero)
            {
                Native.DeleteDC(_memDc);
                _memDc = IntPtr.Zero;
            }
        }
        catch (Exception ex)
        {
            LogInteropOnce(ex);
        }

        _dibBits = IntPtr.Zero;
        _canvas?.Dispose();
        _canvas = null;
    }

    /// <summary>
    /// Copies the straight-alpha canvas into the premultiplied DIB and blits it
    /// with UpdateLayeredWindow, which also places/resizes the window atomically.
    /// Failures are swallowed: a missed frame must not take down the message loop.
    /// </summary>
    private unsafe void PushLayered(Rectangle destination)
    {
        Bitmap? canvas = _canvas;
        if (canvas == null || _memDc == IntPtr.Zero || _dibBits == IntPtr.Zero || !IsHandleCreated)
        {
            return;
        }

        int width = _pxW;
        int height = _pxH;
        try
        {
            BitmapData data = canvas.LockBits(
                new Rectangle(0, 0, width, height),
                ImageLockMode.ReadOnly,
                PixelFormat.Format32bppArgb);
            try
            {
                byte* src = (byte*)data.Scan0;
                byte* dst = (byte*)_dibBits;
                int rowBytes = width * 4;
                for (int y = 0; y < height; y++)
                {
                    byte* s = src + (y * data.Stride);
                    byte* d = dst + (y * rowBytes);
                    for (int x = 0; x < width; x++)
                    {
                        byte a = s[3];
                        if (a == 0)
                        {
                            d[0] = 0;
                            d[1] = 0;
                            d[2] = 0;
                            d[3] = 0;
                        }
                        else if (a == 255)
                        {
                            d[0] = s[0];
                            d[1] = s[1];
                            d[2] = s[2];
                            d[3] = 255;
                        }
                        else
                        {
                            d[0] = (byte)((s[0] * a) / 255);
                            d[1] = (byte)((s[1] * a) / 255);
                            d[2] = (byte)((s[2] * a) / 255);
                            d[3] = a;
                        }

                        s += 4;
                        d += 4;
                    }
                }
            }
            finally
            {
                canvas.UnlockBits(data);
            }

            var ptDst = new Native.POINT { X = destination.Left, Y = destination.Top };
            var size = new Native.SIZE { CX = width, CY = height };
            var ptSrc = new Native.POINT { X = 0, Y = 0 };
            var blend = new Native.BLENDFUNCTION
            {
                BlendOp = Native.AC_SRC_OVER,
                BlendFlags = 0,
                SourceConstantAlpha = 255,
                AlphaFormat = Native.AC_SRC_ALPHA,
            };

            IntPtr screenDc = Native.GetDC(IntPtr.Zero);
            try
            {
                Native.UpdateLayeredWindow(
                    Handle,
                    screenDc,
                    ref ptDst,
                    ref size,
                    _memDc,
                    ref ptSrc,
                    0,
                    ref blend,
                    Native.ULW_ALPHA);
            }
            finally
            {
                if (screenDc != IntPtr.Zero)
                {
                    Native.ReleaseDC(IntPtr.Zero, screenDc);
                }
            }
        }
        catch (Exception ex)
        {
            LogInteropOnce(ex);
        }
    }

    // ------------------------------------------------------------------
    // Positioning
    // ------------------------------------------------------------------

    private Rectangle ComputeBounds()
    {
        try
        {
            Screen? screen = TargetScreen();
            Rectangle area = screen?.WorkingArea ?? new Rectangle(0, 0, _pxW, _pxH);
            PointF anchor = _hasAnchor
                ? _anchor
                : new PointF(area.Right - 18f, area.Bottom - 18f);

            int margin = _isDragging ? DragMargin : ResizeMargin;
            int x = (int)Math.Round(anchor.X) - _pxW;
            int y = (int)Math.Round(anchor.Y) - _pxH;

            int minX = area.Left + margin;
            int maxX = Math.Max(minX, area.Right - _pxW - margin);
            int minY = area.Top + margin;
            int maxY = Math.Max(minY, area.Bottom - _pxH - margin);

            x = Math.Clamp(x, minX, maxX);
            y = Math.Clamp(y, minY, maxY);

            return new Rectangle(x, y, _pxW, _pxH);
        }
        catch (Exception ex)
        {
            LogInteropOnce(ex);
            try
            {
                return new Rectangle(Left, Top, _pxW, _pxH);
            }
            catch
            {
                return new Rectangle(0, 0, _pxW, _pxH);
            }
        }
    }

    /// <summary>Screen that owns the anchor; falls back to the screen under the cursor.</summary>
    private Screen? TargetScreen()
    {
        try
        {
            if (_hasAnchor)
            {
                var anchorPoint = new Point((int)Math.Round(_anchor.X), (int)Math.Round(_anchor.Y));
                foreach (Screen screen in Screen.AllScreens)
                {
                    if (screen.WorkingArea.Contains(anchorPoint))
                    {
                        return screen;
                    }
                }
            }

            return Screen.FromPoint(Cursor.Position);
        }
        catch (Exception ex)
        {
            LogInteropOnce(ex);
            try
            {
                return Screen.PrimaryScreen ?? Screen.AllScreens.FirstOrDefault();
            }
            catch
            {
                return null;
            }
        }
    }

    private PointF CurrentAnchor() => new PointF(_bounds.Right, _bounds.Bottom);

    // ------------------------------------------------------------------
    // Interaction: mouse
    // ------------------------------------------------------------------

    protected override void OnMouseMove(MouseEventArgs e)
    {
        base.OnMouseMove(e);

        if (_snapshotMode)
        {
            return;
        }

        if (!_trackingLeave)
        {
            _trackingLeave = Native.TryTrackLeave(Handle);
            OnHoverEnter();
        }

        if (!_pendingDrag)
        {
            return;
        }

        Point now = Cursor.Position;
        int dx = now.X - _dragStartScreen.X;
        int dy = now.Y - _dragStartScreen.Y;

        if (!_isDragging)
        {
            double threshold = DragThresholdDip * _scale;
            if (Math.Sqrt((dx * dx) + (dy * dy)) > threshold)
            {
                _longPressTimer.Stop();
                _pendingDrag = false;
                _toggleRootId = null;
            }

            return;
        }

        DragTo(now);
    }

    protected override void OnMouseDown(MouseEventArgs e)
    {
        base.OnMouseDown(e);

        if (_snapshotMode || e.Button != MouseButtons.Left)
        {
            return;
        }

        if (!_trackingLeave)
        {
            _trackingLeave = Native.TryTrackLeave(Handle);
            OnHoverEnter();
        }

        PointF logical = ToLogical(PointToClient(Cursor.Position));

        // Icon buttons win over both drag and root-toggle handling, and an icon
        // press never starts the long-press drag timer.
        string? icon = HitIcon(logical);
        if (icon != null)
        {
            ActivateIcon(icon);
            return;
        }

        _toggleRootId = HitRoot(logical);
        _pendingDrag = true;
        _isDragging = false;
        _dragStartScreen = Cursor.Position;
        _dragStartOrigin = _bounds.Location;

        _longPressTimer.Stop();
        _longPressTimer.Start();
    }

    protected override void OnMouseUp(MouseEventArgs e)
    {
        base.OnMouseUp(e);

        if (_snapshotMode)
        {
            return;
        }

        _longPressTimer.Stop();

        if (_isDragging)
        {
            EndDrag();
        }
        else if (_toggleRootId != null)
        {
            string rootId = _toggleRootId;
            if (!_state.CollapsedRoots.Remove(rootId))
            {
                _state.CollapsedRoots.Add(rootId);
            }

            _hoverSuppressUntil = DateTime.UtcNow.AddSeconds(HoverSuppressSeconds);
            ApplyLayout();
        }

        _pendingDrag = false;
        _isDragging = false;
        _toggleRootId = null;
    }

    private void OnLongPressTick(object? sender, EventArgs e)
    {
        _longPressTimer.Stop();
        if (!_pendingDrag || _isDragging || _snapshotMode)
        {
            return;
        }

        _isDragging = true;
        _anchor = CurrentAnchor();
        _hasAnchor = true;
        try
        {
            Cursor = Cursors.SizeAll;
        }
        catch
        {
            // Cursor change is cosmetic only.
        }
    }

    private void DragTo(Point screenPosition)
    {
        int dx = screenPosition.X - _dragStartScreen.X;
        int dy = screenPosition.Y - _dragStartScreen.Y;
        int x = _dragStartOrigin.X + dx;
        int y = _dragStartOrigin.Y + dy;

        try
        {
            Rectangle? area = null;
            try
            {
                Screen? screen = Screen.FromPoint(new Point(x + (_pxW / 2), y + (_pxH / 2)));
                area = screen?.WorkingArea;
            }
            catch (Exception ex)
            {
                LogInteropOnce(ex);
            }

            if (area is { Width: > 0, Height: > 0 })
            {
                Rectangle a = area.Value;
                int minX = a.Left + DragMargin;
                int maxX = Math.Max(minX, a.Right - _pxW - DragMargin);
                int minY = a.Top + DragMargin;
                int maxY = Math.Max(minY, a.Bottom - _pxH - DragMargin);
                x = Math.Clamp(x, minX, maxX);
                y = Math.Clamp(y, minY, maxY);
            }

            MoveWindowTo(new Rectangle(x, y, _pxW, _pxH));
        }
        catch (Exception ex)
        {
            LogInteropOnce(ex);
            return;
        }

        _anchor = CurrentAnchor();
        _hasAnchor = true;

        if ((DateTime.UtcNow - _lastAnchorSave).TotalMilliseconds > AnchorSaveMs)
        {
            _lastAnchorSave = DateTime.UtcNow;
            SavePosition();
        }
    }

    /// <summary>
    /// Moves the real window rect without touching the layered surface. Used while
    /// dragging; the content moves with the HWND, so no re-blit is needed.
    /// </summary>
    private void MoveWindowTo(Rectangle rect)
    {
        _bounds = rect;
        if (!IsHandleCreated)
        {
            return;
        }

        Native.SetWindowPos(
            Handle,
            IntPtr.Zero,
            rect.Left,
            rect.Top,
            rect.Width,
            rect.Height,
            Native.SWP_NOZORDER | Native.SWP_NOACTIVATE | Native.SWP_NOOWNERZORDER);
    }

    private void EndDrag()
    {
        _isDragging = false;
        try
        {
            Cursor = Cursors.Default;
        }
        catch
        {
            // Cosmetic.
        }

        _anchor = CurrentAnchor();
        _hasAnchor = true;
        SavePosition();
        ApplyLayout();
    }

    private void OnHoverEnter()
    {
        if (_snapshotMode || _state.Expanded)
        {
            return;
        }

        if (_state.Pinned)
        {
            _state.Expanded = true;
            RenderNow();
            return;
        }

        _state.Expanded = true;
        _state.ScrollOffset = 0f;
        ApplyLayout();
    }

    private void OnHoverLeave()
    {
        if (_snapshotMode || _hiddenForFullscreen)
        {
            return;
        }

        if (DateTime.UtcNow < _hoverSuppressUntil)
        {
            return;
        }

        if (_pendingDrag || _isDragging || _state.Pinned || !_state.Expanded)
        {
            return;
        }

        _state.Expanded = false;
        _state.ScrollOffset = 0f;
        ApplyLayout();
    }

    private void TogglePin()
    {
        _state.Pinned = !_state.Pinned;
        _hoverSuppressUntil = DateTime.UtcNow.AddSeconds(HoverSuppressSeconds);

        if (_state.Pinned)
        {
            _state.Expanded = true;
        }
        else
        {
            try
            {
                if (!_bounds.Contains(Cursor.Position))
                {
                    _state.Expanded = false;
                    _state.ScrollOffset = 0f;
                }
            }
            catch (Exception ex)
            {
                LogInteropOnce(ex);
            }
        }

        _anchor = CurrentAnchor();
        _hasAnchor = true;
        SavePosition();
        ApplyLayout();
    }

    // ------------------------------------------------------------------
    // Icon buttons (pin / desktop sessions)
    // ------------------------------------------------------------------

    /// <summary>Hit-tests the renderer-published icon rects, in logical DIP.</summary>
    private string? HitIcon(PointF logical)
    {
        RenderResult? result = _lastRender;
        if (result?.Icons != null)
        {
            foreach (IconHit hit in result.Icons)
            {
                if (!string.IsNullOrEmpty(hit.Id) && hit.Bounds.Contains(logical))
                {
                    return hit.Id;
                }
            }
        }

        // Fallback only while the renderer does not publish icon rects yet.
        if (_state.Expanded && PinRect().Contains(logical))
        {
            return "pin";
        }

        return null;
    }

    private void ActivateIcon(string id)
    {
        switch (id)
        {
            case "pin":
                TogglePin();
                break;

            case "desktop":
                ToggleIncludeDesktop();
                break;

            default:
                break;
        }
    }

    /// <summary>
    /// Flips the desktop-sessions toggle, redraws the icon immediately and lets
    /// the host persist config.json. The daemon does the actual filtering on its
    /// next refresh, so the row set changes on the following status poll.
    /// </summary>
    private void ToggleIncludeDesktop()
    {
        _state.IncludeDesktop = !_state.IncludeDesktop;
        _hoverSuppressUntil = DateTime.UtcNow.AddSeconds(HoverSuppressSeconds);
        RenderNow();

        try
        {
            IncludeDesktopChanged?.Invoke(_state.IncludeDesktop);
        }
        catch (Exception ex)
        {
            LogInteropOnce(ex);
        }
    }

    // ------------------------------------------------------------------
    // Fullscreen auto-hide
    // ------------------------------------------------------------------

    private static readonly string[] ShellWindowClasses =
    {
        "Progman",
        "WorkerW",
        "Shell_TrayWnd",
        "Shell_SecondaryTrayWnd",
        "MultitaskingViewFrame",
        "TaskSwitcherWnd",
        "ForegroundStaging",
    };

    /// <summary>
    /// Hosts that can stretch over a whole monitor without being the app the user
    /// is actually in (IME/touch keyboard, shell flyouts, third-party overlays).
    /// Hiding the bubble for these would be a false positive.
    /// </summary>
    private static readonly string[] IgnoredFullscreenProcesses =
    {
        "TextInputHost.exe",
        "ShellExperienceHost.exe",
        "StartMenuExperienceHost.exe",
        "SearchHost.exe",
        "GameBar.exe",
        "GameBarFTServer.exe",
        "NVIDIA Share.exe",
        "NVIDIA Overlay.exe",
    };

    /// <summary>
    /// Hides the bubble while another process owns a fullscreen window on the
    /// bubble's monitor, and restores it (same place, without activation) when
    /// that window goes away. Called from the 500 ms reload timer.
    /// </summary>
    public void UpdateFullscreenVisibility()
    {
        if (_snapshotMode || !IsHandleCreated)
        {
            return;
        }

        bool shouldHide = _hideOnFullscreen && IsFullscreenForegroundOnBubbleMonitor();
        if (shouldHide == _hiddenForFullscreen)
        {
            // Watchdog: the OS visibility must agree with the flag. Without this a
            // missed transition (window hidden while the flag says visible, or the
            // reverse) would persist until some unrelated transition happened.
            bool visible = Native.IsWindowVisible(Handle);
            if (shouldHide ? visible : !visible)
            {
                if (shouldHide)
                {
                    HideForFullscreen();
                }
                else
                {
                    RestoreFromFullscreen();
                }
            }

            return;
        }

        if (shouldHide)
        {
            HideForFullscreen();
        }
        else
        {
            RestoreFromFullscreen();
        }
    }

    private void HideForFullscreen()
    {
        try
        {
            _hiddenForFullscreen = true;
            _layoutDirty = false;

            // Drop transient interaction state: the window is off screen.
            _longPressTimer.Stop();
            _pendingDrag = false;
            _isDragging = false;
            _toggleRootId = null;
            _trackingLeave = false;

            Native.ShowWindow(Handle, Native.SW_HIDE);
        }
        catch (Exception ex)
        {
            LogInteropOnce(ex);
        }
    }

    private void RestoreFromFullscreen()
    {
        try
        {
            _hiddenForFullscreen = false;

            Native.ShowWindow(Handle, Native.SW_SHOWNOACTIVATE);
            Native.SetWindowPos(
                Handle,
                Native.HWND_TOPMOST,
                0,
                0,
                0,
                0,
                Native.SWP_NOMOVE | Native.SWP_NOSIZE | Native.SWP_NOACTIVATE
                    | Native.SWP_NOOWNERZORDER | Native.SWP_SHOWWINDOW);

            if (_layoutDirty)
            {
                _layoutDirty = false;
                ApplyLayout();
            }
            else
            {
                // Re-blit at the tracked rect: same position, no activation.
                RenderFrame(_bounds);
            }
        }
        catch (Exception ex)
        {
            LogInteropOnce(ex);
        }
    }

    private bool IsFullscreenForegroundOnBubbleMonitor()
    {
        try
        {
            IntPtr foreground = Native.GetForegroundWindow();
            if (foreground == IntPtr.Zero || foreground == Handle)
            {
                return false;
            }

            if (!Native.IsWindowVisible(foreground) || Native.IsIconic(foreground))
            {
                return false;
            }

            Native.GetWindowThreadProcessId(foreground, out uint processId);
            if (processId == (uint)Environment.ProcessId)
            {
                return false;
            }

            // Shell hosts and overlays can cover the monitor without being the app
            // the user is actually in (IME, touch keyboard, Game Bar, NVIDIA overlay).
            string processName = Native.GetProcessImageName(processId);
            foreach (string ignored in IgnoredFullscreenProcesses)
            {
                if (string.Equals(processName, ignored, StringComparison.OrdinalIgnoreCase))
                {
                    return false;
                }
            }

            // Layered / click-through windows are overlays (in-game HUDs, capture
            // rings, tooltips), never the fullscreen app itself.
            long exStyle = (long)Native.GetWindowLongPtr(foreground, Native.GWL_EXSTYLE);
            const long overlayStyles = Native.WS_EX_LAYERED | Native.WS_EX_TRANSPARENT;
            if ((exStyle & overlayStyles) != 0)
            {
                return false;
            }

            string className = Native.GetClassName(foreground);
            foreach (string shellClass in ShellWindowClasses)
            {
                if (string.Equals(className, shellClass, StringComparison.Ordinal))
                {
                    return false;
                }
            }

            if (!Native.GetWindowRect(foreground, out Native.RECT windowRect))
            {
                return false;
            }

            IntPtr monitor = Native.MonitorFromWindow(foreground, Native.MONITOR_DEFAULTTONEAREST);
            if (monitor == IntPtr.Zero)
            {
                return false;
            }

            var info = new Native.MONITORINFO { cbSize = Marshal.SizeOf<Native.MONITORINFO>() };
            if (!Native.GetMonitorInfo(monitor, ref info))
            {
                return false;
            }

            // Fullscreen means the window rect covers the *monitor* rect, not the
            // work area: a maximised window must never hide the bubble.
            const int tolerance = 2;
            bool covers = windowRect.Left <= info.rcMonitor.Left + tolerance
                          && windowRect.Top <= info.rcMonitor.Top + tolerance
                          && windowRect.Right >= info.rcMonitor.Right - tolerance
                          && windowRect.Bottom >= info.rcMonitor.Bottom - tolerance;
            if (!covers)
            {
                return false;
            }

            IntPtr bubbleMonitor = Native.MonitorFromWindow(Handle, Native.MONITOR_DEFAULTTONEAREST);
            return bubbleMonitor != IntPtr.Zero && bubbleMonitor == monitor;
        }
        catch (Exception ex)
        {
            LogInteropOnce(ex);
            return false;
        }
    }

    private void OnWheel(int rawDelta)
    {
        if (_snapshotMode || !_state.Expanded)
        {
            return;
        }

        RenderResult? result = _lastRender;
        if (result == null)
        {
            return;
        }

        float maxOffset = Math.Max(0f, result.ContentHeight - result.ViewportHeight);
        if (maxOffset <= 0f)
        {
            return;
        }

        float step = rawDelta / 120f * WheelStepPerNotch;
        float next = Math.Clamp(_state.ScrollOffset - step, 0f, maxOffset);
        if (Math.Abs(next - _state.ScrollOffset) < 0.01f)
        {
            return;
        }

        _state.ScrollOffset = next;
        RenderNow();
    }

    private bool ClampScroll()
    {
        RenderResult? result = _lastRender;
        if (result == null)
        {
            return false;
        }

        float maxOffset = Math.Max(0f, result.ContentHeight - result.ViewportHeight);
        float clamped = Math.Clamp(_state.ScrollOffset, 0f, maxOffset);
        if (Math.Abs(clamped - _state.ScrollOffset) < 0.01f)
        {
            return false;
        }

        _state.ScrollOffset = clamped;
        return true;
    }

    private RectangleF PinRect()
    {
        return new RectangleF(_logicalW - PinRight - PinSize, PinTop, PinSize, PinSize);
    }

    private PointF ToLogical(Point client)
    {
        float scale = _scale <= 0f ? 1f : _scale;
        return new PointF(client.X / scale, client.Y / scale);
    }

    private string? HitRoot(PointF logical)
    {
        RenderResult? result = _lastRender;
        if (result == null)
        {
            return null;
        }

        foreach (RootRowHit hit in result.RootRows)
        {
            if (!hit.Bounds.Contains(logical))
            {
                continue;
            }

            if (!string.IsNullOrEmpty(hit.RootId) && RootHasActiveChildren(hit.RootId))
            {
                return hit.RootId;
            }
        }

        return null;
    }

    private bool RootHasActiveChildren(string rootId)
    {
        foreach (RootSession root in _state.Roots)
        {
            if (root.Id != rootId)
            {
                continue;
            }

            foreach (ChildAgent child in root.Children)
            {
                if (child.Active)
                {
                    return true;
                }
            }

            return false;
        }

        return false;
    }

    // ------------------------------------------------------------------
    // Window messages
    // ------------------------------------------------------------------

    protected override void WndProc(ref Message m)
    {
        switch (m.Msg)
        {
            case Native.WM_MOUSEACTIVATE:
                // Never take focus away from the foreground app.
                m.Result = (IntPtr)Native.MA_NOACTIVATE;
                return;

            case Native.WM_ERASEBKGND:
                m.Result = (IntPtr)1;
                return;

            case Native.WM_MOUSELEAVE:
                _trackingLeave = false;
                try
                {
                    // Moving/resizing a layered window can make the system report a
                    // leave while the cursor is still inside: re-arm and keep hover.
                    if (!_snapshotMode
                        && IsHandleCreated
                        && _bounds.Contains(Cursor.Position))
                    {
                        _trackingLeave = Native.TryTrackLeave(Handle);
                        return;
                    }

                    OnHoverLeave();
                }
                catch (Exception ex)
                {
                    LogInteropOnce(ex);
                }

                return;

            case Native.WM_MOUSEWHEEL:
                try
                {
                    int raw = (int)(((long)m.WParam >> 16) & 0xFFFF);
                    OnWheel((short)raw);
                }
                catch (Exception ex)
                {
                    LogInteropOnce(ex);
                }

                return;

            case Native.WM_WINDOWPOSCHANGED:
                base.WndProc(ref m);
                try
                {
                    // Any move we did not initiate (system, another app) is adopted
                    // into the tracked rect. Our own UpdateLayeredWindow blits never
                    // produce this message, and drags already set it beforehand.
                    if (!_snapshotMode
                        && !_rendering
                        && IsHandleCreated
                        && Native.GetWindowRect(Handle, out Native.RECT actual)
                        && actual.Right > actual.Left
                        && actual.Bottom > actual.Top)
                    {
                        var rect = Rectangle.FromLTRB(actual.Left, actual.Top, actual.Right, actual.Bottom);
                        if (rect != _bounds)
                        {
                            _bounds = rect;
                        }
                    }
                }
                catch (Exception ex)
                {
                    LogInteropOnce(ex);
                }

                return;

            case Native.WM_DPICHANGED:
                try
                {
                    OnDpiChanged();
                }
                catch (Exception ex)
                {
                    LogInteropOnce(ex);
                }

                m.Result = IntPtr.Zero;
                return;

            case Native.WM_DISPLAYCHANGE:
                // A resolution / monitor change can leave the anchor off-screen.
                try
                {
                    if (!_snapshotMode)
                    {
                        ApplyLayout();
                    }
                }
                catch (Exception ex)
                {
                    LogInteropOnce(ex);
                }

                break;
        }

        base.WndProc(ref m);
    }

    private void OnDpiChanged()
    {
        if (_snapshotMode || !IsHandleCreated)
        {
            return;
        }

        float newScale = GetScale();
        if (Math.Abs(newScale - _scale) < 0.001f)
        {
            return;
        }

        // Keep the Right/Bottom anchor: the window may change physical size.
        ApplyLayout();
    }

    private float GetScale()
    {
        try
        {
            if (IsHandleCreated)
            {
                uint dpi = Native.GetDpiForWindow(Handle);
                if (dpi >= 48 && dpi <= 480)
                {
                    return dpi / 96f;
                }
            }

            int deviceDpi = DeviceDpi;
            if (deviceDpi >= 48 && deviceDpi <= 480)
            {
                return deviceDpi / 96f;
            }
        }
        catch (Exception ex)
        {
            LogInteropOnce(ex);
        }

        return 1f;
    }

    // ------------------------------------------------------------------
    // Snapshot
    // ------------------------------------------------------------------

    /// <summary>
    /// Renders the current state into the canvas and writes it as PNG. Works
    /// without a visible window (and without a desktop session) because the
    /// canvas is a plain GDI+ bitmap.
    /// </summary>
    public bool SaveSnapshot(string path)
    {
        try
        {
            RenderFrame(null);
            Bitmap? canvas = _canvas;
            if (canvas == null)
            {
                return false;
            }

            string full = Path.GetFullPath(path);
            string? dir = Path.GetDirectoryName(full);
            if (!string.IsNullOrEmpty(dir))
            {
                Directory.CreateDirectory(dir);
            }

            // The GDI+ PNG encoder only accepts images whose pixels it owns. The
            // on-screen canvas is an ordinary GDI+ bitmap today, but copying it
            // keeps the export valid if it ever becomes DIB-section backed.
            using (var copy = new Bitmap(canvas.Width, canvas.Height, PixelFormat.Format32bppArgb))
            {
                copy.SetResolution(96f, 96f);
                using (Graphics g = Graphics.FromImage(copy))
                {
                    g.CompositingMode = CompositingMode.SourceCopy;
                    g.DrawImageUnscaled(canvas, 0, 0);
                }

                copy.Save(full, ImageFormat.Png);
            }

            return true;
        }
        catch (Exception ex)
        {
            Bitmap? canvas = _canvas;
            Stderr(
                "snapshot save failed: " + ex.Message
                + (canvas == null
                    ? " (no canvas)"
                    : string.Format(
                        CultureInfo.InvariantCulture,
                        " (canvas {0}x{1} {2} dpi={3})",
                        canvas.Width,
                        canvas.Height,
                        canvas.PixelFormat,
                        canvas.HorizontalResolution)));
            LogRenderOnce(ex);
            return false;
        }
    }

    // ------------------------------------------------------------------
    // position.json  ({ "x": Right, "y": Bottom, "pinned": bool })
    // ------------------------------------------------------------------

    private static string PositionPath()
    {
        string home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        return Path.Combine(home, ".dsh", "run-bubble", "position.json");
    }

    private void LoadPosition()
    {
        try
        {
            string path = PositionPath();
            if (!File.Exists(path))
            {
                return;
            }

            using JsonDocument doc = JsonDocument.Parse(File.ReadAllText(path));
            JsonElement root = doc.RootElement;
            if (root.ValueKind != JsonValueKind.Object)
            {
                return;
            }

            if (root.TryGetProperty("x", out JsonElement x)
                && root.TryGetProperty("y", out JsonElement y)
                && x.ValueKind == JsonValueKind.Number
                && y.ValueKind == JsonValueKind.Number)
            {
                _anchor = new PointF((float)x.GetDouble(), (float)y.GetDouble());
                _hasAnchor = true;
            }

            if (root.TryGetProperty("pinned", out JsonElement pinned)
                && (pinned.ValueKind == JsonValueKind.True || pinned.ValueKind == JsonValueKind.False))
            {
                _state.Pinned = pinned.GetBoolean();
            }
        }
        catch
        {
            // A corrupt position file must never block startup.
        }
    }

    private void SavePosition()
    {
        try
        {
            string path = PositionPath();
            string? dir = Path.GetDirectoryName(path);
            if (!string.IsNullOrEmpty(dir))
            {
                Directory.CreateDirectory(dir);
            }

            string payload = string.Format(
                CultureInfo.InvariantCulture,
                "{{\"x\":{0},\"y\":{1},\"pinned\":{2}}}",
                Math.Round(_anchor.X, 2),
                Math.Round(_anchor.Y, 2),
                _state.Pinned ? "true" : "false");

            string tmp = path + ".tmp-" + Environment.ProcessId.ToString(CultureInfo.InvariantCulture);
            File.WriteAllText(tmp, payload);
            File.Move(tmp, path, overwrite: true);
        }
        catch
        {
            // Best effort persistence only.
        }
    }

    // ------------------------------------------------------------------
    // Diagnostics / disposal
    // ------------------------------------------------------------------

    private static void Stderr(string message)
    {
        try
        {
            Console.Error.WriteLine("[overlay] " + message);
        }
        catch
        {
            // No console.
        }
    }

    private void LogRenderOnce(Exception ex)
    {
        if (_renderErrorLogged)
        {
            return;
        }

        _renderErrorLogged = true;
        Stderr("render failed: " + ex);
    }

    private void LogInteropOnce(Exception ex)
    {
        if (_interopErrorLogged)
        {
            return;
        }

        _interopErrorLogged = true;
        Stderr("window operation failed: " + ex.Message);
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            try
            {
                _longPressTimer.Stop();
                _longPressTimer.Dispose();
            }
            catch
            {
                // Ignore.
            }

            DisposeSurface();
        }

        base.Dispose(disposing);
    }
}
