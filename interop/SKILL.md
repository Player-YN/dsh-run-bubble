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

Continue the same conversation:

```sh
SID=$(dsh-chat new --cwd .)
dsh-chat send --session "$SID" "Remember the number 41."
dsh-chat send --session "$SID" "Add one and reply with the result."
dsh-chat close --session "$SID"
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
`--title <text>`, `--json`, `--timeout <sec>`, `--quiet`, `--verbose`.

`--source` / `--title` write a local sidecar
(`$DSH_HOME/run-bubble/sessions/<sessionId>.json`) so the desktop run bubble can
show which agent launched the session and a short task title.

If `dsh-chat` is not on `PATH`, run `node ~/.dsh/interop/dsh-chat.mjs ...`.

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
