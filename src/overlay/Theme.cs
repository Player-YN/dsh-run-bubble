// Theme.cs — colors, font cache and small derived shades for the overlay.
// Values follow docs/PORT-WINDOWS.md §6 (dark / light), which is itself the
// AppKit palette from overlay.swift. All sizes are DIP; the window layer owns
// DPI scaling, so fonts are created with GraphicsUnit.Pixel (1 unit == 1 DIP
// in the renderer's coordinate space). Font objects are cached for the life of
// the Theme and must NOT be disposed by callers.

using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Text;

namespace DshRunBubble;

/// <summary>Dark/light palette plus cached fonts for one appearance.</summary>
public sealed class Theme
{
    private static readonly Lazy<string> MonoFamily = new(ResolveMonoFamily);
    private static readonly Lazy<string> SemiboldFamily = new(ResolveSemiboldFamily);
    private static readonly Lazy<string> RegularFamily = new(ResolveRegularFamily);

    private readonly Dictionary<(float Size, bool Semibold, bool Mono), Font> _fonts =
        new Dictionary<(float Size, bool Semibold, bool Mono), Font>();

    private readonly Color[] _groupColors;

    private Theme(bool dark)
    {
        IsDark = dark;

        if (dark)
        {
            // AppKit's calibratedWhite 0.10 maps to sRGB #212121 (not #1A1A1A);
            // match the macOS reference screenshots (dark panel looked too black
            // with the originally-specced #1A1A1A).
            Bg = Color.FromArgb(Alpha(0.93), 0x21, 0x21, 0x21);
            Fg = Color.FromArgb(0xF5, 0xF5, 0xF5);
            Muted = Color.FromArgb(0xB3, 0xB3, 0xB3);
            TaskFg = Color.FromArgb(0xD1, 0xD1, 0xD1);
            Border = Color.FromArgb(Alpha(0.12), 0xFF, 0xFF, 0xFF);
            _groupColors = new[]
            {
                Color.FromArgb(0x0A, 0x84, 0xFF),
                Color.FromArgb(0xFF, 0x9F, 0x0A),
                Color.FromArgb(0x30, 0xB0, 0xC7),
                Color.FromArgb(0xBF, 0x5A, 0xF2),
                Color.FromArgb(0xFF, 0x37, 0x5F),
                Color.FromArgb(0x30, 0xD1, 0x58),
            };
        }
        else
        {
            // Logical colour is #FCFCFC @ 94%. GDI+ pushes a translucent fill
            // through a premultiplied-alpha round-trip that truncates one unit
            // off the straight-alpha RGB (0xFC is stored as 0xFB), so feed 0xFD
            // and the canvas holds exactly (A240, R252, G252, B252); the
            // premultiplied value seen by the layered window is then exact too
            // (252 * 240 / 255 = 237).
            Bg = Color.FromArgb(Alpha(0.94), 0xFD, 0xFD, 0xFD);
            Fg = Color.FromArgb(0x1F, 0x1F, 0x1F);
            Muted = Color.FromArgb(0x66, 0x66, 0x66);
            TaskFg = Color.FromArgb(0x47, 0x47, 0x47);
            Border = Color.FromArgb(Alpha(0.08), 0x00, 0x00, 0x00);
            _groupColors = new[]
            {
                Color.FromArgb(0x00, 0x7A, 0xFF),
                Color.FromArgb(0xFF, 0x95, 0x00),
                Color.FromArgb(0x30, 0xB0, 0xC7),
                Color.FromArgb(0xAF, 0x52, 0xDE),
                Color.FromArgb(0xFF, 0x2D, 0x55),
                Color.FromArgb(0x34, 0xC7, 0x59),
            };
        }

        Accent = Color.FromArgb(0x30, 0xD1, 0x58);
    }

    /// <summary>Create the palette for the requested appearance.</summary>
    public static Theme Create(bool dark) => new Theme(dark);

    public bool IsDark { get; }

    public Color Bg;
    public Color Fg;
    public Color Muted;
    public Color TaskFg;
    public Color Border;
    public Color Accent;

    /// <summary>Group color by root <c>colorKey</c> (Swift: palette[abs(index) % count]).</summary>
    public Color GroupColor(int index)
    {
        int absolute = index;
        if (absolute < 0)
        {
            absolute = index == int.MinValue ? 0 : -index;
        }

        return _groupColors[absolute % _groupColors.Length];
    }

    /// <summary>
    /// Cached font. <paramref name="size"/> is a DIP size (Swift point value).
    /// The returned instance is owned by the Theme and must not be disposed.
    /// </summary>
    public Font Font(float size, bool semibold, bool mono)
    {
        (float, bool, bool) key = (size, semibold, mono);
        if (_fonts.TryGetValue(key, out Font? cached))
        {
            return cached;
        }

        Font font = CreateFont(size, semibold, mono);
        _fonts[key] = font;
        return font;
    }

    // ---- derived shades used by the renderer --------------------------------

    /// <summary>White (dark) / black (light) with the given alpha, as in AppKit's calibratedWhite.</summary>
    public Color Scrim(double alpha)
    {
        int a = Alpha(alpha);
        return IsDark ? Color.FromArgb(a, 255, 255, 255) : Color.FromArgb(a, 0, 0, 0);
    }

    /// <summary>Replace a color's alpha channel.</summary>
    public Color WithAlpha(Color color, double alpha)
    {
        return Color.FromArgb(Alpha(alpha), color.R, color.G, color.B);
    }

    public Color HeaderSeparator => Scrim(0.70);

    public Color RowSeparator => Scrim(0.55);

    public Color BadgeBg => Scrim(IsDark ? 0.08 : 0.06);

    public Color ScrollTrack => Scrim(IsDark ? 0.10 : 0.08);

    public Color ScrollThumb => Scrim(0.38);

    public Color IdChipBg => Scrim(IsDark ? 0.07 : 0.05);

    public Color SourceChipBg(int colorKey) => WithAlpha(GroupColor(colorKey), IsDark ? 0.22 : 0.14);

    public Color CountChipBg => WithAlpha(Accent, IsDark ? 0.16 : 0.10);

    public Color EffortChipFg => IsDark
        ? Color.FromArgb(0xFF, 0x9F, 0x0A)
        : Color.FromArgb(0xA6, 0x5C, 0x05);

    public Color EffortChipBg => WithAlpha(Color.FromArgb(0xFF, 0x9F, 0x0A), IsDark ? 0.14 : 0.10);

    /// <summary>0..1 alpha -> 0..255 int (rounded), matching AppKit's alpha component.</summary>
    public static int Alpha(double alpha)
    {
        if (alpha <= 0)
        {
            return 0;
        }

        if (alpha >= 1)
        {
            return 255;
        }

        return (int)Math.Round(alpha * 255.0);
    }

    // ---- font plumbing ------------------------------------------------------

    private static Font CreateFont(float size, bool semibold, bool mono)
    {
        if (mono)
        {
            return new Font(
                MonoFamily.Value,
                size,
                semibold ? FontStyle.Bold : FontStyle.Regular,
                GraphicsUnit.Pixel);
        }

        if (semibold)
        {
            string family = SemiboldFamily.Value;
            bool synthetic = string.Equals(family, RegularFamily.Value, StringComparison.OrdinalIgnoreCase);
            return new Font(
                family,
                size,
                synthetic ? FontStyle.Bold : FontStyle.Regular,
                GraphicsUnit.Pixel);
        }

        return new Font(RegularFamily.Value, size, FontStyle.Regular, GraphicsUnit.Pixel);
    }

    private static string ResolveMonoFamily()
    {
        return FirstInstalled("Cascadia Mono", "Consolas", "Courier New") ?? "Courier New";
    }

    private static string ResolveSemiboldFamily()
    {
        return FirstInstalled("Segoe UI Semibold") ?? ResolveRegularFamily();
    }

    private static string ResolveRegularFamily()
    {
        return FirstInstalled("Segoe UI", "Tahoma", "Arial") ?? "Arial";
    }

    private static string? FirstInstalled(params string[] candidates)
    {
        try
        {
            using var collection = new InstalledFontCollection();
            var installed = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (FontFamily family in collection.Families)
            {
                installed.Add(family.Name);
            }

            foreach (string candidate in candidates)
            {
                if (installed.Contains(candidate))
                {
                    return candidate;
                }
            }
        }
        catch
        {
            // Font enumeration is best effort; fall through to the static fallback.
        }

        return null;
    }
}
