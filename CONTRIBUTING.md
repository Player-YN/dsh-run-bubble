# Contributing

Thanks for taking the time to improve `dsh-run-bubble`.

## Before you open an issue

- Check the [README](README.md), especially **Limitations** and **Privacy**.
- macOS: run `./run-bubble logs` and `./run-bubble status`.
- Windows: run `pwsh -File .\run-bubble.ps1 logs`, `... status`, and
  `... doctor`.
- Include the relevant output with secrets and session prompts removed, plus
  your OS version, Node version, .NET SDK version (Windows), and the `mode`
  field from `daemon.json` on Windows.

## Pull requests

1. Fork the repo and create a branch: `feat/...`, `fix/...`, or `docs/...`.
2. Keep the change focused. UI changes should include a before/after snapshot:
   ```sh
   # macOS
   ./RunBubbleOverlay --demo --snapshot /tmp/before.png
   ./RunBubbleOverlay --demo-many --collapse-first --snapshot /tmp/after.png
   ```
   ```powershell
   # Windows
   .\dist\RunBubbleOverlay.exe --demo --snapshot $env:TEMP\before.png
   .\dist\RunBubbleOverlay.exe --demo-many --collapse-first --snapshot $env:TEMP\after.png
   ```
   The `--demo*` flags never read the real session store.
3. Run the checks for the platform you touched:
   ```sh
   make check && make build            # macOS
   ```
   ```powershell
   node --check daemon.mjs
   pwsh -File .\build.ps1
   node tests\smoke.mjs
   ```
4. Update `README.md` / `README.zh-CN.md` and `CHANGELOG.md` when behavior or
   paths change.
5. Open the PR with a short “what / why / how tested” description.

## Code notes

- `daemon.mjs` is intentionally dependency-free Node and shared by both
  platforms. Keep the folded state small; never retain event arrays.
- Session logs are **concatenated zstd frames** (one per append). Never decode
  them with a single-shot `zstdDecompressSync` — that silently returns only the
  first frame. Use `src/win/zstd.mjs`.
- `overlay.swift` is a single AppKit file; avoid third-party Swift packages. The
  panel must stay usable without Accessibility or Screen Recording permissions.
- `src/overlay/` is the Windows overlay: WinForms + `UpdateLayeredWindow`, no
  WebView, no Electron. Keep rendering DIP-based; the window layer owns DPI.
- `src/lease-probe/` is read-only. Never acquire, wait on, or release a session
  lease, and never read process memory.
- The status document is versioned (`schemaVersion`). Add fields; don't break
  existing ones without a migration note.

## Good first issues

- Linux overlay that consumes the same `status.json`.
- Persist per-root collapsed state.
- Optional “compact mode” that hides the token footer.
- `--dark` / `--light` theme override for deterministic screenshots.
