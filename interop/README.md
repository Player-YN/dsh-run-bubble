# dsh-acp-interop

Part of [dsh-run-bubble](../README.md). Optional; install it when you want
`--source` / `--title` sidecar metadata and a discoverable ACP client.

Make a local DeepSeek Harness agent discoverable and callable from another
coding agent in a terminal (macOS and Windows).

`dsh --profile acp --help` only prints one line. It does not describe the
protocol. This kit supplies the missing layer:

- `dsh-chat` — a tiny ACP client with self-describing `--help`.
- `SKILL.md` — a skill another agent can load to learn the commands.
- This README — the full raw ACP method table for implementers.

## Install

### macOS (original)

```sh
cd interop
./install.sh
```

This copies `dsh-chat.mjs` and `SKILL.md` to `~/.dsh/interop/` and creates
`~/.local/bin/dsh-chat`. If `~/.local/bin` is not on `PATH`, add it:

```sh
export PATH="$HOME/.local/bin:$PATH"
```

### Windows

```powershell
cd interop
pwsh -NoProfile -File .\install.ps1 -DryRun   # preview files and PATH diff
pwsh -NoProfile -File .\install.ps1           # install
```

Then **reopen your terminal** (a new process is required for a User PATH
change to be visible). The installer:

- copies `dsh-chat.mjs` and `SKILL.md` to `%USERPROFILE%\.dsh\interop`;
- writes a self-contained shim directory to
  `%LOCALAPPDATA%\dsh-run-bubble\bin`:
  `dsh-chat.cmd`, `dsh-chat.ps1`, and a `dsh-chat.mjs` copy;
- adds that directory to the **User** PATH (`HKCU`), idempotently and with
  de-duplication. The machine-wide PATH is never touched and no administrator
  rights are requested.

`-DryRun` prints the exact previous/new User PATH and writes nothing.
`-Uninstall` removes the shims and the bin directory from the User PATH (the
`~\.dsh\interop` copies are kept; add `-Purge` to remove them too).
`-NoPs1Shim` skips `dsh-chat.ps1` for machines whose PowerShell execution
policy blocks local scripts; `dsh-chat.cmd` keeps working.
`-NoPathUpdate` installs the files without editing PATH.

You can also run it straight from a checkout without installing:

```bat
node interop\dsh-chat.mjs --help
interop\dsh-chat.cmd --help
pwsh -NoProfile -File interop\dsh-chat.ps1 --help
```

## Use

### macOS / POSIX

```sh
dsh-chat --help
dsh-chat ask "Reply with exactly: HELLO"
SID=$(dsh-chat new --cwd .)
dsh-chat send --session "$SID" "Continue the task"
dsh-chat list
dsh-chat close --session "$SID"
```

### Windows — cmd.exe

```bat
dsh-chat ask --source codex --title "Auth refactor" "Reply with exactly: HELLO"
dsh-chat new --cwd .
dsh-chat send --session <id> "Continue the task"
dsh-chat close --session <id>
```

`dsh-chat.cmd` forwards all arguments verbatim and preserves the exit code
(`exit /b %ERRORLEVEL%`). It switches the console to UTF-8 (`chcp 65001`) for
the duration of the call and restores the previous code page, so Chinese titles
and prompts arrive intact on a GBK console.

### Windows — PowerShell

```powershell
dsh-chat ask --source codex --title "认证重构" "Reply with exactly: HELLO"
$sid = dsh-chat new --cwd .
pwsh -NoProfile -File "$env:USERPROFILE\.dsh\interop\dsh-chat.mjs" send --session $sid "继续任务"
```

`dsh-chat.ps1` emits UTF-8 (`[Console]::OutputEncoding`), supports pipelines
(`dsh-chat ... | ConvertFrom-Json`), forwards all remaining arguments, and
propagates the native exit code through `$LASTEXITCODE`.

Each command spawns `dsh --profile acp` (`dsh.cmd` on Windows, through
`cmd.exe /d /s /c` because a `.cmd` file is not a PE executable), performs the
ACP handshake, and exits. The session is persisted under `~/.dsh/sessions`;
`send` resumes it by id.

## Sidecar metadata

`dsh-chat --source codex --title "Auth refactor" ...` writes
`$DSH_HOME/run-bubble/sessions/<sessionId>.json`
(`%DSH_HOME%\run-bubble\sessions\<sessionId>.json` on Windows; default
`DSH_HOME` is `~/.dsh`, i.e. `%USERPROFILE%\.dsh`):

```json
{
  "sessionId": "sess_0b8729e7",
  "source": "codex",
  "sourceLabel": "Codex",
  "title": "Auth refactor",
  "task": "Use the bash tool to ...",
  "pid": 47232,
  "surface": "acp",
  "heartbeatAt": "2026-10-18T09:32:21.116Z",
  "updatedAt": "2026-10-18T09:32:21.116Z"
}
```

### Sidecar contract (shared with `daemon.mjs`)

| Field | Type | Writer | Meaning |
|---|---|---|---|
| `source` | string | required | Canonical launcher id (`codex`, `claude-code`, `cursor`, `dsh-chat`, `terminal`, …). Explicit source always beats process-chain inference. |
| `sourceLabel` | string | required | Display label used by the bubble chip (`Codex`, `Claude Code`, …). Optional; the daemon has a fallback label. |
| `title` | string | required | Short task title shown in the bubble root row. |
| `task` | string | required | First prompt / task preview line (may be empty for `new`). |
| `updatedAt` | ISO 8601 | required | Time of the last explicit metadata write. |
| `pid` | number | required | PID of the wrapper process that wrote the file. Windows liveness/ownership signal; may be stale after the process exits, so verify the process is alive before trusting it. |
| `surface` | enum | required | `acp`, `headless`, `sdk`, or `desktop`. `dsh-chat` declares `acp` (override with `--surface`/`DSH_RUN_BUBBLE_SURFACE`). The daemon trusts this for the desktop-ownership decision. |
| `heartbeatAt` | ISO 8601 | required | Last liveness refresh. The wrapper refreshes it every 15 s while a prompt is running (`--heartbeat <sec>`, `0` disables; `DSH_RUN_BUBBLE_HEARTBEAT` also works), so a long turn stays "live" without log mtime tricks. |
| `sessionId` | string | optional | DSH session id when known. `dsh-chat` always knows it, so it is always written; omit it rather than guessing. |

Rules for writers:

- Write **atomically**: unique `<file>.tmp-<pid>-<n>` then rename. A concurrent
  reader never sees partial JSON; concurrent writers cannot corrupt the file
  (last write wins, metadata is merged from the existing record first).
- `0600` on POSIX. Windows has no POSIX mode bits: the file inherits the
  user-profile ACL, which is already private to the user.
- Sidecar failures must never break the prompt: `dsh-chat` only warns on
  stderr and continues.
- Do not put secrets in a sidecar, and do not read credentials from the
  environment while producing one.

Rules for the daemon (Windows):

- `source`/`sourceLabel` are authoritative when present
  (`sourceConfidence: "explicit"`).
- `surface: "acp" | "headless" | "sdk"` means external; `"desktop"` means the
  in-app surface. Trust it before the process-chain fallback.
- Treat `pid` alive **and** a `heartbeatAt` inside the stale window as live
  evidence; a dead pid or an old heartbeat must not keep a session active.
  Keep `source`/`title` for attribution even when the heartbeat is stale.
- Read the file at any instant; atomic rename guarantees complete JSON.

For debugging, `dsh-chat --print-sidecar [ask|new|send] [options]` prints
exactly the JSON that would be written (and the target path on stderr) without
starting `dsh`:

```sh
dsh-chat --print-sidecar --source codex --title "Auth refactor" ask "hello"
# stdout: the sidecar JSON; stderr: dsh-chat: sidecar path: .../<id>.json
```

Without a sidecar, the bubble infers source from the holder's process chain and
uses the first real user prompt as the title. Windows has no `session.lock`
equivalent, so the sidecar is the reliable attribution signal there; the daemon
falls back to CIM process-chain inference and log mtime when it is absent.

## Platform notes

- Launcher discovery: `DSH_BIN`, then the platform defaults (macOS app bundle
  and Homebrew paths; Windows
  `%LOCALAPPDATA%\Programs\DeepSeek Harness\resources\runtime\cli\bin\dsh.cmd`),
  then `PATH`. Override with `DSH_BIN`.
- A `.cmd` launcher is started as
  `cmd.exe /d /s /c ""<dsh.cmd>" --profile acp"`. On shutdown `dsh-chat`
  ends stdin, waits 800 ms, then uses `taskkill /T /F` so the `cmd.exe` shell
  and the `dsh` child do not linger (a lingering tree would keep the bubble
  showing "running").
- Windows wrappers never run elevated and never read credential environment
  variables.

## Raw ACP reference

Transport: `dsh --profile acp`, newline-delimited JSON-RPC 2.0 over stdio.
stdout carries only protocol frames; logs go to stderr.

| Direction | Method | Params | Result / notifications |
|---|---|---|---|
| client→server | `initialize` | `{protocolVersion:1, clientCapabilities:{}}` | `{protocolVersion, agentInfo, agentCapabilities, authMethods}` |
| client→server | `session/new` | `{cwd, mcpServers:[]}` | `{sessionId, configOptions}` |
| client→server | `session/list` | `{}` | `{sessions:[{sessionId,cwd}]}` |
| client→server | `session/resume` | `{sessionId, cwd, mcpServers:[]}` | `{configOptions}` |
| client→server | `session/set_config_option` | `{sessionId, configId:"model", value:"[\"provider\",\"model\"]"}` | `{configOptions}` |
| client→server | `session/prompt` | `{sessionId, prompt:[{type:"text",text}]}` | `{stopReason}` |
| client→server | `session/close` | `{sessionId}` | `{}` |
| client→server | `session/cancel` | `{sessionId}` | `{}` |
| server→client | `session/update` | — | `{sessionId, update:{sessionUpdate,...}}` |
| server→client | `session/request_permission` | — | client answers allow/reject |

Common `session/update` values: `agent_message_chunk` (text in
`update.content.text`), `agent_thought_chunk`, `tool_call`,
`tool_call_update`, `plan`.

### Minimal client

```js
const p = spawn('dsh', ['--profile', 'acp'], { stdio: ['pipe', 'pipe', 'pipe'] })
const send = (id, method, params) => p.stdin.write(JSON.stringify({ jsonrpc: '2.0', id, method, params }) + '\n')
send(1, 'initialize', { protocolVersion: 1, clientCapabilities: {} })
send(2, 'session/new', { cwd: process.cwd(), mcpServers: [] })
// on the session/new response:
send(3, 'session/set_config_option', {
  sessionId, configId: 'model', value: JSON.stringify(['deepseek-account', 'deepseek-flash'])
})
send(4, 'session/prompt', { sessionId, prompt: [{ type: 'text', text: 'hello' }] })
// print update.content.text for agent_message_chunk until response id 4
```

On Windows use `dsh-chat.cmd`, or spawn the launcher through
`cmd.exe /d /s /c ""<path>\dsh.cmd" --profile acp"` — a plain
`spawn('...\\dsh.cmd', ...)` fails with `EINVAL` because `.cmd` is not an
executable image.

## Session ownership

Only one process can write a session. A session live in the DSH desktop app is
locked; `session/resume` returns `already owned by an active write handle`.
Close it in the app first. ACP `session/resume` accepts persisted, inactive
sessions only.

Windows has no `session.lock`/`lsof`; exclusivity is enforced by DSH itself, so
the same `already owned by an active write handle` error applies.

## References

- ACP specification: https://agentclientprotocol.com
- TypeScript ACP SDK: https://www.npmjs.com/package/@agentclientprotocol/sdk
- DSH ACP package: https://www.npmjs.com/package/@deepseek-ai/dsh-acp
- DSH SDK client: https://www.npmjs.com/package/@deepseek-ai/dsh-sdk-client
