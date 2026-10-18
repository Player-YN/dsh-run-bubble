# DSH × Windows：会话锁、存活判定、归属与内部格式（逆向报告）

> **用途**：为 `dsh-run-bubble` 的 Windows 移植提供依据。本文只描述**已在本机实测或已在已安装产物中定位到代码**的事实；凡未验证的一律标注「未验证」。
>
> **分析对象**
> - 已安装产物：`C:\Users\USER\AppData\Local\Programs\DeepSeek Harness\resources\app.asar`（182,794,869 B）
>   - 内含 DSH 版本 **0.2.1-rc.2**（`/dsh/package.json`，见附录 A 命令 `version`）
> - 本机源码 checkout：`C:\Users\USER\deepseek-harness`，版本 **0.1.5-rc.2**（更旧，仅作可读 TS 参考；**结论以 asar 为准**）
> - 运行时：Node v24.11.1；DSH_HOME=`C:\Users\USER\.dsh`；桌面宿主 PID 35836
> - 采集工具：`%TEMP%\dsh-asar\*.mjs`（附录 A），FFI 用 DSH 自带的 `koffi`（`%DSH_HOME%\profiles\node_modules\koffi`）

---

## 0. 结论摘要

| # | 问题 | 结论 | 置信度 |
|---|---|---|---|
| 1 | mac 的 `session.lock` 在 Windows 上是什么 | **不存在文件**。Windows 用**命名内核信号量**（`Local\dsh-session-lock-<sha256(小写化绝对锁路径)>`）实现同一把「单写者」锁，**零文件系统足迹** | **高**（源码 + 实测） |
| 2 | Windows 上能否判断"会话有活进程在写" | **能，且是精确的**：信号量对象只在其持有者的句柄存活期间存在，`OpenSemaphoreW` 探测存在性 = 精确存活判定；进一步用句柄表可拿到**持有者 PID** | **高**（实测 26 个会话：9 活 / 17 死，负对照 ERROR_FILE_NOT_FOUND） |
| 3 | 是否存在心跳/注册表/pid 文件/单例监听 | **没有**。`.dsh` 下无 `.pid/.sock/.lock/.db`；projcache 是"提交时刷新的投影缓存"不是心跳；唯一跨进程对象就是那把信号量 | **高**（文件系统全扫 + 代码） |
| 4 | 桌面 App 发起的会话 vs 命令行会话如何区分 | Session header **没有任何来源字段**；但「谁持有租约」= 精确答案：holder PID ∈ 桌面宿主 PID 集合 → 桌面会话 | **高**（实测 9/9 桌面） |
| 5 | 桌面宿主 PID 怎么认 | 进程表里 `CommandLine` 含 `dsh-desktop-host\lib\index.js`（**反斜杠**，必须分隔符无关匹配） | **高**（实测 PID 35836） |
| 6 | 子会话如何创建/落在哪 | 父日志 `subagent/catalog` 记子 id；子日志 header 有 `parentSession` + `origin:"subagent"` + `delegationDepth:1`；**落在同一 projectDir** | **高**（实测 6 个子会话） |
| 7 | v4 `assistant/message.usage` 字段 | `inputTokens / outputTokens / cacheReadTokens / cacheWriteTokens / totalTokens`（v0 旧格式多一个 `reasoningTokens`、无 `totalTokens`） | **高**（实测） |
| 8 | 能否只靠"进程 cwd + 最近写入会话"映射进程→会话 | **不能稳定**。新会话 id 不在命令行里；ACP 的 cwd 由 client 参数给，不等于进程 cwd。**精确映射只能靠租约持有者 PID** | **高**（代码 + 实测） |
| 9 | 日志解码 | ⚠️ **`zlib.zstdDecompressSync` 只能解出第一帧**（本机 159 KB 日志只出 278 B / 1 行，实际 648,804 B / 198 行）。DSH 每次追加写一帧，必须逐帧解压 | **高**（实测） |
| 10 | 有没有别的跨进程锁 | 有 `dsh-atomic-write` 的 `<file>.lock`（内容是 `<pid>\n`，wx 创建），但**只用于存储 JSON/配置的读-改-写**，与会话无关 | **高**（源码） |

**一句话**：mac 版「锁 + `lsof` 找 PID」在 Windows 上**有完全对等的替代品**（命名信号量 + 句柄表反查 PID），`daemon.mjs` 的 `lockHolders()` / `desktopPids()` 两个函数可以在 win32 上**语义不变地**重新实现，主循环其余逻辑不需要改。真正的坑只有两个：**锁文件不存在（不能 stat `/path/session.lock`）** 和 **多帧 zstd**。

---

## 1. 核心机制：Windows 上的会话写租约（write lease）

### 1.1 机制总述

代码位置（asar 内，**未压缩的 JS + JSDoc**，可直接抽取阅读）：

```
/dsh/node_modules/@deepseek-ai/dsh-session-persistence-jsonl/lib/index.js   (147,273 B)
  ├─ //#region lib/types/format.js      → 目录布局、header 编解码
  ├─ //#region lib/types/win32.js       → Windows 原语（MoveFileExW / 命名信号量）
  └─ //#region lib/types/lease.js       → SessionWriteLease（跨进程写锁）
```

`lease.js` 的模块注释（原文，节选）：

```
 * Cross-process write-ownership lock for one session's artifact directory,
 * held for the whole life of a write handle. The arbiter is the kernel:
 * POSIX takes a non-blocking `flock(2)` via native system support on `session.lock`
 * beside the log, and Windows holds a named kernel semaphore derived from
 * that path — never a file lock or handle, so readers, searches, and
 * directory removal proceed freely while the lock is held. Contention maps
 * to `SessionAlreadyOwnedError`; the kernel releases the lock when the
 * holder's descriptor or last object handle closes, including on any process
 * death, so a crashed holder never blocks a successor. A live but wedged
 * holder keeps the lock until its process exits: there is deliberately no
 * expiry ...
```

已安装版 README（`dsh-session-persistence-jsonl/README.zh.md` 第 168 行）说得更直白：

> **每会话一个活动写入方**——写句柄认领在所属后端实例内排除第二个写入方，内核锁（`session.lock` 上的非阻塞 `flock(2)`；**Windows 上为由该路径派生的命名内核信号量，零文件系统足迹**）排除其他所有实例与进程；锁在以写模式打开既有产物时立即获取，新建会话则仅在首次实体化写入之前获取……**Windows 信号量名按登录会话隔离**。

### 1.2 锁是如何按平台门控的（源码原文）

```js
// lib/types/lease.js
/** Base name of the kernel lock file inside a session's directory. */
const LEASE_FILENAME = "session.lock";

var SessionWriteLease = class SessionWriteLease {
  static async acquire(dir, id) {
    const path = join(dir, LEASE_FILENAME);
    await mkdir(dir, { recursive: true, mode: 448 });
    if (process.platform === "win32") {                 // ← 平台门控在这里
      let handle;
      try {
        handle = await acquireLockHandleWin32(path);
      } catch (error) {
        if (error?.code === "EBUSY") throw new SessionAlreadyOwnedError(id);
        throw error;
      }
      return new SessionWriteLease({ kind: "win32", handle });
    }
    for (let attempt = 0; attempt < 3; attempt += 1) {   // POSIX: flock(session.lock)
      const handle = await open(path, "w");
      try {
        try { await tryLockExclusive(handle.fd); }        // @deepseek-ai/node-addon-system/flock
        catch (error) { if (isLockContention(error)) throw new SessionAlreadyOwnedError(id); throw error; }
        const held = await handle.stat({ bigint: true });
        const current = await stat(path, { bigint: true })... // inode 校验（防 unlink-recreate）
        if (current !== void 0 && current.ino === held.ino && current.dev === held.dev)
          return new SessionWriteLease({ kind: "posix", handle });
      } catch (error) { await handle.close(); throw error; }
      await handle.close();
    }
    throw new SessionAlreadyOwnedError(id);
  }
  async release() {
    if (this.released) return;
    this.released = true;
    if (this.held.kind === "win32") { await releaseLockHandleWin32(this.held.handle); return; }
    await this.held.handle.close();                        // POSIX 锁文件永不删除
  }
};
```

### 1.3 Windows 信号量的名字算法（移植时必须逐字节复刻）

```js
// lib/types/win32.js
async function acquireLockHandleWin32(path) {
  const api = await win32();                                  // koffi → kernel32.dll
  const name = `Local\\dsh-session-lock-${createHash("sha256").update(resolve(path).toLowerCase()).digest("hex")}`;
  const handle = api.createSemaphoreW(null, 1, 1, name);      // 初值 1、最大 1
  if (handle === 0) throw win32Error("CreateSemaphoreW", api.getLastError(), path, name);
  const wait = api.waitForSingleObject(handle, 0);            // 0 超时 = 非阻塞
  if (wait === WAIT_OBJECT_0) return handle;
  api.closeHandle(handle);
  if (wait === WAIT_TIMEOUT) throw win32Error("WaitForSingleObject", ERROR_SHARING_VIOLATION, path, name); // → EBUSY → SessionAlreadyOwnedError
  throw win32Error("WaitForSingleObject", api.getLastError(), path, name);
}
async function releaseLockHandleWin32(handle) {
  const api = await win32();
  api.releaseSemaphore(handle, 1, null);
  api.closeHandle(handle);                                    // 末句柄关闭 ⇒ 内核对象销毁
}
```

关键点：

- `path` = `join(dirname(日志绝对路径), "session.lock")`，即 **`<sessionDir>\session.lock`**，但这个文件**不一定存在、也不需要存在**（`mkdir` 只建目录；Windows 分支从不 `open` 该文件）。
- 名称前缀 **`Local\`** = 每个登录会话一份命名空间（README：「Windows 信号量名按登录会话隔离」）。同一用户同一登录会话内的进程互相可见。
- `resolve(path).toLowerCase()` = **全小写化**，因此盘符/目录大小写差异不影响匹配；但 8.3 短名、junction/symlink 会破坏匹配（见 §10）。
- FFI 是 **koffi**（DSH 依赖里自带，`@koromix/koffi`）。DSH 只在 win32 才 `import("koffi")`，非 Windows 不加载。

### 1.4 锁的生命周期（这决定了"什么算 live"）

| 时点 | 行为 |
|---|---|
| 打开既有会话的写句柄 | 立即 `SessionWriteLease.acquire()` |
| 新建会话 | 延迟到**第一次实体化写入之前**才取锁（未实体化会话无痕迹） |
| 关闭写句柄 / 进程退出 / 崩溃 | `closeHandle`（或进程死亡时内核回收）⇒ 对象销毁，后继者可立即写入 |
| 有没有超时/过期 | **故意没有**（避免抢占卡死写者）；卡死但存活的持有者会一直占锁直到进程退出 |
| 读、搜索、删目录 | 完全不受影响（没有文件、没有文件句柄） |

**语义结论（很重要）**：租约 ≠ "正在跑一轮"。它等于 **"该会话被某个活进程以写句柄持有"**。实测证据：`session-3d69f569-…` 只有 4 行、0 个 turn、323 B（用户在桌面 App 里新建的空会话），文档撰写时仍 **LIVE**（被 35836 持有）。这与 mac 的 `flock` 语义**完全一致**（mac 上 UI 打开的会话同样持锁），所以气泡的既有行为不需要重新定义。

### 1.5 本机为什么一个 `session.lock` 都没有

```powershell
PS> Get-ChildItem C:\Users\USER\.dsh -Recurse -Force -Filter session.lock | Select-Object FullName
(none)
```

与已知事实一致：Windows 分支**从不创建该文件**。因此任何 `stat('<dir>\\session.lock')` 判断都会永远为 false —— 移植时**不能**用文件存在性作为门槛。

### 1.6 其他锁（都不是会话锁）

| 机制 | 位置 | 用途 | 能否用于会话存活 |
|---|---|---|---|
| `dsh-atomic-write` 的 `<file>.lock` | `/dsh/node_modules/@deepseek-ai/dsh-atomic-write/lib/index.js` | `wx` 创建，内容 `<pid>\n`，`EEXIST` 视为争用，持有者 PID 消失则接管。用于**存储 JSON / 配置文件的读-改-写串行化** | 否（秒级瞬态、且与会话无关） |
| Electron/Chromium `lockfile` | `%APPDATA%\@deepseek-ai\dsh-desktop\lockfile` | 桌面 App 自己的单例/进程锁 | 否（只能说明"App 在跑"） |
| 桌面宿主 IPC | 匿名管道 fd 3/4（`dsh-desktop-host` ↔ Electron 主进程） | 私有协议，无监听端口 | 否（外部不可访问） |

实测：`lockfile` 在 App 运行时**可以被只读打开**（内容为空字符串），说明它不是独占句柄，不能当信号用：

```
1) lockfile opened; content = ""
```

---

## 2. Q2 活跃性：有没有运行时注册表 / 心跳 / 单例监听？

### 2.1 文件系统全扫结论：没有

```
PS> Get-ChildItem C:\Users\USER\.dsh -Recurse -File -Force |
      ? { $_.FullName -notmatch '\\sessions\\|\\node_modules\\|\\dsh-runtimes\\' }
.agent-presets\**            (agent preset 配置)
.anonymous-user-id
.credentials.yaml
attachments\v1\objects\**    (附件内容寻址存储)
llm-deepseek\files-v3.json   (文件引用缓存)
profiles\{desktop,headless,web}\{package.json,cordis.yml,cordis.patch.yml,pnpm-workspace.yaml}
settings.yaml.imported
storages\session_projcache.json          (旧版聚合缓存, 2026-08-19 后不再更新)
storages\session_projcache\sessions\*.json (现行投影缓存, version 7)
storages\workspace.json                  (工作区注册表)
run-bubble\**                            (本项目自己的目录)

PS> Get-ChildItem C:\Users\USER\.dsh -Recurse -Force |
      ? { $_.Name -match '\.(pid|sock|lock|mutex|db|sqlite|sqlite3)$' -and $_.FullName -notmatch 'node_modules' }
(none)
```

⇒ **没有 pid 文件、没有 socket/命名管道文件、没有 sqlite 索引、没有任何心跳文件。**
（`dsh-session-query-sqlite` 包存在，但本机 `storages` 下无 `.db`，说明该后端未启用。）

### 2.2 三个 `storages` 单元的写入方与语义

| 文件 | 谁写 | 内容 | 能否判活 |
|---|---|---|---|
| `session_projcache\sessions\<id>.json` | **base 层**（`dsh-session-projection-cache`，见 `dsh-base/cordis.patch.yml:196`）⇒ **所有表层都写**（desktop/web/acp/headless） | 投影：title/tokenUsage/sessionStats/turnOutline/todos/plan/subagent*/sessionListMetadata/imageLimits/agentTeam…（`record.identity` = `{formatVersion,createdAt,cwd,isSeeded,inheritedEventCount}`） | **否**。只在"投影变化提交"时刷新，不是心跳；见 2.3 反例 |
| `workspace.json` | **web-app 层**（`dsh-workspace`，见 `dsh-web-app/cordis.patch.yml:91`）⇒ 仅 desktop / `dsh web` 写 | `global.workspaceIds / archivedSessionIds / pinnedSessionIds` + `tables.workspaces.<id>.{path,title,sessionIds,createdAt,updatedAt}` | 否（是 UI 的工作区归属，不是存活） |
| `session_projcache.json`（旧） | 旧版本 | 已停更（mtime 2026-08-19），可忽略 | 否 |

### 2.3 projcache 不能判活的实测反例

同一时刻对比（`sessionStats.val.openStep` 存在 = 提交时有一个 step 处于打开状态）：

```
LIVE 5a41c432-…  openStep {"turn":1,"step":56,...}   turnBoundary.openTurnStartSeq=5
dead f7cee991-…  openStep {"turn":1,"step":20,...}   turnBoundary.openTurnStartSeq=5   ← 已死，但 openStep 仍在
dead d111aa16-…  openStep null
dead session-99b2eceb-… openStep null
```

⇒ 子 agent 结束后 projcache 不会把 `openStep` 清空（没有后续提交就没有刷新），**用 `openStep` 判活会误判**。

### 2.4 桌面 App 单例：不可用

- `%APPDATA%\@deepseek-ai\dsh-desktop\lockfile` 存在但可只读打开（见 §1.6）。
- `%APPDATA%\@deepseek-ai\dsh-desktop\logs\` 是**空目录**。
- `desktop\settings.json` 只有 `{"updates":{"allowTestAuthPopupWindow":false}}`。
- 桌面宿主的监听端口（实测 35836 监听 `127.0.0.1:25318`、`127.0.0.1:9230`）**需要启动 token**：

```
GET http://127.0.0.1:25318/      → 401 "dsh web authentication required; reopen the URL printed by dsh web."
GET http://127.0.0.1:25318/api   → 401 "unauthorized"
```

  token 只出现在 Electron 主进程收到的"启动 URL"里，**不落盘**（已 grep `Preferences` / `Local Storage\leveldb`，无 25318）。⇒ **不能用桌面 App 的 HTTP API 查询"打开了哪些会话"**。

### 2.5 结论

> DSH **没有**任何运行时注册表、心跳、pid 文件、单例 socket 或 sqlite 活表。唯一能回答"某会话当前是否有活进程在写"的跨进程对象，就是 §1 的**命名内核信号量**。所有 JSON 状态文件都只是「缓存」或「配置」，写入时机由提交驱动，**不能当心跳**。

---

## 3. Q3 归属：谁能区分「桌面 App 发起」与「命令行发起」

### 3.1 Session header：没有来源字段（权威 schema）

从 asar 内 zod schema / `.d.ts`（`dsh-session` 包）抽取：

```ts
export interface SessionHeader {
    readonly version: typeof SESSION_FORMAT_VERSION;
    readonly id: SessionId;
    readonly createdAt: number;
    readonly cwd?: string;
    readonly parentSession?: SessionId;
    readonly isSeeded: boolean;               // 是否含 fork 继承前缀
    readonly origin?: 'subagent';             // 只可能是 "subagent"
    readonly delegationDepth?: number;
    readonly agentPreset?: string;
}
```

实测 26 个日志的 header 键并集：`type, version, id, createdAt, cwd, parentSession, origin, delegationDepth, agentPreset, isSeeded`。
⇒ **没有 surface / profile / client / launcher / origin(desktop|cli) / parentProcess 字段**。`origin` 的取值域被 zod 限定为字面量 `"subagent"`，不能表达"桌面 vs 命令行"。

### 3.2 `~/.dsh/profiles/*` 是"组合配置"，不给会话打标

```
profiles/desktop/package.json   → dsh.profile.bundles = [dsh-base, dsh-web-app, experimental-* ...]
profiles/headless/package.json  → bundles = [dsh-base, dsh-headless]
profiles/web/package.json       → bundles = [dsh-base, dsh-web-app]
profiles/*/cordis.yml           → 空数组（组合根，由 patch 层叠加）
profiles/*/cordis.patch.yml     → 用户覆盖层（模型、主题、语言…）
```

⇒ 只是**启动时决定挂哪些插件**的配置，不含任何会话 id 或会话标签。会话数据全部落在共享的 `DSH_HOME\sessions`、`DSH_HOME\storages`。

### 3.3 `sessionListMetadata` 里没有线索

`storages\session_projcache\sessions\<id>.json` → `record.rows.sessionListMetadata`：

```json
{"ver":1,"seq":261,"val":{"blank":false,"lastPromptAt":1792334983395}}
```

只有 `blank`（空会话）和 `lastPromptAt`。**没有** source/surface/profile 字段。

### 3.4 日志里唯一的"表面"痕迹：runtime-context 的 `app:web-surface`

v4 日志把「运行时上下文快照」记成结构化的 `user/message`：

```json
{"type":"user/message","seq":17,"time":1792334737811,
 "data":{"source":{"kind":"runtime-context","form":"snapshot",
   "sections":[
     {"name":"working-directory:current","text":"Current working directory: \"C:\\\\Users\\\\USER\\\\Desktop\"."},
     {"name":"sandbox:policy","text":"Current DSH file policy: danger-full-access. ..."},
     {"name":"approval:policy","text":"Approval prompts are disabled ..."},
     {"name":"harness:source","text":"Current DeepSeek Harness implementation checkout: \"...app.asar\\\\dsh\\\\\"."},
     {"name":"app:web-surface","text":"Current DeepSeek Harness Web GUI URL: \"http://127.0.0.1:25318\"."}
   ]},
  "role":"user","id":"..."},"surfaceOp":"append"}
```

- `app:web-surface` 的值来自 `webApp.getAdvertisedUrl()`（= 监听器 origin，或配置的 `publicUrl`）。
- 生产者是 `@deepseek-ai/dsh-harness-dev-context`；它 `inject: ["systemPrompt","sessionProjections","webApp"]`，且 **只被 `dsh-web-app` 挂载**（`dsh-web-app/cordis.patch.yml:211`），`dsh-base` 里没有。
  ⇒ 该 section 的出现等价于「产生这条消息的进程是 **GUI 组合**（desktop 或 `dsh web`）」。
- 快照规则：**值不变就不追加**。所以它只会出现在「首轮」或「URL 变化后」的第一条消息，不能只看最后一条。

实测 26 个日志的 URL 分布（按年代）：

```
2026-10-18 desktop 会话 / 子会话 → section:http://127.0.0.1:25318   (现桌面宿主端口)
2026-09-29 会话(旧桌面宿主)      → prose:http://127.0.0.1:19387      (旧格式，值写在 system prompt 里)
2026-08 会话(dsh web)            → prose:http://127.0.0.1:3091 / :3080
```

### 3.5 workspace.json 也是 GUI 专属（次要信号）

`workspace.json` 的 `tables.workspaces[].sessionIds` 收录的是 **UI 工作区里的根会话**（子会话不收录）。它由 `dsh-workspace` 写，而该插件只在 web-app 层挂载 ⇒ 可以当作「GUI 表面」的弱证据，**不能**当"桌面 App 启动"的证据（`dsh web` 同样会写）。

### 3.6 决定性信号：租约持有者 PID

`lease` 的持有者就是**当前对该会话持有写句柄的进程**。用 §4 的方案拿到 holder PID 后：

```
holder ∈ {含 dsh-desktop-host\lib\index.js 的进程}  → 桌面 App 的会话（跳过）
holder ∉ 该集合                                    → 外部会话（气泡显示）
无 holder                                          → 已死
```

实测（2026-10-18 22:5x，26 个会话）：

```
DESKTOP  --C-Users-USER-Desktop--\02c52557-21d9-4a18-b09b-fc78de8e735a   35836  DeepSeek Harness.exe
DESKTOP  --C-Users-USER-Desktop--\5a41c432-a846-4be1-a096-4dcb6ad75748   35836  DeepSeek Harness.exe
DESKTOP  --C-Users-USER-Desktop--\session-REDACTED-0b8729e7 35836  DeepSeek Harness.exe
DESKTOP  --C-Users-USER-Desktop--\session-3d69f569-861a-407f-9b86-a7c7843e4237 35836  DeepSeek Harness.exe
... (共 9 个活会话，全部 35836)
dead sessions: 17/26
```

桌面宿主命令行（`Win32_Process.CommandLine`，注意**反斜杠**与 `--expose-internals`）：

```
"C:\Users\USER\AppData\Local\Programs\DeepSeek Harness\DeepSeek Harness.exe" --expose-internals
  "C:\Users\USER\AppData\Local\Programs\DeepSeek Harness\resources\app.asar\dsh\node_modules\@deepseek-ai\dsh-desktop-host\lib\index.js"
  "...\resources\app.asar\dsh"
  C:\Users\USER\.dsh\profiles\desktop
  "...\resources\runtime\primary-runtime"
  "...\runtime\primary-runtime\dependencies\pnpm\bin\pnpm.mjs"
  "...\resources\runtime\bin"
```

> ⚠️ mac 版 `daemon.mjs` 用 `line.includes('dsh-desktop-host/lib/index.js')`（正斜杠）会**永不命中**。必须 `/dsh-desktop-host[\\/]lib[\\/]index\.js/i`。
> 另外：桌面宿主的**子进程**（工具执行器 `dsh-subprocess-local\lib\runner.js`）也是 `DeepSeek Harness.exe`，不要误判为宿主。

### 3.7 归属判定方案对比

| 方案 | 能回答 | 可靠性 | 延迟 | 成本 |
|---|---|---|---|---|
| **A. 租约持有者 PID**（§4） | 精确：活/死 + 桌面/外部 + 可用于推 source | **高** | 一次句柄表扫描 ~67 ms | 中（需要 FFI 或 PowerShell Add-Type） |
| B. `app:web-surface` URL + 端口→进程 | GUI 表面 vs 非 GUI；再按端口归属分 desktop/web | 中高（受"值不变不追加"影响，且只能反映最后写入者） | 读日志已含 | 低 |
| C. `workspace.json` 成员 | 根会话是否被 GUI 工作区收录 | 中（dsh web 也会写；不覆盖子会话） | 读一次 JSON | 极低 |
| D. 桌面 App 是否在跑 | 只能说明"有桌面 App"，不能归属到具体会话 | 低 | — | — |

---

## 4. 精确方案：拿到信号量的持有者 PID（本报告最重要的产出）

### 4.1 原理

1. 内核对象**引用计数**：`releaseLockHandleWin32()` 先 `ReleaseSemaphore` 再 `CloseHandle`；持有者崩溃时内核回收句柄。⇒ **对象存在 ⟺ 有进程当前持有该租约**。
2. 用 `NtQuerySystemInformation(SystemExtendedHandleInformation = 64)` 拿到全系统句柄表（进程、句柄值、类型索引）。
3. 用「自己创建的一个命名信号量」反查 **Semaphore 的 ObjectTypeIndex**（类型索引随系统而变，不能硬编码）。
4. 对每个信号量句柄：`OpenProcess(PROCESS_DUP_HANDLE)` → `DuplicateHandle` → `NtQueryObject(ObjectNameInformation)` → 得到 `\Sessions\<n>\BaseNamedObjects\dsh-session-lock-<hash>`。
5. 把 hash 与「会话目录推导出的 hash」比对 ⇒ **会话 → holder PID**。

`SYSTEM_HANDLE_TABLE_ENTRY_INFO_EX` 的 x64 布局（本机实测校验：`HandleValue` 在 +16，`ObjectTypeIndex` 在 **+30**，条目 40 B，数组起点 +16）：

```
+0 Object, +8 UniqueProcessId, +16 HandleValue, +24 GrantedAccess,
+28 CreatorBackTraceIndex(2), +30 ObjectTypeIndex(2), +32 HandleAttributes, +36 Reserved
```

### 4.2 实测结果（参考实现见附录 A `win-lease-attribution.mjs`）

```
handle snapshot: 200844 handles, 9384 semaphores, 9 DSH leases, 67 ms
process table: 367 rows, 455 ms; desktop hosts: 35836

LIVE  session                                                      holder  ownerImage
DESKTOP   --C-Users-USER-Desktop--\02c52557-21d9-4a18-b09b-fc78de8e735a      35836  DeepSeek Harness.exe
DESKTOP   --C-Users-USER-Desktop--\07a0fa8c-8b15-4a58-8017-007ffb805bd6      35836  DeepSeek Harness.exe
DESKTOP   --C-Users-USER-Desktop--\497c63a5-5935-4bbc-83ed-419fcdeb307e      35836  DeepSeek Harness.exe
DESKTOP   --C-Users-USER-Desktop--\5a41c432-a846-4be1-a096-4dcb6ad75748      35836  DeepSeek Harness.exe
DESKTOP   --C-Users-USER-Desktop--\d111aa16-c91c-4ca1-8b48-2a525920ced3      35836  DeepSeek Harness.exe
DESKTOP   --C-Users-USER-Desktop--\f7cee991-06f8-4c27-8124-37e13afda88b      35836  DeepSeek Harness.exe
DESKTOP   --C-Users-USER-Desktop--\session-REDACTED-0b8729e7  35836  DeepSeek Harness.exe
DESKTOP   --C-Users-USER-Desktop--\session-3d69f569-861a-407f-9b86-a7c7843e4237  35836  DeepSeek Harness.exe
DESKTOP   --C-Users-USER-Desktop--\session-99b2eceb-4895-4adb-b852-a82f65539bcc  35836  DeepSeek Harness.exe

dead sessions: 17/26
any session.lock on disk: false
```

### 4.3 更轻量的两种等价探测（无需句柄表）

| 探测 | 调用 | 结论 | 代价 | 风险 |
|---|---|---|---|---|
| **A1 存在性探测**（推荐做 live 判定） | `OpenSemaphoreW(SEMAPHORE_QUERY_STATE=0x0001, FALSE, name)`；句柄非 0 ⇒ 存在 ⇒ 有人持有；随后 `CloseHandle` | 对象只在被持有时存在 ⇒ 精确 live/dead | 每会话 ~µs | **零风险**（纯读，不改变内核计数） |
| A2 非阻塞抢占试探 | `CreateSemaphoreW(null,1,1,name)` + `WaitForSingleObject(h,0)`：`WAIT_OBJECT_0(0)`=空闲（随后必须 `ReleaseSemaphore`+`Close`），`WAIT_TIMEOUT(258)`=被持有 | 同上，且能区分"存在但计数=1"这种边界 | 同上 | 极低：若在"释放句柄前"这一瞬间 DSH 恰好取锁，会给它一个 `SessionAlreadyOwnedError`。**生产环境请用 A1** |

本机自测（`selftest-lease.mjs`）：

```
live session      A(exists)= {"exists":true}    B(wait)= {"result":"held"}
dead session      A(exists)= {"exists":false,"err":2}  B(wait)= {"result":"free"}
[selftest] after create+wait   w= 0                  A(exists)= {"exists":true}
[selftest] after release+close                       A(exists)= {"exists":false,"err":2}   ← 对象随末句柄销毁
```

负对照错误码 = `2`（`ERROR_FILE_NOT_FOUND`）。

### 4.4 复刻 hash 的唯一要求

```js
import { createHash } from 'node:crypto'
import { join, resolve } from 'node:path'

const leaseName = (sessionDir) =>
  `Local\\dsh-session-lock-${createHash('sha256')
     .update(resolve(join(sessionDir, 'session.lock')).toLowerCase())
     .digest('hex')}`
// sessionDir 必须是 DSH 自己会得到的同一个绝对路径：
//   path.resolve(process.env.DSH_HOME ?? join(homedir(), '.dsh'), 'sessions', projectDir, sessionId)
```

DSH 侧等价的 `path` 来自 `dirname(<日志绝对路径>)`，所以只要 `DSH_HOME` 是同一个绝对路径、且路径中没有 junction/8.3 短名，hash 必然一致。**调试技巧**：若怀疑不匹配，用 §4.1 第 4 步枚举所有 `dsh-session-lock-*` 名字与本地算出的 hash 做 diff。

---

## 5. Q4 子 agent 会话

### 5.1 子会话是怎么来的

- 子会话是**独立会话**（独立 `<uuid>` 目录、独立 header、独立日志、独立 projcache），由 `dsh-subagent*` 在同一进程内创建。
- 父会话的日志里会记 `subagent/catalog`（子 id + 创建时间 + label + mode）。
- 子会话第一条事件是 `subagent/descriptor`（`seq: 0`），随后是继承来的 `sandbox/mode` / `approval/policy` / `permission/preset`（`source:"delegation"`），然后 `agent/inbox/spliced` 注入子任务。

### 5.2 实测样本：子会话 header（`sessions\--C-Users-USER-Desktop--\5a41c432-…\session.v4.jsonl.zstd`）

```json
{"type":"session","version":4,"id":"5a41c432-a846-4be1-a096-4dcb6ad75748",
 "createdAt":1792334983326,"cwd":"C:\\Users\\USER\\Desktop",
 "parentSession":"session-REDACTED-0b8729e7",
 "isSeeded":false,"origin":"subagent","delegationDepth":1,"agentPreset":"standard"}
{"type":"subagent/descriptor","seq":0,"time":1792334983327,"data":{
  "version":3,"mode":"continuable","provider":"spawn",
  "label":"Reverse-engineer DSH Windows session liveness/ownership semantics from shipped app.asar and local stores",
  "agentProvider":"deepseek-account","agentModel":"deepseek-flash","agentReasoningEffort":"high"}}
```

父日志里的登记事件（`session-REDACTED…` 的 v4 日志，`seq` 递增）：

```json
{"type":"subagent/catalog","seq":201,"time":1792334983351,"data":{
  "version":0,"childId":"5a41c432-a846-4be1-a096-4dcb6ad75748","childCreatedAt":1792334983326,
  "mode":"continuable","label":"Reverse-engineer DSH Windows session liveness/ownership semantics ..."}}
```

旧格式（v0）的子会话 header 同样字段：`origin:"subagent"`、`delegationDepth:1`、`parentSession:"session-<parent>"`，另有 `agentPreset:"standard"`。

### 5.3 子会话落在哪

**同一个 projectDir**（由 `cwd` 决定；子会话继承父会话的 cwd）。本机实例：

```
sessions\--C-Users-USER-Desktop--\session-REDACTED-…    ← 根
sessions\--C-Users-USER-Desktop--\5a41c432-…            ← 子
sessions\--C-Users-USER-Desktop--\f7cee991-…            ← 子
sessions\--C-Users-USER-Desktop--\07a0fa8c-…            ← 子
sessions\--C-Users-USER-Desktop--\d111aa16-…            ← 子
sessions\--C-Users-USER-Desktop--\497c63a5-…            ← 子
sessions\--C-Users-USER-Desktop--\02c52557-…            ← 子
```

目录名 = 会话 id 原文。**观察到的 id 有两种命名族**：UI 新建的根会话是 `session-<uuid>`，子会话是裸 `<uuid>`（推测由 `randomUUID()` 直接 mint）。⇒ daemon **不得**假设 id 前缀；`shortId` 取前 8 位时对两者都成立。

### 5.4 相关投影行

```
subagentTiming  {"ver":3,"seq":261,"val":{"descriptorSeen":true,"settledMs":0,"active":{"since":1792334983349,"through":1792335213920}}}
subagent        {"ver":2,"seq":261,"val":{"identity":{"mode":"continuable","label":"…","seq":0}}}
agentTeam       {"ver":4,"seq":261,"val":{"id":"5a41c432-…","members":[],"tasks":[],…}}
```

`subagentTiming.active` 看起来像"子 agent 运行区间"，但它是**投影**（提交驱动），**不能当实时心跳**（同 §2.3）。

---

## 6. Q5 事件与 token

### 6.1 权威事件类型清单（已安装版 `KNOWN_SESSION_EVENT_TYPES`）

从 asar 抽取（`dsh-session` 包内的持久化校验白名单，共 62 项）：

```
agent-preset/selected, agent/inbox/spliced, approval/asked, approval/decided, approval/policy,
assistant/attempt, assistant/message, command/done, command/run,
compaction/end, compaction/prune, compaction/start, compaction/summary,
deliverables/presented, developer/message,
feedback/message-delete, feedback/message-put, feedback/record,
goal/change, hook/invoked, hook/result, image/offload,
job/registered, job/settled, llm/retry, llm/retry-started, model/selection,
permission/preset, plan/mode, request/context, request/header, sandbox/mode,
schedule/change, session-log-deepseek/delivery-accepted, session/end-seed, session/title,
session/title-llm-request, step/end, step/start, subagent/catalog, subagent/descriptor,
subagent/model-selection-policy, system/message, team/member, team/message/delivered,
team/message/queued, team/task, todo/write,
tool-workflow/agent-end, tool-workflow/agent-start, tool-workflow/run-end, tool-workflow/run-start,
tool/call, tool/ptc-dispatch, tool/ptc-dispatch-start, tool/result,
turn/end, turn/start, user/message, web/deepseek-search-llm-request,
working-directory/change, workspace/changes
```

> 注意：清单里**没有** `assistant/chunk` / `reasoning-chunks` / `text-chunks` / `tool-call-chunks`。
> 这些只出现在 **v0 老日志**（本机 2026-08 的会话），v4 之后流式内容改由 `assistant/message.data.stream` + 提交后的完整 `message` 承载。

### 6.2 实测频次（本机 14 个 v4 日志；采样时点 2026-10-18 23:0x，会话在持续写入，绝对数会漂移、比例稳定）

```
629 tool/call                510 step/start              505 session-log-deepseek/delivery-accepted
627 tool/result              504 step/end                494 assistant/message
303 job/registered           301 job/settled              71 user/message
 66 agent/inbox/spliced       22 web/…-llm-request         21 turn/start
 20 session/title            17 sandbox/mode               17 approval/policy
 17 permission/preset        15 turn/end                   14 session
 13 system/message           13 request/header             12 request/context
 12 team/member              12 assistant/attempt           7 session/title-llm-request
  6 subagent/descriptor       6 subagent/catalog            5 todo/write
  3 command/run               3 command/done                2 session/end-seed
  2 model/selection           1 working-directory/change    1 developer/message
  1 goal/change               1 approval/asked               1 approval/decided
```

**事件信封**（v4）：`{type, seq, time, data, surfaceOp?, sourceEventSeqs?, seq0?, time0?}`；header 行是 `{type:"session", version:4, id, createdAt, cwd, isSeeded, delegationDepth, agentPreset, parentSession?, origin?}`。

### 6.3 `assistant/message` 的 usage 字段（实测）

v4：

```json
{"type":"assistant/message","seq":27,"time":…,"data":{
  "turn":1,"step":1,"message":{...},"stream":[...],
  "usage":{"inputTokens":11148,"outputTokens":246,"cacheReadTokens":0,"cacheWriteTokens":0,"totalTokens":11394}}}
```

- **v4 键**：`inputTokens, outputTokens, cacheReadTokens, cacheWriteTokens, totalTokens`
- **v0（旧）键**：`inputTokens, outputTokens, cacheReadTokens, reasoningTokens`（**无** `totalTokens`、**无** `cacheWriteTokens`）
- 两代并集：`inputTokens, outputTokens, cacheReadTokens, cacheWriteTokens, totalTokens, reasoningTokens`

⇒ `daemon.mjs` 现有 `addTokens()` 的字段名**完全正确**；`total = Number(usage.totalTokens) || input+output+cacheRead+cacheWrite` 的回退在 v0 上也成立。

`projcache` 里的聚合口径不同，别混用：`tokenUsage.val.totals = {uncachedInputTokens, outputTokens, cacheReadTokens, cacheWriteTokens}`。

### 6.4 `turn/start` / `turn/end`

```json
{"type":"turn/start","seq":10,"time":1792334737791,"data":{"turn":1}}
{"type":"turn/end","seq":73,"time":1792334757662,"data":{"turn":1,"reason":{"kind":"completed"}}}
{"type":"turn/end","seq":…,"time":…,"data":{"turn":2,"reason":{"kind":"error","error":{
   "message":"Content Exists Risk (request_id: …)","code":"INVALID_REQUEST","status":400}}}}
```

- `turn/start.data` 只有 `turn`。
- `turn/end.data` = `{turn, reason}`；`reason.kind` 实测有 `completed`（15 次）与 `error`（12 次，`error:{message,code,status}`）。
- `daemon.mjs` 的 `active = lastStart && (无 lastEnd || lastEnd.time < lastStart.time)` 逻辑**可直接复用**。

### 6.5 `session/title` 的触发时机（实测时间线）

同一个 desktop 会话（`session-REDACTED…`）：

```
seq 15  t=1792334737810  user/message  (approval policy 变更通知)
seq 16  t=1792334737811  user/message  "<first real user prompt>"     ← 第一条真实用户输入
seq 22  t=1792334737815  session/title {"title":"<session title (fallback)>","messageSeqs":[16],"source":{"kind":"fallback"}}   ← +4 ms
seq 26  t=1792334738508  session/title {"title":"查找GitHub最新推送项目","messageSeqs":[16],"source":{"kind":"provider","provider":"session-title-first-prompt-llm","model":{"provider":"deepseek-account","model":"deepseek-flash"}}}  ← +693 ms
seq 86  t=1792334885442  session/title {"title":"<session title (llm)>","messageSeqs":[16,79],"source":{"kind":"provider","provider":"session-title-all-prompts-llm",…}}  ← 第二轮的再总结
```

⇒ 顺序恒为 **fallback（确定性截断首条 prompt）→ provider（LLM）→ 后续轮再润色**。`data` 结构：

```json
{"title":"…","messageSeqs":[16],"source":{"kind":"fallback"}}
{"title":"…","messageSeqs":[16],"source":{"kind":"provider","provider":"…","model":{…}}}
```

对气泡的实际意义：`session/title` 一定在 turn 1 前几个事件内出现，**不需要等轮次结束**；`fallback` 版本约等于"首条 prompt 前 8 词/96 字节"。另：ACP profile 显式 `- id: session-title-llm / disabled: true`（`dsh-acp-app/cordis.patch.yml`）⇒ **ACP 会话永远只有 fallback 标题，没有任何 provider 标题**（可作 ACP 的辅助指纹）。

### 6.6 ⚠️ 日志解码：多帧 zstd（移植必踩坑）

DSH 每次追加写**一个独立的 zstd frame**（本机 159,089 B 的文件里有 **119 个 frame**、198 行 JSON）。

```js
// Node 24 内置，但只解第一帧：
zlib.zstdDecompressSync(buf)  → 278 B / 1 行      ← 灾难性静默截断
// 必须逐帧解压（共 648,804 B / 198 行）：
```

可用的纯内置实现（本机验证，见附录 A `zstd-multiframe.mjs`）：按 zstd 帧结构（magic `28 b5 2f fd` → Frame_Header_Descriptor → Window/DictID/ContentSize → blocks，直到 last_block）算出一帧的结尾，对每帧单独 `zstdDecompressSync`，再拼接；遇到非 magic 字节逐字节重同步。

```js
const MAGIC = 0xfd2fb528
function frameEnd(buf, start) {
  let p = start + 4
  const fhd = buf[p++]
  const fcsFlag = fhd >> 6, single = (fhd >> 5) & 1, cks = (fhd >> 2) & 1, dict = fhd & 3
  if (!single) p += 1
  p += [0, 1, 2, 4][dict]
  p += fcsFlag === 0 ? (single ? 1 : 0) : fcsFlag === 1 ? 2 : fcsFlag === 2 ? 4 : 8
  for (;;) {
    const h = buf[p] | (buf[p + 1] << 8) | (buf[p + 2] << 16); p += 3
    const last = h & 1, type = (h >> 1) & 3, size = h >> 3
    p += type === 0 ? size : type === 1 ? 1 : size          // Raw / RLE / Compressed
    if (last) break
  }
  if (cks) p += 4
  return p
}
export function decodeLog(buf) {
  const parts = []; let pos = 0, frames = 0
  while (pos + 4 <= buf.length) {
    if (buf.readUInt32LE(pos) !== MAGIC) { pos += 1; continue }  // 尾部 padding/截断修复
    const end = frameEnd(buf, pos)
    parts.push(zlib.zstdDecompressSync(buf.subarray(pos, end)))
    frames += 1; pos = end
  }
  return { text: Buffer.concat(parts).toString('utf8'), frames }
}
```

（mac 版用 `zstd -d -c` CLI，天然支持多帧；Windows 上没有 `zstd` CLI，必须自己解。）

---

## 7. Q6 进程 → 会话映射

### 7.1 CLI 的 argv 契约

`dsh` 启动器（已安装版在 asar `/dsh/node_modules/@deepseek-ai/dsh/lib/bin.js`，启动器+profile-boot 已打包进去；源码 checkout 对应 `apps/cli/src/args.ts`）只解析**自己的**标志，其余原样透传给被启动 profile 的 app：

```
dsh --profile <name> [--patch <yml>]... [--from-default-profile <name>] [ <app args...> ]
dsh web [app args...]                       # 等价 --profile web
dsh --profile desktop                       # 被显式拒绝："profile "desktop" is managed exclusively by the Electron application"
```

`--profile` 之后的第一个不认识的 token 开始属于 app。各 app 自己的标志（来自各 bundle README）：

| profile | 组合 | app 标志 |
|---|---|---|
| `acp` | base + acp-app | 无（ACP JSON-RPC over stdio） |
| `headless` | base + headless | 任务位置参数、`--session-id <id>`、`--json`、`--help` |
| `web` | base + web-app | `--host --port --tls-cert --tls-key --public-url --trusted-host --no-open` |
| `desktop` | base + web-app + desktop 补丁 | 由 Electron 传（`runtimeDir`、`projectDir`…），用户不可用 |

⇒ **命令行里能拿到 profile，但拿不到"新会话 id"**（`--session-id` 只用于*续跑*已有会话）。

### 7.2 会话 cwd 从哪来

- headless：`cwd` 用已挂载 `fs` 提供方解析（无 fs 服务时用**进程 cwd**），并写入新会话 header；`--session-id` 续跑会校验 cwd 一致。
- acp：cwd 由 ACP 客户端在 `session/new` 参数里给出（绝对路径，组合前校验），**可以与进程 cwd 不同**。
- web/desktop：用户在 UI 里选/建 workspace，会话 `cwd` 来自 workspace 或创建参数。

### 7.3 结论：能不能只靠 cwd + 最近写入？

**不能稳定映射**，理由：

1. 新会话的 id 不在 argv 里（只有 `--session-id` 续跑时才有）。
2. ACP 的会话 cwd 由 client 给，与进程 cwd 无必然关系；同一 ACP 进程可连续创建多个不同 cwd 的会话。
3. headless 是一进程一会话且立刻退出 —— 可以用"进程启动时间 ≈ 会话 createdAt + cwd 相同"配对，但**一个会话也可能被多次 headless 续跑**。
4. web `--port` 能对上 `app:web-surface` 的端口，但只适用于 web/desktop，且要读端口表。

可行的近似（若拿不到租约持有者 PID 时的降级）：

- 候选进程 = 进程表中 `CommandLine` 含 `--profile acp|headless` 或 `\@deepseek-ai\dsh\lib\bin.js` 的进程；
- 对每个「外部 live 会话」，用 `header.createdAt` 与进程 `CreationDate` 的差（±2 s）配对；
- 唯一配对成功才采信，否则 `sourceConfidence:"unknown"`。

**精确答案**：§4 的 holder PID 直接给出「会话 → 进程」，再沿 `ParentProcessId` 走链 ⇒ 同时解决"是否桌面"和"哪个 agent 启动"（codex / claude / cursor / terminal）。

---

## 8. 推荐算法（按可靠性排序）

### T1（推荐主链路）租约持有者 PID + 进程表

| 项 | 值 |
|---|---|
| 能回答 | `live`（精确）、`desktop`（精确）、`source`（父链）、`pid` |
| 可靠性 | **高**（内核级，与 mac 的 `flock`+`lsof` 语义等价） |
| 延迟 | 句柄表扫描 67 ms + 进程表 455 ms（缓存 5 s）；可按需只用存在性探测 ~1 ms/会话 |
| 实现成本 | 中：需要 FFI。推荐 `koffi`（DSH 自带：`%DSH_HOME%\profiles\node_modules\koffi`，安装时复制或运行时解析）；否则用 PowerShell `Add-Type` 编译同一段 C#（成本高、启动慢 ~0.5–1 s） |
| 失败模式 | EDR 拦截 `NtQuerySystemInformation`/`OpenProcess`；守护进程跑在不同登录会话 ⇒ 看不到 `Local\` 对象；非 Windows |
| 降级 | 返回 `null`（"不可用"），落到 T2/T3 |

### T2 存在性探测（只要 live/dead，不要 holder）

`OpenSemaphoreW` 探测每个候选会话。同样精确，但拿不到 PID ⇒ 只能用 T3 判断 desktop。
成本：1 次 PowerShell `Add-Type` 或 1 次 koffi 调用；每会话 µs。

### T3 GUI 表面启发式（只判"GUI vs 非 GUI"）

`app:web-surface` 存在（+ 端口归属）⇒ 桌面/网页；不存在 ⇒ acp/headless。
可靠性中高；对"桌面会话后来被 CLI 续跑"会误判（见 §10）。
`workspace.json` 成员可作补充（只覆盖根会话）。

### T4 mtime / sidecar 启发式（现有 PORT-WINDOWS 草案）

`mtime` 窗口 + 显式 sidecar。可靠性低（无法区分"活着但空闲"与"已死"），但零成本、零依赖。**建议只作为最终降级**。

### 排序结论

```
live      : T1 ≫ T2 ≫ T4
desktop   : T1 ≫ T3 ≫ (T4 不适用)
source    : T1（父链）> sidecar 显式声明 > 名称猜测
```

---

## 9. 给 daemon 移植者的接口建议

### 9.1 `src/win/liveness.mjs`（替换 `lockHolders()`）

mac 语义保持不变，win32 分支**不让调用方感知差异**：

```js
/** 一个会话目录的租约持有者。null = 探测不可用；[] = 无人持有（已死）。 */
export async function leaseHolders(sessionDir)          // → number[] | null
/** 批量：一次句柄表扫描得到全部活会话。null = 不可用。 */
export async function scanLeases(sessionDirs)           // → Map<sessionId, pid> | null
/** 单会话存在性探测（轻量，无需 holder）。null = 不可用。 */
export async function isLeaseHeld(sessionDir)           // → boolean | null
/** 仅供诊断/测试：信号量名。 */
export function leaseName(sessionDir)                   // → 'Local\\dsh-session-lock-<64 hex>'
```

实现要点（详见附录 A `win-lease-attribution.mjs`）：

1. **不要** `stat(join(sessionDir,'session.lock'))` —— 该文件永不存在。
2. `leaseName()` 用 `path.resolve(join(sessionDir,'session.lock')).toLowerCase()` 做 sha256。
3. `scanLeases()` 一次 `NtQuerySystemInformation(64)`（缓冲按 `STATUS_INFO_LENGTH_MISMATCH(0xC0000004)` 增长），先用自建命名信号量反查 Semaphore 的 `ObjectTypeIndex`（+30），再对每个信号量句柄 `OpenProcess(PROCESS_DUP_HANDLE)+DuplicateHandle+NtQueryObject` 取名。
4. 全部探测**只读**：绝不 `CreateSemaphoreW`+`Wait`（除非用 A2，且必须立刻 `Release`+`Close`）。
5. 进程表只查一次/刷新，缓存 3–5 s；`desktopHostPids()` = `CommandLine` 匹配 `/dsh-desktop-host[\\/]lib[\\/]index\.js/i`。
6. 任何一步失败 → 返回 `null`，让上层降级；**不要把 `null` 当 `[]`**（`[]` 会误杀所有会话）。

`daemon.mjs` 里现有的这几行**可以原样保留**：

```js
const holders = await lockHolders(lockPath)        // win32: leaseHolders(entry.dir)
if (holders && holders.length === 0) continue      // 无人持有 = 死
if (holders && holders.some((pid) => desktops.has(pid))) continue  // 桌面 App 的会话
...
const inferred = !explicitSourceValue(sidecar) && holders?.length ? await inferSource(holders[0]) : null
```

唯一要改的是把 `lockPath` 参数换成 `entry.dir`（或让 `lockHolders(dir, platform)` 内部自己拼路径）。

### 9.2 `src/win/process-table.mjs`（替换 `ps`）

mac 的 `ps -axo pid=,command=` / `ps -o ppid=,comm=` 在 Windows 上换成**一次** CIM 查询：

```js
/** → Map<pid, { ppid, name, cmdline, startTime }> | null ；缓存 5 s */
export async function processTable()
/** 桌面宿主 PID 集合；null = 不可用 */
export async function desktopHostPids()
/** 从 holder PID 沿 ppid 走链推断 source（codex/claude-code/cursor/terminal/unknown） */
export async function inferSource(pid)
```

实测成本：一次 `Get-CimInstance Win32_Process | Select ProcessId,ParentProcessId,Name,CommandLine,CreationDate`
= **367 行 / 455 ms**（全量）；带 `-Filter` 的窄查询 421 ms。`netstat -ano -p TCP` = **19 ms**（端口归属用它）。

`sourceFromCommand()` 必须改成**匹配 `CommandLine` 而不只是 image 名**，因为 Windows 上一切皆 `node.exe`：

```js
function sourceFromCommand(cmdline, imageName) {
  const v = `${imageName} ${cmdline}`.toLowerCase()
  if (/codex|chatgpt/.test(v)) return { source: 'codex', sourceLabel: 'Codex' }
  if (/claude/.test(v))        return { source: 'claude-code', sourceLabel: 'Claude Code' }
  if (/cursor/.test(v))        return { source: 'cursor', sourceLabel: 'Cursor' }
  if (/dsh-chat/.test(v))      return { source: 'dsh-chat', sourceLabel: 'DSH Chat' }
  if (/pwsh|powershell|cmd\.exe|windowsterminal|conhost|wt\.exe|bash\.exe|wsl/.test(v))
    return { source: 'terminal', sourceLabel: 'Terminal' }
  return null
}
```

已知本机真实形态（供匹配规则参考）：

```
node.exe  "...\npm\bin\npx-cli.js" "shadcn@latest" mcp
node.exe  "...\Cursor\User\globalStorage\anysphere.cursor-agent-worker\...\index.js" --api-key ...
node.exe  "node" "...\chrome-devtools-mcp.js" ...
DeepSeek Harness.exe --expose-internals "...dsh-desktop-host\lib\index.js" ...
DeepSeek Harness.exe "...dsh-subprocess-local\lib\runner.js" -- pwsh.exe ...
```

> ⚠️ **别把 `dsh-desktop-host\lib\cli.js` 当成"外部 CLI"**：它只是桌面运行时里 `dsh` 命令行的包装入口（`import { runCli } from "@deepseek-ai/dsh/lib/bin.js"`，用于 App 自己执行 profile/plugin 操作），不是 ACP/headless 进程。识别外部 CLI 用
> `--profile\s+(acp|headless|sdk|web)` 或 `@deepseek-ai[\\/]dsh[\\/]lib[\\/]bin\.js`。

### 9.3 `src/win/zstd.mjs`（替换 `zstd` CLI）

```js
/** 多帧解码；失败抛错由上层保留旧缓存。 */
export function decodeSessionLog(buffer)   // → { text, frames }
```

⚠️ 严禁只用 `zlib.zstdDecompressSync(buffer)`（只解第一帧，会静默丢 99% 内容）。

### 9.4 建议 `daemon.json` 增字段（便于诊断，不破坏 `status.json` v2）

```json
{ "platform": "win32", "mode": "lease+handle-table", "leaseProbe": "ok|unavailable", "sourceProbe": "cim|sidecar|none" }
```

### 9.5 性能预算（实测）

| 操作 | 本机耗时 | 建议频率 |
|---|---|---|
| 句柄表扫描（200 k 句柄 / 9.4 k 信号量） | 67 ms | 每 tick（1.5 s）或 1 s 缓存 |
| 单会话存在性探测 | < 1 ms | 需要时 |
| CIM 全量进程表（367 行） | 455 ms | 缓存 5 s（与现有 `desktopPidsCache` 一致） |
| `netstat -ano -p TCP` | 19 ms | 需要端口归属时，缓存 5 s |
| 多帧解压（159 KB → 648 KB） | < 10 ms | 仅 `size:mtime` 变化时（现有逻辑） |

### 9.6 对 `docs/PORT-WINDOWS.md` 的具体修订（该文 §4 已声明"以本文为准"）

1. **§2 技术选型**：「Node 24 内置 `zlib.zstdDecompressSync`」→ 改为「内置 zlib + 自写多帧解帧器」（否则只读第一行）。
2. **§4 判定算法 2（live）**：把 `mtime` 窗口降级为 T4 兜底；主路径改为 `leaseHolders()/scanLeases()`：
   - `null` → 降级到 mtime/sidecar；
   - `[]` → **已死，直接跳过**（不需要再判 `openTurn`）；
   - 非空 → live，并进入桌面归属判定。
3. **§4 判定算法 3（desktop）**：改为「holder PID ∈ desktopHostPids」；把"保守跳过歧义会话"降级为 T1 不可用时的兜底。
4. **§4 判定算法 4（source）**：改为「holder PID 沿 ppid 走链」，匹配 `CommandLine`（见 9.2）；`commod` 匹配规则里 `pwsh/powershell/cmd/WindowsTerminal/conhost` 已正确，补充 `wt.exe`、`wsl.exe`。
5. **§4 性能约束**：沿用"1 次进程表 + N 次 stat"；新增"1 次句柄表扫描/refresh"。
6. **§10 已知差异**：「会话活跃性为启发式（无锁）」→ 改为「Windows 上存在内核级会话租约，可精确判定；仅当 FFI 不可用时退化为启发式」。

---

## 10. 已知不确定项与后续验证方法

| # | 不确定项 | 当前证据 | 验证方法 |
|---|---|---|---|
| 1 | **外部（acp/headless）进程是否也持有租约** —— 未在本机端到端实测（本机只跑桌面 App）。代码路径完全相同（`openWrite` → `SessionWriteLease.acquire`，无表层分支），置信中高 | 源码 + mac 等价行为 + 9/9 桌面实测 | 跑一次 `pnpm dsh --profile headless "say ok"`，运行期间用 `win-lease-attribution.mjs` 看该会话 holder 是否 = headless 的 node PID |
| 2 | 桌面 App **关闭标签页**后是否释放租约（"空会话也 LIVE"已实测 ⇒ 至少"打开即持锁"成立） | 9 个活会话全部 35836，含 0 轮空会话 `session-3d69f569` | 在 App 里关一个会话/关整个 App，重跑探测看该会话是否转 dead |
| 3 | 端口归属方案（`app:web-surface` → 端口 → PID）在 `dsh web` 场景的准确率 | 只有代码与历史端口证据（3091/3080/19387/25318） | 起一个 `dsh web --port 8099`，看新会话的 section URL 是否 8099、端口是否由该 node 进程持有 |
| 4 | **路径 hash 的脆弱点**：`.dsh` 若为 junction/symlink、或 DSH_HOME 写成 8.3 短名 ⇒ hash 不一致、探测永远"dead" | 未复现（本机 DSH_HOME 是普通目录） | 故意用 `subst`/junction 指一份 DSH_HOME 起一次会话；或枚举系统内 `dsh-session-lock-*` 名字与本地 hash 做 diff |
| 5 | `Local\` 命名空间跨登录会话不可见 | README 明确「按登录会话隔离」；任务计划程序若非"仅在用户登录时运行"，守护进程会落在 Session 0 | 计划任务改为"用户登录时运行"；或用一项自检：已知活会话探测为 false 时报告 `leaseProbe:"unavailable"` |
| 6 | EDR/杀软拦截 `NtQuerySystemInformation`、`OpenProcess(PROCESS_DUP_HANDLE)` | 本机未拦截（67 ms 内完成 9.4 k 次 `OpenProcess`+`DuplicateHandle`+`NtQueryObject`） | 在装有 Defender ASR/企业 EDR 的机器上跑同一脚本；捕获 `error code 5/87` 即降级 |
| 7 | `NtQueryObject` 在非信号量句柄上可能挂起（本方案已按类型索引过滤，只查 Semaphore） | 代码保证 | 若将来放宽过滤，必须保留类型索引检查 |
| 8 | `ObjectTypeIndex`（对象类型索引）随系统/驱动差异 —— 用「自建信号量反查」解决，不要硬编码 24 | 本机 Semaphore 索引 = 24 | 换机器跑 `selftest-lease.mjs` 打印索引 |
| 9 | 桌面宿主是否"总是"启动 web-app 组合（决定 `app:web-surface` 是否恒存在） | `dsh-desktop-host` 注释："Launch the Desktop profile through the Web application and report its URL to Electron" + 实测 section 存在 | 换版本升级后抽查一次日志 |
| 10 | `subagent/catalog` 的 `version`/`mode` 枚举值 | 仅见 `version:0`、`mode:"continuable"` | 跑 `mode:"spawn"`/`fork` 的子 agent 对比 |
| 11 | v0 老日志里 `assistant/chunk` 等流式事件 | 只在 2026-08 的会话里出现 | 无需处理（header.version 区分；v4 无这些类型） |
| 12 | 外部启动器在**打包运行时**上的真实命令行形态（本机没有跑过外部 ACP/headless） | 打包运行时在 `app.asar` 内，普通 node 读不了；桌面 App 的子进程用 `DeepSeek Harness.exe <script.js>` 当 node 用（已实测于 `dsh-subprocess-local\lib\runner.js`） | 用真实外部客户端跑一次，`Get-CimInstance Win32_Process` 抓它的 CommandLine，据此定 `EXTERNAL_PROFILE_PATTERN` |

---

## 附录 A：复现命令与脚本

脚本都在 `%TEMP%\dsh-asar\`（不污染仓库）。它们依赖：
- Node 24（`zlib.zstdDecompressSync`、`fs`）
- koffi：`C:\Users\USER\.dsh\profiles\node_modules\koffi`（DSH 自带）
- asar 读取：纯 Node 解析 JSON 头（不整包解压）

```powershell
cd $env:TEMP\dsh-asar

# 0) 安装版 DSH 版本（读 app.asar 内 /dsh/package.json）
node asar.mjs version                       # → 0.2.1-rc.2
#    列出 asar 内某目录
node asar.mjs list "dsh-session-persistence-jsonl"
#    抽取单文件（按需，不整包解包）
node asar.mjs extract "/dsh/node_modules/@deepseek-ai/dsh-session-persistence-jsonl/lib/index.js" persistence-index.js
#    在 asar 原始字节里搜字符串并打印上下文
node asar.mjs search "session.lock" 200 12  # → 4 处，含命名信号量注释与 LEASE_FILENAME

# 1) 会话锁存活探测（存在性；O(会话数) 次内核调用）
node probe-lock.mjs                         # 打印 LIVE/dead 列表 + 负对照 {"exists":false,"err":2}
# 2) 两种探测方式 + 内核对象生命周期自测
node selftest-lease.mjs
# 3) 精确归因：会话 → 持有者 PID → 是否桌面宿主
node win-lease-attribution.mjs
# 4) 多帧 zstd 解码 + 事件清单
node inventory.mjs
node scan-surface.mjs                        # 每个日志里的 GUI 表面 URL
# 5) 文件共享/独占语义（证明 DSH 不留长句柄）
node probe-share.mjs
# 6) 进程/端口/进程表成本
node probe-portability.mjs

# 7) 手工确认桌面宿主与端口
Get-CimInstance Win32_Process |
  ? { $_.CommandLine -match 'dsh-desktop-host' } |
  select ProcessId,ParentProcessId,Name,CommandLine | fl
Get-NetTCPConnection -State Listen | ? OwningProcess -eq 35836 | select LocalAddress,LocalPort
```

脚本清单与用途：

| 脚本 | 用途 | 关键输出 |
|---|---|---|
| `asar.mjs` | asar 头解析 / list / extract / 字节级 search | `version` → 0.2.1-rc.2 |
| `zstd-multiframe.mjs` | 多帧 zstd 解码（库） | 159 KB → 119 帧 → 648,804 B |
| `probe-lock.mjs` | 存在性探测全部会话 | `LIVE 9 / 26`，负对照 `err:2` |
| `selftest-lease.mjs` | A/B 两种探测 + 对象生命周期 | live: exists/held；dead: absent/free；释放后消失 |
| `win-lease-attribution.mjs` | **参考实现**：会话→holder PID→desktop | 9 个会话全部 holder=35836，扫描 67 ms |
| `inventory.mjs` | v4 事件清单、usage 键、turn 结构、projcache 对比 | 见 §6.2/6.3 |
| `scan-surface.mjs` | `app:web-surface` / 旧 prose URL | 25318 / 19387 / 3091 / 3080 |
| `probe-share.mjs` | `CreateFileW(dwShareMode=0)` 独占打开 | 全部 SHAREABLE ⇒ 无长句柄 |
| `probe-portability.mjs` | lockfile / CIM 成本 / netstat 成本 | 455 ms / 19 ms |

---

## 附录 B：关键路径与事实速查

```
DSH_HOME                        C:\Users\USER\.dsh
会话库                          %DSH_HOME%\sessions\<projectDir>\<sessionId>\session.v4.jsonl.zstd
projectDir 编码                  绝对 cwd 把 \ 和 : 换成 '-'，前后加 '--'
                                例：C:\Users\USER\Desktop → --C-Users-USER-Desktop--
会话 id                          不透明字符串；根会话 session-<uuid>，子会话裸 <uuid>
租约（Windows）                  Local\dsh-session-lock-<sha256(lower(resolve(<sessionDir>\session.lock)))>
租约（POSIX）                    <sessionDir>/session.lock + flock（文件永久保留）
投影缓存                        %DSH_HOME%\storages\session_projcache\sessions\<id>.json（version 7, record.identity/rows）
工作区注册表                    %DSH_HOME%\storages\workspace.json（web-app 层写）
桌面 App 用户数据               %APPDATA%\@deepseek-ai\dsh-desktop\
桌面宿主命令行                  "<exe>" --expose-internals "...app.asar\dsh\node_modules\@deepseek-ai\dsh-desktop-host\lib\index.js" <runtime> <profile> <source> <pnpm> <bin>
桌面宿主监听                    127.0.0.1:25318（GUI，需 token）、127.0.0.1:9230
asar 内关键包                   @deepseek-ai/dsh-session-persistence-jsonl  (lease/win32/format)
                                @deepseek-ai/dsh-harness-dev-context         (app:web-surface)
                                @deepseek-ai/dsh-web-app/cordis.patch.yml    (挂 webserver/workspace/harness-dev-context)
                                @deepseek-ai/dsh-acp-app/cordis.patch.yml    (base+acp，禁用 session-title-llm)
                                @deepseek-ai/dsh-desktop-host/lib/index.js   (runProfile({profile:'desktop'}))
```

---

## 附录 C：与「已确认本机事实」的差异更正

| 既有说法 | 实测/源码结论 |
|---|---|
| 「本机不存在任何 `session.lock` 文件」 | ✅ 正确，**并且原因是设计如此**：Windows 用命名内核信号量，零文件系统足迹。不要再用文件存在性判活 |
| 「活跃会话的 zstd 日志可用 `FileShare.None` 独占打开 ⇒ DSH 不做跨进程文件锁」 | ✅ 文件层面正确（实测 `CreateFileW(share=0)` 对日志、projcache、workspace.json、Electron lockfile **全部成功**）；但**"不做锁"的推论错了**：锁在**内核命名对象**里，不在文件上 |
| 「Node 24 原生 `zlib.zstdDecompressSync` 可解日志」 | ⚠️ **只能解第一帧**。必须逐帧解（否则只拿到 header 一行，静默错） |
| 「桌面宿主命令行含 `dsh-desktop-host/lib/index.js`（反斜杠路径）」 | ✅ 正确；再补两点：进程镜像名是 `DeepSeek Harness.exe`（不是 node）；其子进程 `dsh-subprocess-local\lib\runner.js` 同名但**不是**宿主 |
| 「子 agent 事件 `subagent/descriptor` / `subagent/timing`」 | ✅ 存在；`subagent/timing` 在**投影缓存**里（`rows.subagentTiming`），日志里叫 `subagent/catalog`（父侧）+ `subagent/descriptor`（子侧） |
