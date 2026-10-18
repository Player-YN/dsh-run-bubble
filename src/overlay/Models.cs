// Models.cs — shared data model for the DSH run-bubble Windows overlay.
// Frozen interface (see docs/PORT-WINDOWS.md §7). Rendering layer only:
// no window handles, no file IO, no timers here.
//
// Parsing rules mirror overlay.swift exactly:
//   * numbers accept JSON numbers or numeric strings, everything else -> 0
//   * ints truncate (like Swift Int(Double))
//   * booleans accept true/false or numbers (0 == false)
//   * missing / mistyped fields silently fall back to defaults
//   * the whole parse is exception proof: on any failure -> empty list

using System;
using System.Collections.Generic;
using System.Drawing;
using System.Globalization;
using System.Text.Json;

namespace DshRunBubble;

/// <summary>Token counters for one session (schema v2 <c>tokens</c> object).</summary>
public sealed class Tokens
{
    public int Input;
    public int Output;
    public int CacheRead;
    public int CacheWrite;
    public int Total;

    public Tokens()
    {
    }

    public Tokens(int input, int output, int cacheRead, int cacheWrite, int total)
    {
        Input = input;
        Output = output;
        CacheRead = cacheRead;
        CacheWrite = cacheWrite;
        Total = total;
    }
}

/// <summary>One child agent of a root session.</summary>
public sealed class ChildAgent
{
    public string Id = "";
    public string Label = "";
    public string Parent = "";
    public string Model = "";
    public string Effort = "";
    public double StartedAt;
    public double ElapsedMs;
    public bool Active;
    public Tokens Tokens = new();
}

/// <summary>One root (external) session as emitted by daemon.mjs.</summary>
public sealed class RootSession
{
    public string Id = "";
    public string ShortId = "";
    public string Title = "";
    public string Cwd = "";
    public string Source = "";
    public string SourceLabel = "";
    public string SourceConfidence = "";
    public string TitleSource = "";
    public string TaskPreview = "";
    public string Model = "";
    public string Effort = "";
    public int ColorKey;
    public int Turn;
    public double StartedAt;
    public double ElapsedMs;
    public bool Active;
    public Tokens Tokens = new();
    public List<ChildAgent> Children = new();
}

/// <summary>
/// Mutable UI state shared with the window layer. The render layer only reads
/// it; the window layer owns hover / pin / scroll / collapse mutations.
/// </summary>
public sealed class BubbleState
{
    public List<RootSession> Roots = new();
    public bool Expanded;
    public bool Pinned;
    public float ScrollOffset;
    public float Pulse = 1f;
    public HashSet<string> CollapsedRoots = new();

    /// <summary>
    /// Whether desktop-app sessions participate in the bubble (the desktop icon
    /// in the expanded header toggles this; daemon side reads config.json).
    /// </summary>
    public bool IncludeDesktop;
}

/// <summary>Clickable rectangle for a root row that owns children.</summary>
/// <remarks>Bounds use the viewport coordinate space (top-left origin), scroll already applied.</remarks>
public readonly struct RootRowHit
{
    public readonly string RootId;
    public readonly RectangleF Bounds;

    public RootRowHit(string rootId, RectangleF bounds)
    {
        RootId = rootId ?? "";
        Bounds = bounds;
    }
}

/// <summary>Clickable icon button in the expanded header (§11.2).</summary>
/// <remarks>Bounds are panel coordinates (top-left origin, no scroll).</remarks>
public readonly struct IconHit
{
    public readonly string Id;
    public readonly RectangleF Bounds;

    public IconHit(string id, RectangleF bounds)
    {
        Id = id ?? "";
        Bounds = bounds;
    }
}

/// <summary>Tolerant parser for status.json (schema v2). Never throws.</summary>
public static class StatusDoc
{
    private static readonly IFormatProvider Inv = CultureInfo.InvariantCulture;

    /// <summary>Parse status.json text into roots. Returns an empty list on any problem.</summary>
    public static List<RootSession> Parse(string json)
    {
        var roots = new List<RootSession>();
        if (string.IsNullOrWhiteSpace(json))
        {
            return roots;
        }

        try
        {
            using (JsonDocument doc = JsonDocument.Parse(json))
            {
                JsonElement root = doc.RootElement;
                if (root.ValueKind != JsonValueKind.Object)
                {
                    return roots;
                }

                if (!root.TryGetProperty("roots", out JsonElement rootsElement) ||
                    rootsElement.ValueKind != JsonValueKind.Array)
                {
                    return roots;
                }

                foreach (JsonElement item in rootsElement.EnumerateArray())
                {
                    RootSession? parsed = ParseRoot(item);
                    if (parsed != null)
                    {
                        roots.Add(parsed);
                    }
                }
            }
        }
        catch
        {
            roots.Clear();
        }

        return roots;
    }

    private static RootSession? ParseRoot(JsonElement value)
    {
        if (value.ValueKind != JsonValueKind.Object)
        {
            return null;
        }

        var root = new RootSession
        {
            Id = GetString(value, "id"),
            ShortId = GetString(value, "shortId"),
            Title = GetString(value, "title"),
            Cwd = GetString(value, "cwd"),
            StartedAt = GetNumber(value, "startedAt"),
            ElapsedMs = GetNumber(value, "elapsedMs"),
            Active = GetBool(value, "active"),
            Turn = GetInt(value, "turn"),
            Model = GetString(value, "model"),
            Effort = GetString(value, "reasoningEffort"),
            Tokens = ParseTokens(value, "tokens"),
            Source = GetString(value, "source"),
            SourceLabel = GetString(value, "sourceLabel"),
            SourceConfidence = GetString(value, "sourceConfidence"),
            TitleSource = GetString(value, "titleSource"),
            TaskPreview = GetString(value, "taskPreview"),
            ColorKey = GetInt(value, "colorKey"),
        };

        if (value.TryGetProperty("children", out JsonElement children) &&
            children.ValueKind == JsonValueKind.Array)
        {
            foreach (JsonElement item in children.EnumerateArray())
            {
                ChildAgent? child = ParseChild(item);
                if (child != null)
                {
                    root.Children.Add(child);
                }
            }
        }

        return root;
    }

    private static ChildAgent? ParseChild(JsonElement value)
    {
        if (value.ValueKind != JsonValueKind.Object)
        {
            return null;
        }

        var child = new ChildAgent
        {
            Id = GetString(value, "id"),
            Label = GetString(value, "label"),
            Parent = GetString(value, "parentSession"),
            StartedAt = GetNumber(value, "startedAt"),
            ElapsedMs = GetNumber(value, "elapsedMs"),
            Active = GetBool(value, "active"),
            Model = GetString(value, "model"),
            Effort = GetString(value, "reasoningEffort"),
            Tokens = ParseTokens(value, "tokens"),
        };

        if (string.IsNullOrEmpty(child.Label))
        {
            child.Label = GetString(value, "title");
        }

        return child;
    }

    private static Tokens ParseTokens(JsonElement parent, string name)
    {
        var tokens = new Tokens();
        if (parent.ValueKind != JsonValueKind.Object ||
            !parent.TryGetProperty(name, out JsonElement value) ||
            value.ValueKind != JsonValueKind.Object)
        {
            return tokens;
        }

        tokens.Input = GetInt(value, "input");
        tokens.Output = GetInt(value, "output");
        tokens.CacheRead = GetInt(value, "cacheRead");
        tokens.CacheWrite = GetInt(value, "cacheWrite");
        tokens.Total = GetInt(value, "total");
        if (tokens.Total == 0)
        {
            tokens.Total = tokens.Input + tokens.Output + tokens.CacheRead;
        }

        return tokens;
    }

    private static JsonElement? GetProperty(JsonElement value, string name)
    {
        if (value.ValueKind == JsonValueKind.Object && value.TryGetProperty(name, out JsonElement found))
        {
            return found;
        }

        return null;
    }

    private static string GetString(JsonElement value, string name)
    {
        JsonElement? property = GetProperty(value, name);
        if (property == null)
        {
            return "";
        }

        switch (property.Value.ValueKind)
        {
            case JsonValueKind.String:
                return property.Value.GetString() ?? "";
            case JsonValueKind.Number:
                return property.Value.GetRawText();
            default:
                return "";
        }
    }

    private static double GetNumber(JsonElement value, string name)
    {
        return ToNumber(GetProperty(value, name));
    }

    private static int GetInt(JsonElement value, string name)
    {
        return ToInt(GetNumber(value, name));
    }

    private static bool GetBool(JsonElement value, string name)
    {
        return ToBool(GetProperty(value, name));
    }

    private static double ToNumber(JsonElement? value)
    {
        if (value == null)
        {
            return 0;
        }

        switch (value.Value.ValueKind)
        {
            case JsonValueKind.Number:
                return value.Value.TryGetDouble(out double number) ? number : 0;
            case JsonValueKind.String:
                string? text = value.Value.GetString();
                if (!string.IsNullOrEmpty(text) &&
                    double.TryParse(text, NumberStyles.Float, Inv, out double parsed))
                {
                    return parsed;
                }

                return 0;
            default:
                return 0;
        }
    }

    private static int ToInt(double value)
    {
        if (double.IsNaN(value) || double.IsInfinity(value))
        {
            return 0;
        }

        if (value >= int.MaxValue)
        {
            return int.MaxValue;
        }

        if (value <= int.MinValue)
        {
            return int.MinValue;
        }

        return (int)value;
    }

    private static bool ToBool(JsonElement? value)
    {
        if (value == null)
        {
            return false;
        }

        switch (value.Value.ValueKind)
        {
            case JsonValueKind.True:
                return true;
            case JsonValueKind.False:
                return false;
            case JsonValueKind.Number:
                return value.Value.TryGetDouble(out double number) && number != 0;
            default:
                return false;
        }
    }
}
