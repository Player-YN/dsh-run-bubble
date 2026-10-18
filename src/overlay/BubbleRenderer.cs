// BubbleRenderer.cs — pure GDI+ painting for the run-bubble overlay.
// Translation of BubbleView.draw / makeRows / drawRow / drawChips from
// overlay.swift into C# with a top-left origin (y grows downwards).
//
// Swift conversions used throughout:
//   * a Swift rect (x, yBottom, w, h) becomes (x, height - yBottom - h, w, h)
//   * a Swift "top" value (distance of the row's text top from the panel top)
//     stays a top edge; text is drawn with its typographic line-box top at
//     that value (StringFormat.GenericTypographic == AppKit draw(at:)).
//   * the body region is clipped to [38, height - 34] (idle: [38, height]).
//
// Nothing here may touch window handles, DPI or the caller's transform.

using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Text;

namespace DshRunBubble;

/// <summary>What one <see cref="BubbleRenderer.Render"/> call produced.</summary>
public sealed class RenderResult
{
    /// <summary>Clickable rows for roots that own (active) children, viewport DIP, top-left origin, scroll applied.</summary>
    public List<RootRowHit> RootRows = new();

    /// <summary>Clickable header icon buttons (§11.2), panel DIP, top-left origin, no scroll.</summary>
    public List<IconHit> Icons = new();

    /// <summary>Height of all body rows plus 10px of bottom breathing room (Swift contentHeight).</summary>
    public float ContentHeight;

    /// <summary>Visible body height used for scrolling.</summary>
    public float ViewportHeight;

    /// <summary>Panel height the window layer should use for this state.</summary>
    public float PreferredHeight;
}

/// <summary>Stateless drawing/layout engine for the bubble panel.</summary>
public static class BubbleRenderer
{
    // Layout constants, identical to overlay.swift.
    public const float Pad = 12f;
    public const float HeaderHeight = 30f;
    public const float FooterHeight = 28f;
    public const float BodyTop = HeaderHeight + 8f;      // 38
    public const float PanelRadius = 13f;
    public const float ExpandedWidth = 356f;
    public const float MaxPanelHeight = 420f;
    public const float MinPanelHeight = 96f;
    public const float RowIndent = 22f;

    // Collapsed pill, §11.1 (v0.3.1): 26 tall, content-sized width.
    public const float CollapsedHeight = 26f;
    public const float PillPad = 9f;
    public const float PillDot = 7f;
    public const float PillGap = 7f;
    public const float PillLabelX = PillPad + PillDot + PillGap;   // 23
    public const float MinCollapsedWidth = 52f;
    /// <summary>Upper bound for the content-sized pill; use <see cref="PreferredWidth"/>.</summary>
    public const float CollapsedWidth = 238f;

    // Header icon button ids returned in <see cref="RenderResult.Icons"/> (§11.2).
    public const string IconIdDesktop = "desktop";
    public const string IconIdPin = "pin";

    // Expanded header icon buttons: 18x18 at y=6, 14px from the right edge.
    private const float IconSize = 18f;
    private const float IconTop = 6f;
    private const float IconPinRight = 32f;
    private const float IconDesktopRight = 54f;

    // Segoe UI's ascent is heavier than SF Pro's, so a plain (h - lineHeight)/2
    // leaves glyph ink ~2px high inside the 26px capsule; these nudges put the
    // ink's optical centre on the panel's centre line (measured, not guessed).
    private const float PillTextNudge = 1.75f;
    private const float PillBadgeNudge = 1f;

    private enum RowKind
    {
        Root,
        Meta,
        Task,
        Child,
        Empty,
        Divider,
    }

    private enum ChipStyle
    {
        Source,
        Id,
        Count,
        Plain,
        Effort,
        Turn,
    }

    private sealed class Chip
    {
        public string Text = "";
        public ChipStyle Style;
        public int ColorIndex;
    }

    private sealed class Row
    {
        public RowKind Kind;
        public string Text = "";
        public string Secondary = "";
        public string Time = "";
        public float Indent;
        public float Height;
        public int ColorIndex;
        public Chip[] Chips = Array.Empty<Chip>();
        public string RootId = "";
        public int ChildCount;
        public bool BackArrow;
    }

    private static readonly StringFormat Typographic = CreateTypographicFormat();

    // PreferredWidth() has no Graphics parameter, so content measurement runs on
    // a tiny off-screen surface. Fonts are palette-independent, so one light
    // Theme instance supplies the cached font objects for measurement.
    private static readonly Lazy<Theme> MeasureTheme = new(() => Theme.Create(dark: false));
    private static readonly object MeasureSync = new();
    private static Bitmap? _measureSurface;
    private static Graphics? _measureGraphics;

    // ------------------------------------------------------------------
    // Public API (frozen, see docs/PORT-WINDOWS.md §7)
    // ------------------------------------------------------------------

    /// <summary>Panel height for the given state, in logical DIP. Does not draw.</summary>
    public static float PreferredHeight(BubbleState state)
    {
        if (state == null || !state.Expanded)
        {
            return CollapsedHeight;
        }

        List<Row> rows = BuildRows(state);
        float natural = HeaderHeight + ContentHeight(rows) +
                        (IsIdle(state) ? 0f : FooterHeight) + 14f;
        return Math.Min(MaxPanelHeight, Math.Max(MinPanelHeight, natural));
    }

    /// <summary>
    /// Panel width for the given state, in logical DIP. Expanded stays at 356;
    /// the collapsed pill sizes itself to its content (52..238, §11.1).
    /// </summary>
    public static float PreferredWidth(BubbleState state)
    {
        if (state == null || state.Expanded)
        {
            return ExpandedWidth;
        }

        return PillWidth(MeasureGraphics(), state);
    }

    /// <summary>
    /// Content width of the collapsed pill:
    /// <c>9 + 7 + 7 + labelW + [8 + badgeBoxW] + [8 + timeW] + 9</c>, clamped.
    /// </summary>
    private static float PillWidth(Graphics g, BubbleState state)
    {
        HeaderParts parts = HeaderContent(state);
        Font headerFont = MeasureFont(11.5f, semibold: true, mono: false);
        Font timeFont = MeasureFont(11.5f, semibold: true, mono: true);
        Font badgeFont = MeasureFont(9.5f, semibold: true, mono: false);

        float width = PillPad + PillDot + PillGap + Measure(g, parts.Label, headerFont).Width;
        if (parts.Badge.Length > 0)
        {
            // 8px gap + the 14px-high badge box (text + 4px padding on each side).
            width += 8f + Measure(g, parts.Badge, badgeFont).Width + 8f;
        }

        if (parts.Time.Length > 0)
        {
            width += 8f + Measure(g, parts.Time, timeFont).Width;
        }

        width += PillPad;
        return Math.Min(CollapsedWidth, Math.Max(MinCollapsedWidth, width));
    }

    /// <summary>
    /// Draw the complete panel (background, rounded border, header, body,
    /// scrollbar and footer) into <paramref name="g"/> using a top-left DIP
    /// coordinate system. Caller owns the graphics transform (DPI scaling).
    /// </summary>
    public static RenderResult Render(Graphics g, float width, float height, BubbleState state, Theme theme)
    {
        var result = new RenderResult();
        if (g == null || theme == null || width <= 0f || height <= 0f)
        {
            return result;
        }

        state ??= new BubbleState();
        List<RootSession> roots = state.Roots ?? new List<RootSession>();
        bool idle = roots.Count == 0;
        bool expanded = state.Expanded;

        GraphicsState graphicsState = g.Save();
        try
        {
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.TextRenderingHint = TextRenderingHint.AntiAliasGridFit;

            DrawPanel(g, width, height, theme);

            HeaderParts header = HeaderContent(state);
            if (expanded)
            {
                DrawExpandedHeader(g, width, theme, state, header, result);
            }
            else
            {
                DrawPillHeader(g, width, height, theme, state, header);
                result.PreferredHeight = CollapsedHeight;
                return result;
            }

            // Header separator (only in the expanded panel).
            using (var rulePen = new Pen(theme.HeaderSeparator, 1f))
            {
                g.DrawLine(rulePen, Pad, HeaderHeight, width - Pad, HeaderHeight);
            }

            List<Row> rows = BuildRows(state);
            float content = ContentHeight(rows);
            float footerReserve = idle ? 0f : FooterHeight + 6f;          // 34
            float viewport = Math.Max(0f, height - BodyTop - footerReserve);
            float maxOffset = Math.Max(0f, content - viewport);
            float offset = Math.Min(Math.Max(0f, state.ScrollOffset), maxOffset);
            float bodyBottom = idle ? 0f : FooterHeight + 6f;
            float clipHeight = Math.Max(0f, height - BodyTop - bodyBottom);

            var hits = new List<RootRowHit>();
            GraphicsState bodyState = g.Save();
            try
            {
                if (clipHeight > 0f)
                {
                    g.SetClip(new RectangleF(0f, BodyTop, width, clipHeight));
                }

                float rowTop = BodyTop - offset;
                foreach (Row row in rows)
                {
                    if (row.Kind == RowKind.Root && row.ChildCount > 0)
                    {
                        hits.Add(new RootRowHit(row.RootId, new RectangleF(0f, rowTop, width, row.Height)));
                    }

                    if (rowTop + row.Height >= BodyTop && rowTop <= BodyTop + viewport)
                    {
                        DrawRow(g, row, rowTop, width, theme, state);
                    }

                    rowTop += row.Height;
                }
            }
            finally
            {
                g.Restore(bodyState);
            }

            result.RootRows = hits;

            if (!idle && content > viewport && maxOffset > 0f)
            {
                DrawScrollbar(g, width, viewport, content, offset, maxOffset, theme);
            }

            if (!idle)
            {
                DrawFooter(g, width, height, roots, theme);
            }

            result.ContentHeight = content;
            result.ViewportHeight = viewport;
            result.PreferredHeight = PreferredHeight(state);
        }
        finally
        {
            g.Restore(graphicsState);
        }

        return result;
    }

    // ------------------------------------------------------------------
    // Panel / chrome
    // ------------------------------------------------------------------

    private static void DrawPanel(Graphics g, float width, float height, Theme theme)
    {
        var rect = new RectangleF(0.5f, 0.5f, width - 1f, height - 1f);
        using GraphicsPath path = RoundedRectPath(rect, PanelRadius);
        using (var fill = new SolidBrush(theme.Bg))
        {
            g.FillPath(fill, path);
        }

        using var borderPen = new Pen(theme.Border, 1f);
        g.DrawPath(borderPen, path);
    }

    // ------------------------------------------------------------------
    // Header: expanded panel vs collapsed pill (§11.1, §11.2)
    // ------------------------------------------------------------------

    private readonly struct HeaderParts
    {
        public readonly string Label;
        public readonly string Time;
        public readonly string Badge;

        public HeaderParts(string label, string time, string badge)
        {
            Label = label ?? "";
            Time = time ?? "";
            Badge = badge ?? "";
        }
    }

    /// <summary>
    /// The strings the header shows for one state. A collapsed *idle* pill has
    /// neither a time nor a badge — just "空闲" — so it can shrink to ~55px.
    /// </summary>
    private static HeaderParts HeaderContent(BubbleState state)
    {
        List<RootSession> roots = state.Roots ?? new List<RootSession>();
        bool idle = roots.Count == 0;
        bool expanded = state.Expanded;

        string label = idle
            ? "空闲"
            : roots.Count == 1
                ? "外部任务运行中"
                : roots.Count + " 个外部任务";
        string time = idle
            ? (expanded ? "—" : "")
            : FormatDuration(MaxElapsed(roots));
        int activeChildren = CountActiveChildren(roots);
        string badge = activeChildren > 0 && (expanded || !idle) ? activeChildren + " 子" : "";

        return new HeaderParts(label, time, badge);
    }

    private static void DrawExpandedHeader(
        Graphics g, float width, Theme theme, BubbleState state, HeaderParts parts, RenderResult result)
    {
        const float headerTop = 7f;
        Font headerFont = theme.Font(11.5f, semibold: true, mono: false);
        Font timeFont = theme.Font(11.5f, semibold: true, mono: true);
        Font badgeFont = theme.Font(9.5f, semibold: true, mono: false);

        List<RootSession> roots = state.Roots ?? new List<RootSession>();
        bool idle = roots.Count == 0;
        float pulse = Clamp01(state.Pulse);

        float timeWidth = Measure(g, parts.Time, timeFont).Width;
        // Two 18px icon buttons sit at the right edge (desktop, then pin), so the
        // time/badge cluster ends 44px from the margin instead of 22px.
        float timeRight = width - 14f - 44f;
        float badgeTextWidth = parts.Badge.Length > 0 ? Measure(g, parts.Badge, badgeFont).Width : 0f;
        float badgeWidth = badgeTextWidth + 8f;
        float badgeRight = timeRight - timeWidth - 8f;
        float badgeLeft = badgeRight - badgeWidth;

        // Status dot: 7x7, 9px from the top (Swift y = height-16).
        Color dotColor = idle
            ? theme.WithAlpha(theme.Muted, 0.55)
            : theme.WithAlpha(theme.Accent, 0.95 * pulse + 0.05);
        FillEllipse(g, dotColor, Pad, 9f, 7f, 7f);

        // Title, clipped by the time (and badge) on the right.
        float labelX = Pad + 13f;
        float labelLimit = timeRight - 6f;
        if (parts.Badge.Length > 0)
        {
            labelLimit = Math.Min(labelLimit, badgeLeft - 6f);
        }

        string headerLabel = TruncateByWidth(g, parts.Label, 18, labelLimit - labelX, headerFont);
        DrawTextTop(g, headerLabel, headerFont, idle ? theme.Muted : theme.Fg, labelX, headerTop);
        DrawTextRight(g, parts.Time, timeFont, theme.Fg, timeRight, headerTop, mono: true);

        if (parts.Badge.Length > 0)
        {
            using (GraphicsPath badgePath = RoundedRectPath(
                       new RectangleF(badgeLeft, 7f, badgeWidth, 14f), 7f))
            using (var badgeBrush = new SolidBrush(theme.BadgeBg))
            {
                g.FillPath(badgeBrush, badgePath);
            }

            DrawTextTop(g, parts.Badge, badgeFont, theme.Muted, badgeLeft + 4f, 7.5f);
        }

        // Icon buttons (§11.2): desktop-sessions toggle left of the pin.
        var desktopRect = new RectangleF(width - IconDesktopRight, IconTop, IconSize, IconSize);
        DrawDesktopIcon(
            g, desktopRect.X, desktopRect.Y, IconSize,
            state.IncludeDesktop ? theme.Accent : theme.Muted, state.IncludeDesktop);
        result.Icons.Add(new IconHit(IconIdDesktop, desktopRect));

        var pinRect = new RectangleF(width - IconPinRight, IconTop, IconSize, IconSize);
        DrawPin(g, pinRect.X, pinRect.Y, IconSize, state.Pinned ? theme.Accent : theme.Muted, state.Pinned);
        result.Icons.Add(new IconHit(IconIdPin, pinRect));
    }

    /// <summary>
    /// Collapsed pill: 9px padding, dot at x=9, label at x=23, time right-aligned
    /// at <c>width - 9</c>, everything vertically centred in the 26px capsule.
    /// </summary>
    private static void DrawPillHeader(
        Graphics g, float width, float height, Theme theme, BubbleState state, HeaderParts parts)
    {
        Font headerFont = theme.Font(11.5f, semibold: true, mono: false);
        Font timeFont = theme.Font(11.5f, semibold: true, mono: true);
        Font badgeFont = theme.Font(9.5f, semibold: true, mono: false);

        List<RootSession> roots = state.Roots ?? new List<RootSession>();
        bool idle = roots.Count == 0;

        float right = width - PillPad;
        float timeWidth = parts.Time.Length > 0 ? Measure(g, parts.Time, timeFont).Width : 0f;
        float timeLeft = right - timeWidth;
        float badgeTextWidth = parts.Badge.Length > 0 ? Measure(g, parts.Badge, badgeFont).Width : 0f;
        float badgeWidth = badgeTextWidth + 8f;
        float badgeRight = parts.Time.Length > 0 ? timeLeft - 8f : right;
        float badgeLeft = badgeRight - badgeWidth;
        float contentRight = parts.Badge.Length > 0
            ? badgeLeft
            : parts.Time.Length > 0
                ? timeLeft
                : right;

        float textTop = (height - headerFont.GetHeight(g)) / 2f + PillTextNudge;

        // Status dot: 7x7 at x=9, vertically centred.
        Color dotColor = idle
            ? theme.WithAlpha(theme.Muted, 0.55)
            : theme.WithAlpha(theme.Accent, 0.95 * Clamp01(state.Pulse) + 0.05);
        FillEllipse(g, dotColor, PillPad, (height - PillDot) / 2f, PillDot, PillDot);

        // The pill width is derived from this content, so the label only needs
        // truncating when the window clamped the width down to the minimum. The
        // 6px gutter only applies when a badge or time follows the label.
        bool hasRightContent = parts.Badge.Length > 0 || parts.Time.Length > 0;
        float labelMax = Math.Max(1f, contentRight - (hasRightContent ? 6f : 0f) - PillLabelX + 1f);
        string label = TruncateByWidth(g, parts.Label, 18, labelMax, headerFont);
        DrawTextTop(g, label, headerFont, idle ? theme.Muted : theme.Fg, PillLabelX, textTop);

        if (parts.Time.Length > 0)
        {
            DrawTextRight(g, parts.Time, timeFont, theme.Fg, right, textTop, mono: true);
        }

        if (parts.Badge.Length > 0)
        {
            float badgeTop = (height - 14f) / 2f;
            using (GraphicsPath badgePath = RoundedRectPath(
                       new RectangleF(badgeLeft, badgeTop, badgeWidth, 14f), 7f))
            using (var badgeBrush = new SolidBrush(theme.BadgeBg))
            {
                g.FillPath(badgeBrush, badgePath);
            }

            float badgeTextTop = badgeTop + (14f - badgeFont.GetHeight(g)) / 2f + PillBadgeNudge;
            DrawTextTop(g, parts.Badge, badgeFont, theme.Muted, badgeLeft + 4f, badgeTextTop);
        }
    }

    // ------------------------------------------------------------------
    // Desktop-sessions icon (vector: monitor outline + stand, §11.2)
    // ------------------------------------------------------------------

    private static void DrawDesktopIcon(Graphics g, float x, float y, float size, Color color, bool filled)
    {
        const float ScreenWidth = 12f;
        const float ScreenHeight = 9f;
        const float BaseWidth = 5f;
        const float BaseHeight = 1.5f;
        const float Gap = 1.5f;

        // 12x9 screen + 1.5px gap + 5x1.5 stand = a 12px block, centred in `size`.
        float blockHeight = ScreenHeight + Gap + BaseHeight;
        float top = y + (size - blockHeight) / 2f;
        float left = x + (size - ScreenWidth) / 2f;
        float baseLeft = x + (size - BaseWidth) / 2f;
        float baseTop = top + ScreenHeight + Gap;

        using GraphicsPath screen = RoundedRectPath(
            new RectangleF(left, top, ScreenWidth, ScreenHeight), 2f);
        using GraphicsPath baseBar = RoundedRectPath(
            new RectangleF(baseLeft, baseTop, BaseWidth, BaseHeight), 0.75f);

        if (filled)
        {
            using var brush = new SolidBrush(color);
            g.FillPath(brush, screen);
            g.FillPath(brush, baseBar);
            return;
        }

        using var pen = new Pen(color, 1.2f)
        {
            LineJoin = LineJoin.Round,
            StartCap = LineCap.Round,
            EndCap = LineCap.Round,
        };
        g.DrawPath(pen, screen);

        using var baseBrush = new SolidBrush(color);
        g.FillPath(baseBrush, baseBar);
    }

    private static void DrawFooter(Graphics g, float width, float height, List<RootSession> roots, Theme theme)
    {
        using (var rulePen = new Pen(theme.HeaderSeparator, 1f))
        {
            float ruleY = height - (FooterHeight - 6f);
            g.DrawLine(rulePen, Pad, ruleY, width - Pad, ruleY);
        }

        Tokens total = TotalTokens(roots);
        Font tokenFont = theme.Font(10f, semibold: false, mono: false);
        Font detailFont = theme.Font(9.5f, semibold: false, mono: true);

        string tokenText = "Token " + FormatCompact(total.Total);
        float tokenTop = height - 8f - tokenFont.GetHeight(g);
        DrawText(g, tokenText, tokenFont, theme.Muted, Pad, tokenTop);

        string detail = "入 " + FormatCompact(total.Input) +
                        "   出 " + FormatCompact(total.Output) +
                        "   缓存 " + FormatCompact(total.CacheRead);
        float detailWidth = Measure(g, detail, detailFont).Width;
        float detailTop = height - 8f - detailFont.GetHeight(g);
        DrawText(g, detail, detailFont, theme.Muted, width - Pad - detailWidth, detailTop);
    }

    private static void DrawScrollbar(
        Graphics g, float width, float viewport, float content, float offset, float maxOffset, Theme theme)
    {
        float trackX = width - 8f;
        float thumbHeight = Math.Max(18f, viewport * viewport / content);
        float progress = Math.Min(1f, Math.Max(0f, offset / maxOffset));
        float thumbTop = BodyTop + (viewport - thumbHeight) * progress;

        using (GraphicsPath trackPath = RoundedRectPath(
                   new RectangleF(trackX, BodyTop, 4f, viewport), 2f))
        using (var trackBrush = new SolidBrush(theme.ScrollTrack))
        {
            g.FillPath(trackBrush, trackPath);
        }

        using (GraphicsPath thumbPath = RoundedRectPath(
                   new RectangleF(trackX, thumbTop, 4f, thumbHeight), 2f))
        using (var thumbBrush = new SolidBrush(theme.ScrollThumb))
        {
            g.FillPath(thumbBrush, thumbPath);
        }
    }

    // ------------------------------------------------------------------
    // Rows
    // ------------------------------------------------------------------

    private static void DrawRow(Graphics g, Row row, float top, float width, Theme theme, BubbleState state)
    {
        switch (row.Kind)
        {
            case RowKind.Root:
                DrawRootRow(g, row, top, width, theme, state);
                break;
            case RowKind.Meta:
                DrawChips(g, row.Chips, top, width, theme);
                break;
            case RowKind.Task:
                DrawTaskRow(g, row, top, width, theme);
                break;
            case RowKind.Child:
                DrawChildRow(g, row, top, width, theme);
                break;
            case RowKind.Empty:
                DrawEmptyRow(g, row, top, width, theme);
                break;
            case RowKind.Divider:
                using (var pen = new Pen(theme.RowSeparator, 1f))
                {
                    g.DrawLine(pen, Pad, top + 4f, width - Pad, top + 4f);
                }

                break;
        }
    }

    private static void DrawRootRow(Graphics g, Row row, float top, float width, Theme theme, BubbleState state)
    {
        Color group = theme.GroupColor(row.ColorIndex);
        Font titleFont = theme.Font(11.5f, semibold: true, mono: false);
        Font timeFont = theme.Font(11f, semibold: true, mono: true);

        // 6x6 group dot, 6px below the row top.
        FillEllipse(g, theme.WithAlpha(group, 0.95), Pad, top + 6f, 6f, 6f);

        float titleX = Pad + 11f;
        if (row.ChildCount > 0)
        {
            bool collapsed = state.CollapsedRoots != null && state.CollapsedRoots.Contains(row.RootId);
            Font chevronFont = theme.Font(9f, semibold: true, mono: false);
            DrawTextTop(g, collapsed ? "▸" : "▾", chevronFont, theme.Muted, Pad + 10f, top);
            titleX = Pad + 21f;
        }

        float timeWidth = Measure(g, row.Time, timeFont).Width;
        float titleMax = width - Pad - timeWidth - titleX - 6f;
        string title = TruncateByWidth(g, row.Text, 22, titleMax, titleFont);
        DrawTextTop(g, title, titleFont, theme.Fg, titleX, top);
        DrawTextRight(g, row.Time, timeFont, theme.Fg, width - Pad, top, mono: true);
    }

    private static void DrawTaskRow(Graphics g, Row row, float top, float width, Theme theme)
    {
        Font arrowFont = theme.Font(11f, semibold: true, mono: false);
        Font taskFont = theme.Font(10f, semibold: false, mono: false);
        float textX = Pad + 21f;
        DrawTextTop(g, "›", arrowFont, theme.Accent, Pad + 11f, top);
        string text = TruncateByWidth(g, row.Text, 46, width - Pad - textX, taskFont);
        DrawTextTop(g, text, taskFont, theme.TaskFg, textX, top);
    }

    private static void DrawChildRow(Graphics g, Row row, float top, float width, Theme theme)
    {
        Font labelFont = theme.Font(10.5f, semibold: false, mono: false);
        Font timeFont = theme.Font(10f, semibold: false, mono: true);
        Font secondaryFont = theme.Font(9.5f, semibold: false, mono: false);

        float labelX = Pad + row.Indent;
        FillEllipse(g, theme.WithAlpha(theme.GroupColor(row.ColorIndex), 0.9), Pad + row.Indent - 8f, top + 5f, 5f, 5f);

        float timeWidth = Measure(g, row.Time, timeFont).Width;
        bool hasSecondary = row.Secondary.Length > 0;
        float secondaryWidth = hasSecondary ? Measure(g, row.Secondary, secondaryFont).Width : 0f;
        float secondaryBlock = hasSecondary
            ? (row.BackArrow ? BackArrowLength + BackArrowGap : 0f) + secondaryWidth
            : 0f;
        float labelMax = width - Pad - timeWidth - 8f - labelX - 6f;
        if (hasSecondary)
        {
            labelMax = Math.Min(labelMax, width - Pad - timeWidth - 8f - secondaryBlock - 6f - labelX);
        }

        string label = TruncateByWidth(g, row.Text, 22, labelMax, labelFont);
        DrawTextTop(g, label, labelFont, theme.Fg, labelX, top);

        DrawTextRight(g, row.Time, timeFont, theme.Muted, width - Pad, top, mono: true);
        if (hasSecondary)
        {
            float secondaryRight = width - Pad - timeWidth - 8f;
            float textX = secondaryRight - secondaryWidth;
            DrawTextRight(g, row.Secondary, secondaryFont, theme.Muted, secondaryRight, top + 1f);
            if (row.BackArrow)
            {
                // Centre the arrow on the secondary text's line box (the "←"
                // glyph at 9.5px collapses into a dash at 1x, so it is vector).
                float centerY = top + 1f - TextLift(secondaryFont, false) + secondaryFont.GetHeight(g) / 2f;
                centerY = (float)Math.Round(centerY * 2f) / 2f;
                DrawBackArrow(g, textX - BackArrowGap - BackArrowLength, centerY, theme.Muted);
            }
        }
    }

    private const float BackArrowLength = 7f;
    private const float BackArrowGap = 4f;

    /// <summary>Vector "←" for the child row's parent reference (font-size independent, crisp at 1x).</summary>
    private static void DrawBackArrow(Graphics g, float x, float centerY, Color color)
    {
        const float HeadWidth = 3.5f;
        const float HeadHalfHeight = 2.2f;

        using var head = new GraphicsPath();
        head.AddPolygon(new[]
        {
            new PointF(x, centerY),
            new PointF(x + HeadWidth, centerY - HeadHalfHeight),
            new PointF(x + HeadWidth, centerY + HeadHalfHeight),
        });
        using (var brush = new SolidBrush(color))
        {
            g.FillPath(brush, head);
        }

        using var pen = new Pen(color, 1f)
        {
            StartCap = LineCap.Round,
            EndCap = LineCap.Round,
        };
        g.DrawLine(pen, x + HeadWidth - 0.8f, centerY, x + BackArrowLength, centerY);
    }

    private static void DrawEmptyRow(Graphics g, Row row, float top, float width, Theme theme)
    {
        Font textFont = theme.Font(10.5f, semibold: false, mono: false);
        Font secondaryFont = theme.Font(9.5f, semibold: false, mono: false);
        float x = Pad + row.Indent;

        string text = TruncateByWidth(g, row.Text, 120, width - Pad - x, textFont);
        DrawTextTop(g, text, textFont, theme.Muted, x, top);

        if (row.Secondary.Length > 0)
        {
            string secondary = TruncateByWidth(g, row.Secondary, 120, width - Pad - x, secondaryFont);
            DrawTextTop(g, secondary, secondaryFont, theme.Muted, x, top + 17f);
        }
    }

    private static void DrawChips(Graphics g, Chip[] chips, float top, float width, Theme theme)
    {
        if (chips == null || chips.Length == 0)
        {
            return;
        }

        float x = Pad + 11f;
        float limit = width - Pad - 8f;
        float chipTop = top - 1f; // Swift: yPos = height - top - 14 + 1

        foreach (Chip chip in chips)
        {
            bool isMono = chip.Style == ChipStyle.Id || chip.Style == ChipStyle.Turn;
            bool semibold = chip.Style == ChipStyle.Source;
            Font font = theme.Font(9.5f, semibold, isMono);

            Color fg;
            Color bg = Color.Empty;
            bool hasBg;
            switch (chip.Style)
            {
                case ChipStyle.Source:
                    fg = theme.GroupColor(chip.ColorIndex);
                    bg = theme.SourceChipBg(chip.ColorIndex);
                    hasBg = true;
                    break;
                case ChipStyle.Id:
                    fg = theme.Muted;
                    bg = theme.IdChipBg;
                    hasBg = true;
                    break;
                case ChipStyle.Count:
                    fg = theme.Accent;
                    bg = theme.CountChipBg;
                    hasBg = true;
                    break;
                case ChipStyle.Effort:
                    fg = theme.EffortChipFg;
                    bg = theme.EffortChipBg;
                    hasBg = true;
                    break;
                default:
                    fg = theme.Muted;
                    hasBg = false;
                    break;
            }

            SizeF textSize = Measure(g, chip.Text, font);
            float padX = hasBg ? 4f : 2f;
            float chipWidth = textSize.Width + padX * 2f;
            if (x + chipWidth > limit)
            {
                break; // Swift: chips that do not fit are dropped, not wrapped.
            }

            if (hasBg)
            {
                using GraphicsPath path = RoundedRectPath(new RectangleF(x, chipTop, chipWidth, 14f), 6f);
                using var brush = new SolidBrush(bg);
                g.FillPath(brush, path);
            }

            float textTop = chipTop + (14f - font.GetHeight(g)) / 2f;
            DrawTextTop(g, chip.Text, font, fg, x + padX, textTop, mono: isMono);
            x += chipWidth + 5f;
        }
    }

    // ------------------------------------------------------------------
    // Pin icon (vector, no emoji / no icon font)
    // ------------------------------------------------------------------

    private static void DrawPin(Graphics g, float x, float y, float size, Color color, bool filled)
    {
        float cx = x + size / 2f;
        float top = y + 2f;

        // Head: rounded bar.
        using var head = new GraphicsPath();
        AddRoundedRect(head, new RectangleF(cx - 4.5f, top, 9f, 3.2f), 1.4f);

        // Neck + flared skirt (thumbtack body).
        float neckY = top + 3.2f;
        float skirtY = neckY + 2.2f;
        float baseY = skirtY + 2.6f;
        using var body = new GraphicsPath();
        body.AddPolygon(new[]
        {
            new PointF(cx - 2.3f, neckY),
            new PointF(cx + 2.3f, neckY),
            new PointF(cx + 1.5f, skirtY),
            new PointF(cx + 4.9f, baseY - 1.0f),
            new PointF(cx + 4.9f, baseY),
            new PointF(cx - 4.9f, baseY),
            new PointF(cx - 4.9f, baseY - 1.0f),
            new PointF(cx - 1.5f, skirtY),
        });

        // Needle.
        using var needle = new GraphicsPath();
        needle.AddPolygon(new[]
        {
            new PointF(cx - 0.6f, baseY),
            new PointF(cx + 0.6f, baseY),
            new PointF(cx + 0.5f, baseY + 3.4f),
            new PointF(cx, baseY + 4.8f),
            new PointF(cx - 0.5f, baseY + 3.4f),
        });

        if (filled)
        {
            using var brush = new SolidBrush(color);
            g.FillPath(brush, head);
            g.FillPath(brush, body);
            g.FillPath(brush, needle);
        }
        else
        {
            using var pen = new Pen(color, 1.1f)
            {
                LineJoin = LineJoin.Round,
                StartCap = LineCap.Round,
                EndCap = LineCap.Round,
            };
            g.DrawPath(pen, head);
            g.DrawPath(pen, body);
            g.DrawPath(pen, needle);
        }
    }

    // ------------------------------------------------------------------
    // Layout (no Graphics needed: every row height is a constant)
    // ------------------------------------------------------------------

    private static List<Row> BuildRows(BubbleState state)
    {
        var rows = new List<Row>();
        List<RootSession> roots = state.Roots ?? new List<RootSession>();
        double now = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();

        if (roots.Count == 0)
        {
            rows.Add(new Row
            {
                Kind = RowKind.Empty,
                Text = "没有外部任务在运行",
                Secondary = "等待外部 ACP / headless 调用",
                Height = 36f,
            });
            return rows;
        }

        for (int index = 0; index < roots.Count; index++)
        {
            RootSession root = roots[index];
            if (root == null)
            {
                continue;
            }

            int colorIndex = root.ColorKey;
            List<ChildAgent> kids = ActiveChildren(root);
            bool collapsed = state.CollapsedRoots != null && state.CollapsedRoots.Contains(root.Id ?? "");
            double rootElapsed = root.Active ? now - root.StartedAt : root.ElapsedMs;

            rows.Add(new Row
            {
                Kind = RowKind.Root,
                Text = Truncate(root.Title ?? "", 22),
                Time = FormatDuration(rootElapsed),
                Height = 18f,
                ColorIndex = colorIndex,
                RootId = root.Id ?? "",
                ChildCount = kids.Count,
            });

            var chips = new List<Chip>();
            string source = string.IsNullOrEmpty(root.SourceLabel) ? root.Source ?? "" : root.SourceLabel;
            if (root.SourceConfidence == "inferred" && source.Length > 0)
            {
                source = "~" + source;
            }

            if (source.Length > 0)
            {
                chips.Add(new Chip { Text = source, Style = ChipStyle.Source, ColorIndex = colorIndex });
            }

            if (!string.IsNullOrEmpty(root.Id))
            {
                string idPart = !string.IsNullOrEmpty(root.ShortId)
                    ? PrefixByCodePoints(root.ShortId, 4)
                    : PrefixByCodePoints(root.Id, 4);
                chips.Add(new Chip { Text = "#" + idPart, Style = ChipStyle.Id, ColorIndex = colorIndex });
            }

            if (kids.Count > 0)
            {
                chips.Add(new Chip { Text = kids.Count + " 子", Style = ChipStyle.Count, ColorIndex = colorIndex });
            }

            if (!string.IsNullOrEmpty(root.Model))
            {
                chips.Add(new Chip { Text = root.Model, Style = ChipStyle.Plain, ColorIndex = colorIndex });
            }

            if (!string.IsNullOrEmpty(root.Effort))
            {
                chips.Add(new Chip
                {
                    Text = "推理 " + EffortLabel(root.Effort),
                    Style = ChipStyle.Effort,
                    ColorIndex = colorIndex,
                });
            }

            if (root.Turn > 0)
            {
                chips.Add(new Chip { Text = "T" + root.Turn, Style = ChipStyle.Turn, ColorIndex = colorIndex });
            }

            if (chips.Count > 0)
            {
                rows.Add(new Row
                {
                    Kind = RowKind.Meta,
                    Height = 16f,
                    ColorIndex = colorIndex,
                    Chips = chips.ToArray(),
                });
            }

            if (!string.IsNullOrEmpty(root.TaskPreview) &&
                !string.Equals(root.TaskPreview, root.Title, StringComparison.Ordinal))
            {
                rows.Add(new Row
                {
                    Kind = RowKind.Task,
                    Text = Truncate(root.TaskPreview, 46),
                    Height = 16f,
                    ColorIndex = colorIndex,
                });
            }

            if (!collapsed)
            {
                if (kids.Count == 0)
                {
                    rows.Add(new Row
                    {
                        Kind = RowKind.Empty,
                        Text = "无运行中的子 Agent",
                        Height = 16f,
                        Indent = RowIndent,
                        ColorIndex = colorIndex,
                    });
                }
                else
                {
                    foreach (ChildAgent child in kids)
                    {
                        double childElapsed = child.Active ? now - child.StartedAt : child.ElapsedMs;
                        string label = string.IsNullOrEmpty(child.Label) ? child.Id ?? "" : child.Label;
                        string parent = string.IsNullOrEmpty(child.Parent)
                            ? ""
                            : PrefixByCodePoints(child.Parent, 8);
                        rows.Add(new Row
                        {
                            Kind = RowKind.Child,
                            Text = Truncate(label, 22),
                            Secondary = parent,
                            Time = FormatDuration(childElapsed),
                            Indent = RowIndent,
                            Height = 17f,
                            ColorIndex = colorIndex,
                            BackArrow = parent.Length > 0,
                        });
                    }
                }
            }

            if (index < roots.Count - 1)
            {
                rows.Add(new Row { Kind = RowKind.Divider, Height = 8f });
            }
        }

        return rows;
    }

    private static float ContentHeight(List<Row> rows)
    {
        float total = 0f;
        foreach (Row row in rows)
        {
            total += row.Height;
        }

        return total + 10f;
    }

    private static bool IsIdle(BubbleState state)
    {
        return state == null || state.Roots == null || state.Roots.Count == 0;
    }

    private static List<ChildAgent> ActiveChildren(RootSession root)
    {
        var active = new List<ChildAgent>();
        if (root.Children == null)
        {
            return active;
        }

        foreach (ChildAgent child in root.Children)
        {
            if (child != null && child.Active)
            {
                active.Add(child);
            }
        }

        return active;
    }

    private static int CountActiveChildren(List<RootSession> roots)
    {
        int count = 0;
        foreach (RootSession root in roots)
        {
            if (root == null || root.Children == null)
            {
                continue;
            }

            foreach (ChildAgent child in root.Children)
            {
                if (child != null && child.Active)
                {
                    count++;
                }
            }
        }

        return count;
    }

    private static double MaxElapsed(List<RootSession> roots)
    {
        double now = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
        double maximum = 0;
        foreach (RootSession root in roots)
        {
            if (root == null)
            {
                continue;
            }

            maximum = Math.Max(maximum, root.Active ? now - root.StartedAt : root.ElapsedMs);
            if (root.Children == null)
            {
                continue;
            }

            foreach (ChildAgent child in root.Children)
            {
                if (child == null)
                {
                    continue;
                }

                maximum = Math.Max(maximum, child.Active ? now - child.StartedAt : child.ElapsedMs);
            }
        }

        return maximum;
    }

    private static Tokens TotalTokens(List<RootSession> roots)
    {
        var total = new Tokens();
        foreach (RootSession root in roots)
        {
            if (root == null)
            {
                continue;
            }

            Tokens tokens = root.Tokens ?? new Tokens();
            total.Input += tokens.Input;
            total.Output += tokens.Output;
            total.CacheRead += tokens.CacheRead;
            total.CacheWrite += tokens.CacheWrite;
            total.Total += tokens.Total;

            if (root.Children == null)
            {
                continue;
            }

            foreach (ChildAgent child in root.Children)
            {
                if (child == null)
                {
                    continue;
                }

                Tokens childTokens = child.Tokens ?? new Tokens();
                total.Input += childTokens.Input;
                total.Output += childTokens.Output;
                total.CacheRead += childTokens.CacheRead;
                total.CacheWrite += childTokens.CacheWrite;
                total.Total += childTokens.Total;
            }
        }

        return total;
    }

    // ------------------------------------------------------------------
    // Text primitives / number formatting
    // ------------------------------------------------------------------

    private static StringFormat CreateTypographicFormat()
    {
        var format = (StringFormat)StringFormat.GenericTypographic.Clone();
        format.FormatFlags |= StringFormatFlags.NoWrap | StringFormatFlags.NoClip;
        format.Trimming = StringTrimming.None;
        format.HotkeyPrefix = HotkeyPrefix.None;
        return format;
    }

    private static readonly Dictionary<float, Font> EmojiFontCache = new();
    private static readonly Lazy<string?> EmojiFamilyName = new(ResolveEmojiFamily);

    private static string? ResolveEmojiFamily()
    {
        try
        {
            using var collection = new InstalledFontCollection();
            foreach (FontFamily family in collection.Families)
            {
                if (string.Equals(family.Name, "Segoe UI Emoji", StringComparison.OrdinalIgnoreCase))
                {
                    return family.Name;
                }
            }
        }
        catch
        {
            // Best effort only.
        }

        return null;
    }

    private static Font EmojiFont(float size)
    {
        if (EmojiFontCache.TryGetValue(size, out Font? cached))
        {
            return cached;
        }

        Font font = new Font(
            EmojiFamilyName.Value ?? "Segoe UI",
            size,
            FontStyle.Regular,
            GraphicsUnit.Pixel);
        EmojiFontCache[size] = font;
        return font;
    }

    private static bool ContainsEmoji(string text)
    {
        for (int i = 0; i < text.Length; i++)
        {
            char c = text[i];
            if (char.IsHighSurrogate(c) && i + 1 < text.Length && char.IsLowSurrogate(text[i + 1]))
            {
                return true;
            }

            if (c == '\u200D' || c == '\uFE0F')
            {
                return true;
            }
        }

        return false;
    }

    /// <summary>Split into GDI-measurable runs; non-BMP emoji go to the emoji face.</summary>
    private static List<(string Run, bool Emoji)> SplitEmojiRuns(string text)
    {
        var runs = new List<(string Run, bool Emoji)>();
        var current = new System.Text.StringBuilder();
        bool currentEmoji = false;
        int i = 0;
        while (i < text.Length)
        {
            int codePoint;
            int length;
            if (char.IsHighSurrogate(text[i]) && i + 1 < text.Length && char.IsLowSurrogate(text[i + 1]))
            {
                codePoint = char.ConvertToUtf32(text[i], text[i + 1]);
                length = 2;
            }
            else
            {
                codePoint = text[i];
                length = 1;
            }

            bool isEmojiCodePoint = codePoint >= 0x1F000 && codePoint <= 0x1FAFF;
            bool isGlue = codePoint == 0x200D || codePoint == 0xFE0F;
            bool emojiRun = isEmojiCodePoint || (isGlue && currentEmoji);

            if (current.Length == 0)
            {
                currentEmoji = emojiRun;
            }
            else if (emojiRun != currentEmoji)
            {
                runs.Add((current.ToString(), currentEmoji));
                current.Clear();
                currentEmoji = emojiRun;
            }

            current.Append(text, i, length);
            i += length;
        }

        if (current.Length > 0)
        {
            runs.Add((current.ToString(), currentEmoji));
        }

        return runs;
    }

    /// <summary>
    /// Off-screen surface used by <see cref="PreferredWidth"/> and by
    /// <see cref="PillWidth"/> when the caller has no Graphics yet. Lives for the
    /// process; the 1x1 bitmap is held so the Graphics never outlives its image.
    /// </summary>
    private static Graphics MeasureGraphics()
    {
        lock (MeasureSync)
        {
            if (_measureGraphics != null)
            {
                return _measureGraphics;
            }

            _measureSurface = new Bitmap(1, 1);
            _measureGraphics = Graphics.FromImage(_measureSurface);
            _measureGraphics.TextRenderingHint = TextRenderingHint.AntiAliasGridFit;
            return _measureGraphics;
        }
    }

    private static Font MeasureFont(float size, bool semibold, bool mono)
    {
        return MeasureTheme.Value.Font(size, semibold, mono);
    }

    private static SizeF Measure(Graphics g, string text, Font font)
    {
        if (string.IsNullOrEmpty(text))
        {
            return SizeF.Empty;
        }

        if (!ContainsEmoji(text))
        {
            return g.MeasureString(text, font, new SizeF(1_000_000f, 1_000_000f), Typographic);
        }

        // GDI+ has no colour-emoji support; Segoe UI shows non-BMP emoji as
        // tofu. Measure emoji runs with the emoji face (monochrome outline) so
        // widths — and therefore truncation — stay correct on both sides.
        float width = 0f;
        float height = 0f;
        foreach ((string run, bool emoji) in SplitEmojiRuns(text))
        {
            Font runFont = emoji ? EmojiFont(font.Size) : font;
            SizeF measured = g.MeasureString(run, runFont, new SizeF(1_000_000f, 1_000_000f), Typographic);
            width += measured.Width;
            height = Math.Max(height, measured.Height);
        }

        return new SizeF(width, height);
    }

    /// <summary>Draw text with its typographic line-box top at <paramref name="top"/> (raw, no baseline correction).</summary>
    private static void DrawText(Graphics g, string text, Font font, Color color, float x, float top)
    {
        if (string.IsNullOrEmpty(text))
        {
            return;
        }

        using var brush = new SolidBrush(color);
        if (!ContainsEmoji(text))
        {
            g.DrawString(text, font, brush, x, top, Typographic);
            return;
        }

        float cursor = x;
        foreach ((string run, bool emoji) in SplitEmojiRuns(text))
        {
            Font runFont = emoji ? EmojiFont(font.Size) : font;
            g.DrawString(run, runFont, brush, cursor, top, Typographic);
            cursor += g.MeasureString(run, runFont, new SizeF(1_000_000f, 1_000_000f), Typographic).Width;
        }
    }

    // AppKit anchors the line box using SF Pro's ascent; Segoe UI reports a
    // noticeably larger cell ascent, which pushes proportional glyphs ~2px down
    // at these sizes. Pull top-anchored proportional text up by a calibrated
    // fraction of the size so glyph tops land within 1px of the macOS reference.
    // Cascadia Mono's ascent matches SF Mono, so monospace needs no correction.
    private static float TextLift(Font font, bool mono)
    {
        return mono ? 0f : 0.11f * font.Size;
    }

    private static void DrawTextTop(Graphics g, string text, Font font, Color color, float x, float top, bool mono = false)
    {
        DrawText(g, text, font, color, x, top - TextLift(font, mono));
    }

    private static void DrawTextRight(Graphics g, string text, Font font, Color color, float right, float top, bool mono = false)
    {
        if (string.IsNullOrEmpty(text))
        {
            return;
        }

        float width = Measure(g, text, font).Width;
        DrawTextTop(g, text, font, color, right - width, top, mono);
    }

    /// <summary>
    /// Swift's truncate(): first cut by grapheme count (limit-1 + "…"), then —
    /// because CJK/emoji are wider than the AppKit metrics used on macOS — keep
    /// bisecting the character prefix until the measured width fits.
    /// </summary>
    private static string TruncateByWidth(Graphics g, string text, int maxChars, float maxWidth, Font font)
    {
        if (string.IsNullOrEmpty(text) || maxWidth <= 0f)
        {
            return "";
        }

        string trimmed = Truncate(text, maxChars);
        if (Measure(g, trimmed, font).Width <= maxWidth)
        {
            return trimmed;
        }

        const string Ellipsis = "…";
        if (Measure(g, Ellipsis, font).Width > maxWidth)
        {
            return "";
        }

        int low = 0;
        // Upper bound: the character-limit cut (or the whole string if shorter).
        int high = Math.Min(CountCodePoints(text), Math.Max(0, maxChars - 1));
        int best = 0;
        while (low <= high)
        {
            int middle = (low + high) / 2;
            string candidate = PrefixByCodePoints(text, middle) + Ellipsis;
            if (Measure(g, candidate, font).Width <= maxWidth)
            {
                best = middle;
                low = middle + 1;
            }
            else
            {
                high = middle - 1;
            }
        }

        return PrefixByCodePoints(text, best) + Ellipsis;
    }

    private static string Truncate(string value, int limit)
    {
        if (string.IsNullOrEmpty(value))
        {
            return "";
        }

        if (CountCodePoints(value) <= limit)
        {
            return value;
        }

        return PrefixByCodePoints(value, Math.Max(1, limit - 1)) + "…";
    }

    private static int CountCodePoints(string value)
    {
        int count = 0;
        for (int i = 0; i < value.Length; i++)
        {
            if (char.IsHighSurrogate(value[i]) && i + 1 < value.Length && char.IsLowSurrogate(value[i + 1]))
            {
                i++;
            }

            count++;
        }

        return count;
    }

    private static string PrefixByCodePoints(string value, int count)
    {
        if (string.IsNullOrEmpty(value) || count <= 0)
        {
            return "";
        }

        int index = 0;
        int taken = 0;
        while (index < value.Length && taken < count)
        {
            index += char.IsHighSurrogate(value[index]) && index + 1 < value.Length &&
                     char.IsLowSurrogate(value[index + 1])
                ? 2
                : 1;
            taken++;
        }

        return value.Substring(0, index);
    }

    private static string FormatCompact(int value)
    {
        double number = value;
        if (number >= 1_000_000)
        {
            return (number / 1_000_000.0).ToString("0.0", System.Globalization.CultureInfo.InvariantCulture) + "M";
        }

        if (number >= 1_000)
        {
            return (number / 1_000.0).ToString("0.0", System.Globalization.CultureInfo.InvariantCulture) + "k";
        }

        return value.ToString(System.Globalization.CultureInfo.InvariantCulture);
    }

    private static string FormatDuration(double milliseconds)
    {
        long totalSeconds = (long)Math.Floor(Math.Max(0, milliseconds) / 1000.0);
        long hours = totalSeconds / 3600;
        long minutes = (totalSeconds % 3600) / 60;
        long seconds = totalSeconds % 60;
        if (hours > 0)
        {
            return hours.ToString(System.Globalization.CultureInfo.InvariantCulture) + ":" +
                   minutes.ToString("00", System.Globalization.CultureInfo.InvariantCulture) + ":" +
                   seconds.ToString("00", System.Globalization.CultureInfo.InvariantCulture);
        }

        return minutes.ToString(System.Globalization.CultureInfo.InvariantCulture) + ":" +
               seconds.ToString("00", System.Globalization.CultureInfo.InvariantCulture);
    }

    private static string EffortLabel(string value)
    {
        switch ((value ?? "").ToLowerInvariant())
        {
            case "off":
                return "关";
            case "low":
                return "低";
            case "medium":
                return "中";
            case "high":
                return "高";
            case "max":
                return "最高";
            default:
                return value ?? "";
        }
    }

    // ------------------------------------------------------------------
    // Geometry helpers
    // ------------------------------------------------------------------

    private static float Clamp01(float value)
    {
        if (value < 0f)
        {
            return 0f;
        }

        if (value > 1f)
        {
            return 1f;
        }

        return value;
    }

    private static GraphicsPath RoundedRectPath(RectangleF rect, float radius)
    {
        var path = new GraphicsPath();
        AddRoundedRect(path, rect, radius);
        return path;
    }

    private static void AddRoundedRect(GraphicsPath path, RectangleF rect, float radius)
    {
        float diameter = Math.Min(radius * 2f, Math.Min(rect.Width, rect.Height));
        if (diameter <= 0.5f)
        {
            path.AddRectangle(rect);
            return;
        }

        path.AddArc(rect.X, rect.Y, diameter, diameter, 180f, 90f);
        path.AddArc(rect.Right - diameter, rect.Y, diameter, diameter, 270f, 90f);
        path.AddArc(rect.Right - diameter, rect.Bottom - diameter, diameter, diameter, 0f, 90f);
        path.AddArc(rect.X, rect.Bottom - diameter, diameter, diameter, 90f, 90f);
        path.CloseFigure();
    }

    private static void FillEllipse(Graphics g, Color color, float x, float y, float width, float height)
    {
        using var brush = new SolidBrush(color);
        g.FillEllipse(brush, x, y, width, height);
    }
}
