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

Windows (cmd.exe / PowerShell; the wrappers set UTF-8 and forward exit codes):

```bat
dsh-chat.cmd ask --source codex --title "Auth refactor" "Reply with exactly: HELLO"
dsh-chat.cmd new --cwd .
dsh-chat.cmd send --session <id> "Continue the task"
```

```powershell
dsh-chat ask --source codex --title "认证重构" "Reply with exactly: HELLO"
$sid = dsh-chat new --cwd .
dsh-chat send --session $sid "继续任务"
pwsh -NoProfile -File "$env:USERPROFILE\.dsh\interop\dsh-chat.ps1" --help
```

- macOS: `dsh-chat` is at `~/.local/bin/dsh-chat` (or
  `~/.dsh/interop/dsh-chat.mjs` with `node`).
- Windows: `dsh-chat.cmd` / `dsh-chat.ps1` are installed in
  `%LOCALAPPDATA%\dsh-run-bubble\bin` (PATH), with the script at
  `%USERPROFILE%\.dsh\interop\dsh-chat.mjs`; run that file with `node` if the
  shim is not on PATH.
- `new` prints a session id; `send --session <id>` resumes it in a new process.
- `--source codex --title "..."` writes the run-bubble sidecar
  (`%USERPROFILE%\.dsh\run-bubble\sessions\<id>.json` on Windows); without it
  the bubble falls back to process inference and the first prompt.
- Plain output: answer on stdout; `--json` gives one JSON object per line.
- A session live in the DSH desktop app cannot be resumed (`already owned by an
  active write handle`); use a new session or close it in the app.
- Raw protocol: `dsh --profile acp`, newline-delimited JSON-RPC; on Windows the
  launcher is `…\DeepSeek Harness\resources\runtime\cli\bin\dsh.cmd`. See
  `~/.dsh/interop/SKILL.md` (Windows: `%USERPROFILE%\.dsh\interop\SKILL.md`).
