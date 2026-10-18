## Talking to DeepSeek Harness (DSH)

A local DSH agent is available over ACP. Use the wrapper, not raw JSON-RPC:

```sh
dsh-chat --help
dsh-chat ask --source codex --title "Auth refactor" "Reply with exactly: HELLO"
SID=$(dsh-chat new --cwd .)
dsh-chat send --session "$SID" "Continue the task"
dsh-chat list
dsh-chat close --session "$SID"
```

- `dsh-chat` is at `~/.local/bin/dsh-chat` (or `~/.dsh/interop/dsh-chat.mjs` with `node`).
- `new` prints a session id; `send --session <id>` resumes it in a new process.
- `--source Codex --title "..."` writes the run-bubble sidecar; without it the
  bubble falls back to process inference and the first prompt.
- Plain output: answer on stdout; `--json` gives one JSON object per line.
- A session live in the DSH desktop app cannot be resumed (`already owned by an active write handle`); use a new session or close it in the app.
- Raw protocol: `dsh --profile acp`, newline-delimited JSON-RPC; see `~/.dsh/interop/SKILL.md`.
