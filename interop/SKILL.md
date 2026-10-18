---
name: dsh-acp
description: Talk to a local DeepSeek Harness agent over ACP. Use when you need to start or continue a DSH session from a terminal, send a prompt, list sessions, or reuse an existing session id.
---

# DSH ACP

DeepSeek Harness exposes an Agent Client Protocol (ACP) server over stdio.
Prefer the `dsh-chat` wrapper; it handles the JSON-RPC framing and model
selection. Use the raw protocol only when writing your own client.

## Quick start

```sh
dsh-chat ask --source codex --title "Auth refactor" "Reply with exactly: HELLO"
```

Output: `HELLO`.

On Windows (cmd.exe / PowerShell):

```bat
dsh-chat.cmd ask --source codex --title "Auth refactor" "Reply with exactly: HELLO"
```

```powershell
dsh-chat ask --source codex --title "认证重构" "Reply with exactly: HELLO"
```

Continue the same conversation:

```sh
SID=$(dsh-chat new --cwd .)
dsh-chat send --session "$SID" "Remember the number 41."
dsh-chat send --session "$SID" "Add one and reply with the result."
dsh-chat close --session "$SID"
```

Windows equivalent:

```powershell
$sid = dsh-chat new --cwd .
dsh-chat send --session $sid "Remember the number 41."
dsh-chat send --session $sid "Add one and reply with the result."
dsh-chat close --session $sid
```

`dsh-chat new` prints a session id. `send` resumes that persisted session in a
new process, so the conversation survives process restarts.

## Commands

```text
dsh-chat ask   [options] <text>
dsh-chat send  [options] --session <id> <text>
dsh-chat new   [options]
dsh-chat list  [options]
dsh-chat close [options] --session <id>
```

Options: `--cwd <dir>`, `--model <provider/model>`, `--source <name>`,
`--title <text>`, `--json`, `--timeout <sec>`, `--quiet`, `--verbose`,
`--surface <acp|headless|sdk|desktop>`, `--heartbeat <sec>`,
`--print-sidecar`.

`--source` / `--title` write a local sidecar
(`$DSH_HOME/run-bubble/sessions/<sessionId>.json`, on Windows
`%DSH_HOME%\run-bubble\sessions\<sessionId>.json`, default
`%USERPROFILE%\.dsh`) so the desktop run bubble can show which agent launched
the session and a short task title. The sidecar also carries `pid`, `surface`,
`heartbeatAt` and `sessionId` so the Windows daemon can tell a live external
run from a stale one. `--print-sidecar` prints the JSON instead of calling dsh.

If `dsh-chat` is not on `PATH`:

```sh
node ~/.dsh/interop/dsh-chat.mjs ...
# Windows:
node "%USERPROFILE%\.dsh\interop\dsh-chat.mjs" ...
node <checkout>\interop\dsh-chat.mjs ...
```

## Windows notes

- Entry points: `dsh-chat.cmd` (cmd.exe, forwards exit code with
  `exit /b %ERRORLEVEL%`) and `dsh-chat.ps1` (PowerShell, forwards
  `$LASTEXITCODE`, works in pipelines). Both set the console to UTF-8 so
  Chinese titles/prompts are not garbled. Installed shims live in
  `%LOCALAPPDATA%\dsh-run-bubble\bin`.
- The launcher defaults to
  `%LOCALAPPDATA%\Programs\DeepSeek Harness\resources\runtime\cli\bin\dsh.cmd`;
  override with `DSH_BIN`. `.cmd` launchers are spawned through
  `cmd.exe /d /s /c`, and `dsh-chat` kills the whole process tree on shutdown
  (`taskkill /T /F`) so no `cmd.exe` shell is left behind.
- PowerShell execution policy may block the `.ps1` shim; use `dsh-chat.cmd`
  or install with `install.ps1 -NoPs1Shim`.

## Raw protocol

Start: `dsh --profile acp` (stdio, newline-delimited JSON-RPC 2.0; stdout is
protocol only, diagnostics on stderr).

```text
initialize {protocolVersion:1, clientCapabilities:{}}
session/new {cwd:"/absolute/path", mcpServers:[]}
session/set_config_option {sessionId, configId:"model", value:"[\"deepseek-account\",\"deepseek-flash\"]"}
session/prompt {sessionId, prompt:[{type:"text", text:"..."}]}
# read session/update notifications until the matching session/prompt response
session/close {sessionId}
```

To resume: `session/list {}`, then `session/resume {sessionId, cwd, mcpServers:[]}`.

The ACP profile defaults to `deepseek-official/deepseek-v4-flash`; without an
API key for that route, select `deepseek-account/deepseek-flash` explicitly.
`dsh-chat` does this automatically when the account option exists.

A session currently owned by the DSH desktop app cannot be resumed:
`session "..." is already owned by an active write handle`. Close it in the app
first, or use a different session.

## Output

- Plain mode: assistant text on stdout, tool/progress lines on stderr.
- `--json`: one JSON object per line (`session`, `text`, `update`, `done`).

## Security

The ACP stdio server is unauthenticated and trusts its client. Any local process
that can spawn `dsh` can drive an agent with your credentials. Do not expose it
to an untrusted network; stdio is local by construction.
