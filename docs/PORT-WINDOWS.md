# dsh-run-bubble — Windows 移植设计契约

> 本文件是并行开发的**唯一接口契约**。所有 agent 按此实现，不得擅自更改跨模块接口。
> 源实现（macOS）：`daemon.mjs`、`overlay.swift`、`run-bubble`、`interop/`。

## 1. 目标与不变量

把 macOS 版**全部功能**迁移到 Windows，行为对等、视觉对齐。

**不变量（不可破坏）**
1. `status.json` schema **v2 字段不变**（见 §3）。daemon 与 overlay 只通过它通信。
2. 视觉几何、字号、颜色、行高、留白与 macOS 版**逐像素对齐**（见 §6 的换算表）。
3. 交互语义不变：hover 展开、pin 常开、长按 350ms 拖拽、滚轮滚动、点击 root 折叠、2.5s 空闲宽限、6s 状态文件过期。
4. 两进程模型不变：Node 守护进程（采集）+ 原生 overlay（渲染）。
5. macOS 版**继续可用**（同一份 `daemon.mjs` 兼容双平台；Swift overlay 保留）。
6. 无遥测、无网络请求、无管理员权限要求。

## 2. 技术选型（已定，勿改）

| 组件 | macOS | Windows | 理由 |
|---|---|---|---|
| 采集守护进程 | Node + `zstd` CLI + `lsof`/`ps` | 同一 `daemon.mjs`，Node 24 内置 `zlib.zstdDecompressSync` + CIM 进程表 | 逻辑 95% 复用，跨平台条件分支 |
| Overlay | Swift + AppKit `NSPanel` | **C# / .NET 8 WinForms + `UpdateLayeredWindow`** | 逐像素 alpha、无窗口边框、可直接复刻手绘逻辑（`Graphics` ↔ `NSBezierPath`） |
| 常驻 | launchd `KeepAlive` | 计划任务（登录时 + 失败重启） | 等价语义 |
| 安装脚本 | `run-bubble`(zsh) | `run-bubble.ps1` | 同名子命令 |

依赖：.NET 8 SDK（构建期）、Node 20+（运行期）。目标机已有 `.NET 8.0.32` + WindowsDesktop Runtime，已验证 `dotnet build` 通过。

## 3. 冻结契约：`status.json` v2

路径：`%DSH_HOME%\run-bubble\status.json`（默认 `C:\Users\<user>\.dsh\run-bubble\status.json`）。

```json
{
  "schemaVersion": 2,
  "updatedAt": 1792316794509,
  "daemonPid": 29389,
  "roots": [{
    "id": "session-0b8729e7-...", "shortId": "0b8729e7", "colorKey": 0,
    "parentSession": null, "depth": 0,
    "title": "Auth refactor", "titleSource": "explicit|fallback",
    "source": "codex", "sourceLabel": "Codex",
    "sourceConfidence": "explicit|inferred|unknown",
    "taskPreview": "...", "cwd": "C:\\Users\\USER\\Desktop",
    "startedAt": 1792316000000, "elapsedMs": 754000, "active": true,
    "turn": 2, "model": "deepseek-flash", "reasoningEffort": "high",
    "label": "", 
    "tokens": { "input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0, "total": 0 },
    "turnTokens": { … },
    "children": [ /* 同构，含 parentSession */ ]
  }],
  "totals": { "sessions": 1, "children": 0, "activeChildren": 0, "tokens": { … } }
}
```

- `daemon.json`（同目录）：`{ pid, startedAt, zstd, platform, mode }`。
- 写入必须**原子**：写 `status.json.tmp-<pid>` 再 `rename`。
- 文件权限：Windows 上用 `File.SetAccessControl` 或直接依赖用户目录 ACL（不需 0600 语义）。

## 4. Windows 活跃性与归属判定（核心移植点）

> **已修订（以此为准）**：下文「Windows 无跨进程锁」的前提**是错的**，已由 `docs/dsh-internals-windows.md` §4 推翻。
> DSH 在 win32 上用**命名内核信号量**实现会话写租约，零文件足迹：
>
> ```
> Local\dsh-session-lock-<sha256(lowercase(resolve(<sessionDir>\session.lock)))>
> ```
>
> - 对象存在 ⟺ 有活进程持写租约；末句柄关闭或进程崩溃即销毁，无超时 —— 与 macOS `flock` **语义等价**。
> - 持有者 PID 可精确取得：`NtQuerySystemInformation(SystemExtendedHandleInformation)` →
>   按 `ObjectTypeIndex` 过滤信号量 → `OpenProcess(PROCESS_DUP_HANDLE)` + `DuplicateHandle` +
>   `NtQueryObject(ObjectNameInformation)` 取名 → 与本地 hash 比对。实测 200 844 句柄 / 67 ms。
> - 本机实测：26 个会话目录中 9 个有活租约（holder 全为桌面宿主），17 个已死。
>
> **原生探针**：`src/lease-probe/`（C#，发布为 `dist/DshLeaseProbe.exe`），只读、不触碰任何租约：
>
> ```
> DshLeaseProbe.exe                → {"ok":true,"scanMs":67,"handles":N,"semaphores":N,
>                                     "leases":[{"pid":35836,"hash":"<64hex>","name":"Local\\dsh-session-lock-<64hex>"}]}
> DshLeaseProbe.exe --lock <path>  → {"ok":true,"scanMs":67,"results":[{"lock":"...","held":true,"pids":[35836]}]}
> 失败                             → {"ok":false,"error":"..."} + 退出码 1
> ```
>
> **判定链（daemon，win32）**
> 1. `holders = leaseHolders(entry.dir)`：
>    - `null` → 探针不可用，降级到 T4（mtime/sidecar 启发式，见下表）；
>    - `[]` → **已死，直接跳过**（无需再看 `openTurn`）；
>    - 非空 → 活，进入归属判定。
> 2. 归属：`holders.some(pid ∈ desktopHostPids)` → 桌面 App 自己的会话，跳过（`RUN_BUBBLE_INCLUDE_DESKTOP=1` 可显式包含）；否则为外部会话。
> 3. source：沿 `holders[0]` 的 `ParentProcessId` 走链（CIM 进程表在内存里走，≤8 层），匹配 `CommandLine`。
> 4. `openTurn` 仍用于 `active` 标记与僵尸判定（T4 模式下才承担活跃性职责）。
> 5. `externalCliPids()` 只用于 source 佐证，**不用于归属**；匹配 `--profile\s+(acp|headless|sdk|web)`，
>    **不要**把 `dsh-desktop-host/lib/cli.js` 当外部标志（它是桌面运行时包装 `dsh` 命令行的入口）。
>
> **降级阶梯（探针不可用时）**：`mtime` 在 `RUN_BUBBLE_LIVE_MS`(120 s) 内，或 sidecar 声明 `surface`/`pid` 且心跳新鲜/进程存活；
> `openTurn && now-lastEventAt > RUN_BUBBLE_STALE_MS`(900 s) → 僵尸丢弃；归属无法证明时默认**包含**（宁可多显示，不可永远空）。
>
> **性能**：租约扫描 67 ms（缓存 1.5 s，每 tick ≤1 次）；CIM 进程表 455 ms（缓存 5 s）；多帧解压仅 `size:mtime` 变化时发生。

<!-- 以下为初版草案，已被上方的租约方案取代，仅作背景保留。 -->

mac 版三信号 → Windows 初版假设：

| 信号 | macOS | Windows 实测 |
|---|---|---|
| `session.lock` + `lsof` | 有 | **不存在**；活跃日志可独占打开 → 无跨进程锁 |
| `ps` 找 `dsh-desktop-host/lib/index.js` | 有 | 有，但路径是**反斜杠**：`dsh-desktop-host\lib\index.js`，必须归一化分隔符再匹配 |
| 父进程链推断 source | 有 | 用 CIM 全量进程表在内存里走，等价可行 |

**判定算法（daemon 实现，按优先级）**
1. `openTurn` = 日志中最后一个 `turn/start` 晚于最后一个 `turn/end`（原逻辑不变）。
2. `live`：
   - 若平台为 win32：`mtime` 在 `RUN_BUBBLE_LIVE_MS`（默认 120000）内 **或** 存在显式 sidecar（`interop` 写入，含 `pid`/`heartbeatAt`）；
   - 若 `openTurn && (now - lastEventAt) > RUN_BUBBLE_STALE_MS`（默认 900000）→ 判定为僵尸，丢弃。
   - 若平台为 darwin：沿用锁语义（`lockHolders()` 返回 `[]` → 跳过）。
3. `desktop` 归属：任一会话若其目录/日志的**持有进程**属于桌面宿主 → 跳过。Windows 无锁时采用：
   - sidecar 显式声明 `surface: "acp" | "headless" | "desktop"` → 直接采信；
   - 否则若当前有桌面宿主进程在跑，且无法证明该会话是外部启动 → **保守跳过**（可通过 `RUN_BUBBLE_INCLUDE_AMBIGUOUS=1` 关闭）；
   - 研发结论见 `docs/dsh-internals-windows.md`，若其中发现更可靠信号则以其为准，并把 `mode` 写进 `daemon.json` 便于诊断。
4. `source` 推断：批量取一次进程表（`ProcessId,ParentProcessId,Name,CommandLine`），按 `ppid` 走链，最多 8 层；`commod` 匹配规则扩平台（`pwsh`/`powershell`/`cmd`/`WindowsTerminal`/`conhost` → terminal）。
5. 所有 CIM/PowerShell 调用必须：`-NoProfile -NonInteractive`、带 2s 超时、结果缓存 3–5s、失败静默降级（`null` 表示"不可用"，不是"空"）。

**性能**：一次 refresh 只允许 **1 次**进程表查询 + N 次日志 stat；解压仅在 `size:mtime` 变化时发生；解压失败保留上次缓存并限流日志。

## 5. 文件布局与归属（禁止越界写）

```
daemon.mjs                      [daemon]
src/win/process-table.mjs       [daemon]   进程表/桌面宿主/source 推断
src/win/zstd.mjs                [daemon]   解压封装 + 容错
src/win/liveness.mjs            [daemon]   live/desktop 判定
src/overlay/RunBubbleOverlay.csproj  [overlay-window]
src/overlay/Program.cs          [overlay-window]  入口/参数/demo 调度/500ms reload
src/overlay/BubbleWindow.cs     [overlay-window]  分层窗口/定位/拖拽/hover/pin/scroll/snapshot
src/overlay/Native.cs           [overlay-window]  P/Invoke
src/overlay/Models.cs           [overlay-render]  Root/Child/Tokens/JSON 解析 + BubbleState + RowHit
src/overlay/Theme.cs            [overlay-render]  颜色/字体/度量
src/overlay/BubbleRenderer.cs   [overlay-render]  行布局 + 绘制 + 命中矩形
src/overlay/DemoData.cs         [overlay-render]  --demo/--demo-many/--demo-roots/--demo-idle 数据
run-bubble.ps1                  [launcher]   install/start/stop/status/logs/uninstall/snapshot/restart
build.ps1                       [launcher]   dotnet publish + 语法检查
scripts/*.ps1                   [launcher]   计划任务注册、日志尾读、健康检查
interop/**                      [interop]    dsh-chat.mjs 跨平台 + install.ps1 + README
docs/dsh-internals-windows.md   [research]
docs/PORT-WINDOWS.md            [lead]
README*.md / CHANGELOG.md / ci.yml / .gitignore   [lead]
```

构建产物：`dist/RunBubbleOverlay.exe`（`dotnet publish -c Release -r win-x64 -o dist`，默认框架依赖，`-SelfContained` 可选单文件自包含）。

## 6. Overlay 视觉契约（Swift → C# 逐值对齐）

坐标系：Swift 是左下原点、y 向上；C# 是左上原点、y 向下。**换算：`yTop = height - ySwiftBottom - itemHeight`**。所有尺寸视为 DIP，按 `DeviceDpi/96` 缩放。

**面板**：折叠 `238×42`；展开 `356 × min(420, max(96, 30 + contentHeight + (idle?0:28) + 14))`。
圆角 13，描边 1（内缩 0.5）。`pad=12, headerH=30, footerH=28`。

**颜色**（dark / light）
| 角色 | dark | light |
|---|---|---|
| bg | #1A1A1A @93% | #FCFCFC @94% |
| fg | #F5F5F5 | #1F1F1F |
| muted | #B3B3B3 | #666666 |
| taskFg | #D1D1D1 | #474747 |
| border | #FFFFFF @12% | #000000 @8% |
| accent | #30D158 | #30D158 |
| palette[6] | #0A84FF #FF9F0A #30B0C7 #BF5AF2 #FF375F #30D158（light 用 #007AFF #FF9500 #30B0C7 #AF52DE #FF2D55 #34C759） |

**字体**：`Segoe UI`（semibold→`Segoe UI Semibold`）；等宽 `Cascadia Mono` 回退 `Consolas`。尺寸沿用 Swift 值（9/9.5/10/10.5/11/11.5/12）。

**头部**：文案 idle `空闲`；1 root `外部任务运行中`；n `{n} 个外部任务`；截断 18 字符（按显示宽度）。字号 11.5 semibold。状态点 7×7：展开时距顶 16，折叠时垂直居中；idle 为 muted@55%，否则 accent@(0.95·pulse+0.05)。时间右对齐 `width-14-(expanded?22:0)`，11.5 semibold mono，`m:ss` 或 `h:mm:ss`。`N 子` 徽标 9.5 semibold muted，高 14 圆角 7，底色 白/黑 @8%/6%，右边界 = `width-14-(expanded?22:0) - 时间宽 - 8`。pin 按钮 18×18，位于右上（距右 14、距顶 6），展开时显示，实心/空心表示 pinned，颜色 accent/muted。`headerH` 处画分隔线（pad→width-pad）。

**行**（自上而下，起点 `bodyTop = headerH+8 = 38`）
| 行 | 高 | 内容 |
|---|---|---|
| root | 18 | 色点 6×6(x=pad)；有子时在 `pad+10` 画 `▾`/`▸`(9 bold muted)，标题 x=`pad+21` 否则 `pad+11`；标题 11.5 semibold fg，截断 22；右侧时长 11 semibold mono，右界 `width-pad` |
| meta | 16 | chips：起点 `pad+11`，右界 `width-pad-8`，高 14 圆角 6，间距 5，字号 9.5 |
| task | 16 | `›`(11 bold accent) @`pad+11`；文本 10 taskFg @`pad+21`，截断 46 |
| child | 17 | 缩进 22；色点 5×5 @`pad+indent-8`；标题 10.5 fg @`pad+indent` 截断 22；时长 10 mono muted 右对齐 `width-pad`；`← 前8位` 9.5 muted 右对齐（时长左侧 8px） |
| empty | 36(全局) / 16(root 内) | 10.5 muted；副文本 9.5 muted，下移 17 |
| divider | 8 | 中线在行内 +4，pad→width-pad，border@55% |

chips 样式：
- `source`：色 = palette[colorKey]，底 = palette@(dark .22/light .14)，semibold，无前缀
- `id`：`#{id前4位}`，mono medium，fg=muted，底 白/黑@(dark .07/light .05)
- `count`：`{n} 子`，fg=accent，底 accent@(dark .16/light .10)
- `plain`(model)：fg=muted，无底色，左右 padding 2
- `effort`：`推理 {关|低|中|高|最高}`，fg=dark #FF9F0A / light #A65C05，底 orange@(dark .14/light .10)
- `turn`：`T{n}`，mono medium，fg=muted，无底色

行生成顺序（每个 root）：root → meta（chips 非空时）→ task（`taskPreview` 非空且 ≠ title）→ children/empty（未折叠时；**只列 active 子**）→ divider（非最后一个）。
`contentHeight = Σ行高 + 10`。`viewport = height - 38 - (idle?0:34)`；`bodyBottom = idle?0:34`。滚动条：x=`width-8`，宽 4，圆角 2，thumb 高 `max(18, viewport²/content)`，底色 白/黑@(dark .10/light .08)，thumb @38%。

**空闲态**：单行 `没有外部任务在运行` + 副文本 `等待外部 ACP / headless 调用`，高 36；页脚隐藏。

**页脚**（非 idle）：分隔线在距底 22 处；`Token {compact(total)}` 10 muted 左 @pad，距底 8；右侧 `入 {x}   出 {y}   缓存 {z}` 9.5 mono muted。

## 7. 渲染器 / 窗口 接口（冻结）

```csharp
namespace DshRunBubble;

// Models.cs —— overlay-render 提供
sealed class Tokens { public int Input, Output, CacheRead, CacheWrite, Total; }
sealed class ChildAgent { public string Id, Label, Parent, Model, Effort; public double StartedAt, ElapsedMs; public bool Active; public Tokens Tokens; }
sealed class RootSession { public string Id, ShortId, Title, Cwd, Source, SourceLabel, SourceConfidence, TitleSource,
        TaskPreview, Model, Effort; public int ColorKey, Turn; public double StartedAt, ElapsedMs;
        public bool Active; public Tokens Tokens; public List<ChildAgent> Children = new(); }
static class StatusDoc { public static List<RootSession> Parse(string json); }   // 容错：解析失败返回空列表

// 共享状态 —— overlay-render 定义，overlay-window 只读/改字段
sealed class BubbleState {
    public List<RootSession> Roots = new();
    public bool Expanded, Pinned;
    public float ScrollOffset, Pulse = 1f;
    public HashSet<string> CollapsedRoots = new();
}

// Theme.cs —— overlay-render 提供
sealed class Theme {
    public static Theme Create(bool dark);
    public Color Bg, Fg, Muted, TaskFg, Border, Accent;
    public Color GroupColor(int index);
    public Font Font(float size, bool semibold, bool mono);   // 内部缓存，调用方不要 Dispose
}

// BubbleRenderer.cs —— overlay-render 提供
readonly struct RootRowHit { public string RootId; public RectangleF Bounds; }   // Bounds 为顶左原点视口坐标
sealed class RenderResult {
    public List<RootRowHit> RootRows = new();
    public float ContentHeight, ViewportHeight, PreferredHeight;
}
static class BubbleRenderer {
    public static float PreferredHeight(BubbleState state);                     // 供 resize 前调用
    public static RenderResult Render(Graphics g, float width, float height, BubbleState state, Theme theme);
    // Render 必须：绘制整块面板（含背景/圆角/描边），并填充 RootRows 供命中测试；不得读写窗口句柄。
}
```

窗口侧职责：DPI、定位与锚点、拖拽判定、hover 进出、pin 点击、滚轮、`--snapshot` 导出 PNG、状态文件轮询与 2.5s 宽限。
渲染侧职责：一切像素、行布局、命中矩形。

## 8. 启动器契约 `run-bubble.ps1`

```
run-bubble.ps1 install  [-Rebuild] [-SelfContained]   构建 + 复制到 %LOCALAPPDATA%\dsh-run-bubble + 注册计划任务 + 启动
run-bubble.ps1 start | stop | restart
run-bubble.ps1 status        # 两进程 PID + roots/children/tokens 摘要
run-bubble.ps1 logs          # 两个日志尾部 40 行
run-bubble.ps1 snapshot [path]   # 调 overlay --snapshot，默认 %TEMP%\dsh-run-bubble.png
run-bubble.ps1 uninstall     # 注销任务 + 删 %LOCALAPPDATA%\dsh-run-bubble
```
安装位置：`%LOCALAPPDATA%\dsh-run-bubble\{daemon.mjs, src\win\*, RunBubbleOverlay.exe, run-bubble.ps1}`。
日志：`%LOCALAPPDATA%\dsh-run-bubble\logs\{daemon,overlay}.{out,err}.log`。
计划任务：`DshRunBubble-Daemon`、`DshRunBubble-Overlay`，登录触发、`MultipleInstances=IgnoreNew`、失败 1 分钟重启、隐藏窗口。
**幂等**：重复 install 必须先停旧任务再注册；`uninstall` 保留会话日志与 `status.json`。

## 9. 验收标准

1. `pwsh -File build.ps1` 零警告零错误；`node --check daemon.mjs` 通过。
2. `RunBubbleOverlay.exe --demo --snapshot X.png` 生成 356 宽、视觉与 `docs/images/expanded.png` 一致的图；`--demo-idle`、`--demo-many`、`--demo-roots`、`--collapsed`、`--collapse-first`、`--scroll N` 全部可用。
3. `daemon.mjs` 在本机真实会话库上 3 秒内产出合法 `status.json`（`roots` 为数组、字段齐全、无异常）。
4. overlay 常驻：置顶、不在任务栏、不抢焦点、hover 展开/离开折叠、pin、长按拖拽、滚轮、点击折叠逐个实测通过。
5. `install/start/stop/restart/status/logs/snapshot/uninstall` 全流程可用且幂等。
6. `interop/dsh-chat` 在 Windows 上写出 sidecar 且气泡显示 Codex/Claude Code 等来源。
7. 文档：README 增 Windows 章节（英文 + 中文），CHANGELOG 记录，CI 增加 windows job。

## 10. 已知差异（必须写入文档）

- 无虚拟桌面"固定到所有桌面"能力（macOS `canJoinAllSpaces`）；仅保证置顶。
- 活跃性/归属：**不靠启发式** —— win32 用命名信号量租约 + 句柄表精确判定，与 macOS 的 `flock`+`lsof` 语义等价；仅当原生探针不可用时才降级为 `mtime`/sidecar 启发式（此时会标记 `mode: "win-mtime"`）。
- 无 Accessibility/录屏权限需求（Windows 上也不需要）。
- UI 文案保持中文优先（与上游一致）。
