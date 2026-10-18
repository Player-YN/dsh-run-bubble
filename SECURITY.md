# Security

`dsh-run-bubble` is a local utility for macOS and Windows. It does not open a
network listener, send telemetry, or upload session data.

## What it reads

- `~/.dsh/sessions/**/session.v*.jsonl.zstd` (or `%USERPROFILE%\.dsh\sessions`)
  — local DeepSeek Harness logs.
- `~/.dsh/run-bubble/sessions/*.json` — optional local sidecar metadata.
- Which process holds a session's write lease:
  - **macOS**: `lsof -t <session.lock>`, then `ps -o ppid=,comm=` to infer the
    launching agent.
  - **Windows**: the process table via `Get-CimInstance Win32_Process`, and the
    kernel handle table via `DshLeaseProbe.exe` (see below).
- It does **not** read environment variables, credentials, or file contents
  outside the paths above.

## The Windows lease probe

DSH guards each session with a named kernel semaphore
(`Local\dsh-session-lock-<sha256>`). `DshLeaseProbe.exe` is a small, strictly
read-only helper that answers one question: *which PID holds that semaphore?*

- It calls `NtQuerySystemInformation(SystemExtendedHandleInformation)` to snapshot
  handles, then `OpenProcess(PROCESS_DUP_HANDLE)` + `DuplicateHandle` +
  `NtQueryObject(ObjectNameInformation)` to read **object names only**.
- It never acquires, waits on, signals, or releases a session lease.
- It never reads process memory, file contents, or credentials.
- It requires no elevation. Handle entries it cannot open are skipped.
- If the probe is unavailable, the daemon degrades to `mtime`/sidecar heuristics
  and reports `"mode": "win-mtime"` in `daemon.json`.

## What it writes

- `~/.dsh/run-bubble/status.json` (mode `0600`)
- `~/.dsh/run-bubble/daemon.json` (mode `0600`)
- `~/.dsh/run-bubble/position.json` (drag anchor + pin state)
- Logs:
  - macOS: `~/Library/Logs/dsh-run-bubble/`
  - Windows: `%LOCALAPPDATA%\dsh-run-bubble\logs\`
- Windows installs also create two per-user Scheduled Tasks
  (`DshRunBubble-Daemon`, `DshRunBubble-Overlay`). Both run with limited rights;
  no administrator privileges are requested or required.

## Reporting

Please use GitHub's **Report a vulnerability** flow on the repository's
Security tab. Do not include real prompts, tokens, or session logs in a public
issue.
