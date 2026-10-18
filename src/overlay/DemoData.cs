// DemoData.cs — deterministic demo datasets for --demo / --demo-many /
// --demo-roots / --demo-idle. Values are copied 1:1 from overlay.swift
// (demoRoots / demoManyRoots / demoSameTitleRoots) so snapshots match the
// macOS reference images; only the absolute timestamps are "now - offset".

using System;
using System.Collections.Generic;

namespace DshRunBubble;

/// <summary>Sample status payloads used by the overlay's demo flags.</summary>
public static class DemoData
{
    private const string DemoRootId = "96197fc7-89e7-448e-90b5-ad0c994773a8";

    /// <summary>1 root ("Call the subagent tool exactly") + 1 child, Codex, 26.2k tokens.</summary>
    public static List<RootSession> DemoRoots()
    {
        double now = NowMs();
        var root = new RootSession
        {
            Id = DemoRootId,
            ShortId = "96197fc7",
            Title = "Call the subagent tool exactly",
            StartedAt = now - 754_000,
            Active = true,
            Turn = 1,
            Model = "deepseek-flash",
            Effort = "high",
            Source = "codex",
            SourceLabel = "Codex",
            SourceConfidence = "explicit",
            TitleSource = "explicit",
            TaskPreview = "Refactor the auth middleware into a provider chain",
            ColorKey = 0,
            Tokens = new Tokens(input: 6400, output: 541, cacheRead: 19100, cacheWrite: 0, total: 26200),
        };
        root.Children.Add(new ChildAgent
        {
            Id = "66756e38-5fcf-4572-9c7b-c8fbf0b9f711",
            Label = "bubble child test",
            Parent = DemoRootId,
            StartedAt = now - 32_000,
            Active = true,
            Model = "deepseek-flash",
            Effort = "high",
            Tokens = new Tokens(input: 3227, output: 82, cacheRead: 5376, cacheWrite: 0, total: 8685),
        });
        return new List<RootSession> { root };
    }

    /// <summary>2 roots with 14 + 8 active children — tall enough to scroll.</summary>
    public static List<RootSession> DemoManyRoots()
    {
        double now = NowMs();

        var first = new RootSession
        {
            Id = DemoRootId,
            ShortId = "96197fc7",
            Title = "Fan-out: refactor auth modules",
            StartedAt = now - 1_254_000,
            Active = true,
            Turn = 2,
            Model = "deepseek-flash",
            Effort = "max",
            Source = "codex",
            SourceLabel = "Codex",
            SourceConfidence = "explicit",
            TitleSource = "explicit",
            TaskPreview = "Split auth into provider adapters and update 14 call sites",
            ColorKey = 0,
            Tokens = new Tokens(input: 18400, output: 2411, cacheRead: 47100, cacheWrite: 0, total: 67911),
        };
        for (int index = 1; index <= 14; index++)
        {
            first.Children.Add(new ChildAgent
            {
                Id = "codex-child-" + index + "-0000-0000-0000-000000000000",
                Label = "worker " + index + ": refactor module " + index,
                Parent = first.Id,
                StartedAt = now - ((60 - index * 3) * 1000.0),
                Active = true,
                Model = "deepseek-flash",
                Effort = "high",
                Tokens = new Tokens(
                    input: 1200 + index * 100,
                    output: 60 + index * 10,
                    cacheRead: 3000,
                    cacheWrite: 0,
                    total: 4260 + index * 110),
            });
        }

        var second = new RootSession
        {
            Id = "4f3c2a10-1234-4abc-9def-556677889900",
            ShortId = "4f3c2a10",
            Title = "Parallel test repair",
            StartedAt = now - 620_000,
            Active = true,
            Turn = 1,
            Model = "deepseek-flash",
            Effort = "high",
            Source = "claude-code",
            SourceLabel = "Claude Code",
            SourceConfidence = "inferred",
            TitleSource = "explicit",
            TaskPreview = "Repair flaky integration tests and rerun the suite",
            ColorKey = 2,
            Tokens = new Tokens(input: 8200, output: 930, cacheRead: 21000, cacheWrite: 0, total: 30130),
        };
        for (int index = 1; index <= 8; index++)
        {
            second.Children.Add(new ChildAgent
            {
                Id = "claude-child-" + index + "-0000-0000-0000-000000000000",
                Label = "test worker " + index + ": repair suite " + index,
                Parent = second.Id,
                StartedAt = now - ((40 - index * 3) * 1000.0),
                Active = true,
                Model = "deepseek-flash",
                Effort = "high",
                Tokens = new Tokens(
                    input: 900 + index * 80,
                    output: 40 + index * 8,
                    cacheRead: 2000,
                    cacheWrite: 0,
                    total: 2940 + index * 88),
            });
        }

        return new List<RootSession> { first, second };
    }

    /// <summary>5 roots sharing the same title, colorKey 0..4 (demo-roots).</summary>
    public static List<RootSession> DemoSameTitleRoots()
    {
        double now = NowMs();
        string[] ids = { "b7b0142f", "1c78e458", "e7c6993a", "0b7b9455", "ab606f91" };
        string[] tasks =
        {
            "Work only inside /Users/you/Projects/agent-ledger/wo/work/p7b-2026-10-16/CI",
            "Work only inside /Users/you/Projects/agent-ledger/wo/work/p7b-2026-10-16/API",
            "Work only inside /Users/you/Projects/agent-ledger/wo/work/p7b-2026-10-16/WEB",
            "Work only inside /Users/you/Projects/agent-ledger/wo/work/p7b-2026-10-16/DOCS",
            "Work only inside /Users/you/Projects/agent-ledger/wo/work/p7b-2026-10-16/OPS",
        };

        var roots = new List<RootSession>();
        for (int index = 0; index < ids.Length; index++)
        {
            roots.Add(new RootSession
            {
                Id = ids[index] + "-0000-4000-8000-00000000000" + index,
                ShortId = ids[index],
                Title = "Work only inside /Users/you/Projects/agent-ledger",
                StartedAt = now - (3_180_000 + index * 17_000),
                Active = true,
                Turn = 1,
                Model = "deepseek-flash",
                Effort = "high",
                Source = "terminal",
                SourceLabel = "Terminal",
                SourceConfidence = "explicit",
                TitleSource = "fallback",
                TaskPreview = tasks[index],
                ColorKey = index,
                Tokens = new Tokens(
                    input: 12000 + index * 1100,
                    output: 1200 + index * 90,
                    cacheRead: 42000 + index * 2300,
                    cacheWrite: 0,
                    total: 55200 + index * 3490),
            });
        }

        return roots;
    }

    /// <summary>No running sessions (--demo-idle).</summary>
    public static List<RootSession> DemoIdleRoots() => new List<RootSession>();

    // Convenience aliases so either naming style links from Program.cs.
    public static List<RootSession> Roots() => DemoRoots();

    public static List<RootSession> ManyRoots() => DemoManyRoots();

    public static List<RootSession> SameTitleRoots() => DemoSameTitleRoots();

    public static List<RootSession> IdleRoots() => DemoIdleRoots();

    /// <summary>
    /// Resolve a Swift-style demo flag ("demo", "demo-many", "demo-roots",
    /// "demo-idle") to its dataset. Unknown modes return an empty list.
    /// </summary>
    public static List<RootSession> ForMode(string? mode)
    {
        switch ((mode ?? "").Trim().ToLowerInvariant())
        {
            case "demo":
                return DemoRoots();
            case "demo-many":
            case "many":
                return DemoManyRoots();
            case "demo-roots":
            case "demo-sametitle":
            case "sametitle":
                return DemoSameTitleRoots();
            case "demo-idle":
            case "idle":
                return DemoIdleRoots();
            default:
                return new List<RootSession>();
        }
    }

    private static double NowMs() => DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
}
