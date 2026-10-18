# Contributing

Thanks for taking the time to improve `dsh-run-bubble`.

## Before you open an issue

- Check the [README](README.md), especially **Limitations** and **Privacy**.
- Run `./run-bubble logs` and `./run-bubble status`; include the relevant output
  with secrets and session prompts removed.
- Include macOS version, Xcode command line tools version, Node version, and
  the output of `./run-bubble status`.

## Pull requests

1. Fork the repo and create a branch: `feat/...`, `fix/...`, or `docs/...`.
2. Keep the change focused. UI changes should include a before/after snapshot
   rendered with:
   ```sh
   ./RunBubbleOverlay --demo --snapshot /tmp/before.png
   ./RunBubbleOverlay --demo-many --collapse-first --snapshot /tmp/after.png
   ```
   The `--demo*` flags never read the real session store.
3. Run:
   ```sh
   make check
   make build
   ```
4. Update `README.md` / `README.zh-CN.md` and `CHANGELOG.md` when behavior or
   paths change.
5. Open the PR with a short “what / why / how tested” description.

## Code notes

- `daemon.mjs` is intentionally dependency-free Node. Keep the folded state
  small; never retain event arrays.
- `overlay.swift` is a single AppKit file; avoid adding third-party Swift
  packages. The panel must stay usable without Accessibility or
  Screen Recording permissions.
- The status document is versioned (`schemaVersion`). Add fields; don't break
  existing ones without a migration note.

## Good first issues

- Windows/Linux overlay that consumes the same `status.json`.
- Persist per-root collapsed state.
- Optional “compact mode” that hides the token footer.
- Menubar icon variant.
