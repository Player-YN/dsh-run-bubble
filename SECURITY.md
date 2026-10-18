# Security

`dsh-run-bubble` is a local macOS utility. It does not open a network listener,
send telemetry, or upload session data.

## What it reads

- `~/.dsh/sessions/**/session.v*.jsonl.zstd` — local DeepSeek Harness logs.
- `~/.dsh/run-bubble/sessions/*.json` — optional local sidecar metadata.
- The lock holder PID for a session via `lsof`, then `ps -o ppid=,comm=` to infer
  the launching agent. It does **not** read environment variables.

## What it writes

- `~/.dsh/run-bubble/status.json` (mode 0600)
- `~/.dsh/run-bubble/position.json` (drag anchor + pin state)
- LaunchAgent logs under `~/Library/Logs/dsh-run-bubble/`

## Reporting

Please use GitHub's **Report a vulnerability** flow on the repository's
Security tab. Do not include real prompts, tokens, or session logs in a public
issue.
