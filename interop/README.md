# dsh-acp-interop

Part of [dsh-run-bubble](../README.md). Optional; install it when you want
`--source` / `--title` sidecar metadata and a discoverable ACP client.

Make a local DeepSeek Harness agent discoverable and callable from another
coding agent in a terminal.

`dsh --profile acp --help` only prints one line. It does not describe the
protocol. This kit supplies the missing layer:

- `dsh-chat` — a tiny ACP client with self-describing `--help`.
- `SKILL.md` — a skill another agent can load to learn the commands.
- This README — the full raw ACP method table for implementers.

## Install

```sh
cd interop
./install.sh
```

This copies `dsh-chat.mjs` and `SKILL.md` to `~/.dsh/interop/` and creates
`~/.local/bin/dsh-chat`. If `~/.local/bin` is not on `PATH`, add it:

```sh
export PATH="$HOME/.local/bin:$PATH"
```

## Use

```sh
dsh-chat --help
dsh-chat ask "Reply with exactly: HELLO"
SID=$(dsh-chat new --cwd .)
dsh-chat send --session "$SID" "Continue the task"
dsh-chat list
dsh-chat close --session "$SID"
```

Each command spawns `dsh --profile acp`, performs the ACP handshake, and exits.
The session is persisted under `~/.dsh/sessions`; `send` resumes it by id.

## Sidecar metadata

`dsh-chat --source codex --title "Auth refactor" ...` writes
`$DSH_HOME/run-bubble/sessions/<sessionId>.json`:

```json
{
  "source": "codex",
  "sourceLabel": "Codex",
  "title": "Auth refactor",
  "task": "Use the bash tool to ...",
  "updatedAt": "2026-10-18T09:32:21.116Z"
}
```

The desktop run bubble reads this so a root session shows its launching agent
and a short task title. Without it, the bubble infers source from the lock
holder's `ps` parent chain and uses the first real user prompt.

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

## Session ownership

Only one process can write a session. A session live in the DSH desktop app is
locked; `session/resume` returns `already owned by an active write handle`.
Close it in the app first. ACP `session/resume` accepts persisted, inactive
sessions only.

## References

- ACP specification: https://agentclientprotocol.com
- TypeScript ACP SDK: https://www.npmjs.com/package/@agentclientprotocol/sdk
- DSH ACP package: https://www.npmjs.com/package/@deepseek-ai/dsh-acp
- DSH SDK client: https://www.npmjs.com/package/@deepseek-ai/dsh-sdk-client
