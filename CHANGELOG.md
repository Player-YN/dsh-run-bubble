# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.3.4] - 2026-10-19

### Fixed

- Active sessions older than the 6-hour recent window are no longer dropped.
  The desktop app's long-lived chat can be days old while still streaming; an
  open `turn/start` now wins over `createdAt`. This is why the current desktop
  conversation could still show idle even with `includeDesktop` enabled.

## [0.3.3] - 2026-10-19

### Added

- **macOS parity with the 0.3.1 panel.** The native overlay now has the
  content-sized 55 × 26 idle pill, the monitor button for desktop sessions, and
  fullscreen auto-hide, all sharing `config.json` with the daemon.
- macOS daemon honours `includeDesktop` / `RUN_BUBBLE_INCLUDE_DESKTOP`; the
  panel's monitor toggle now changes the row set on the next refresh.
- `daemon.json` reports `includeDesktop` on macOS as well as Windows.
- Header now carries two 18 px icons (monitor, then pin); expanded time/badge
  positions account for the pair.

### Fixed

- A hidden-for-fullscreen panel can no longer be resurrected by a status poll.

## [0.3.2] - 2026-10-19

### Fixed

- Status gaps that made the bubble fall back to idle while external sessions were
  still running. macOS liveness is now one **bulk `lsof`** per refresh instead of
  one `lsof` process per session (80+ sessions => 20s+ refresh stalls), and a 1s
  heartbeat keeps `status.json` fresh while a refresh is busy.
- The macOS installer now ships `src/` alongside `daemon.mjs`; the cross-platform
  daemon imports `src/win/*` even on macOS.

## [0.3.1] - 2026-10-18

### Added

- **Desktop-session toggle in the panel.** A monitor icon next to the pin shows or
  hides the desktop app's own sessions. Icon-only, no menu, no text; the choice is
  written to `config.json` and survives restarts.
- **Fullscreen auto-hide.** When a foreground window covers the whole monitor the
  bubble lives on (a game, fullscreen video, presentation), the overlay hides
  itself and returns when that window is gone. Opt out with
  `"hideOnFullscreen": false`.
- `config.json` (`$DSH_HOME/run-bubble/config.json`) as the shared runtime
  settings file between overlay and daemon; `RUN_BUBBLE_INCLUDE_DESKTOP` still
  overrides it for scripts and CI.
- `daemon.json` now reports `includeDesktop` alongside `leaseProbe` for diagnosis.

### Changed

- The idle pill shrank from 238 × 42 to a **content-sized ~55 × 26** capsule; the
  collapsed width is computed from the label, badge and elapsed time and clamped to
  52–238 px, so the corner it anchors to never jumps. Idle no longer draws a `—`
  placeholder or a badge.
- README now states up front that the tool is built for **external agent runs**, and
  documents the panel icons and the fullscreen behaviour.

### Fixed

- Collapsed width no longer depends on the expanded panel's fixed 238 px, so a
  short idle label does not leave a mostly empty pill.

## [0.3.0] - 2026-10-18

Windows port. The daemon and the `status.json` v2 contract are shared by both
platforms; only the overlay and the service manager are platform specific.

### Added

- **Windows overlay** — `src/overlay/` (C#/.NET 8, WinForms + `UpdateLayeredWindow`):
  always-on-top, non-activating, taskbar-free panel with per-pixel alpha, hover
  expand, pin, 350 ms long-press drag, wheel scrolling, per-root collapse, idle
  state, and `--demo*`/`--snapshot` modes for pixel-parity screenshots.
- **`DshLeaseProbe.exe`** (`src/lease-probe/`) — read-only kernel handle-table
  probe that resolves the real holder PID of a session's named kernel semaphore
  lease (`Local\dsh-session-lock-<sha256>`). Gives Windows the same live/dead and
  desktop/external attribution that macOS gets from `session.lock` + `lsof`.
- **Windows launcher** — `run-bubble.ps1` (`install|start|stop|restart|status|
  logs|snapshot|doctor|uninstall`) and `build.ps1`, with per-user Scheduled Tasks
  (`DshRunBubble-Daemon`, `DshRunBubble-Overlay`, restart on failure, no
  elevation) mirroring the launchd `KeepAlive` behaviour.
- **Cross-platform interop** — `interop/dsh-chat.cmd`, `dsh-chat.ps1`,
  `install.ps1`; the sidecar gained `pid`, `surface`, `heartbeatAt`, and
  `sessionId` so the daemon can attribute an ACP run without guessing.
- **`tests/`** — synthetic session-store fixture (one zstd frame per event, plus a
  half-written trailing frame) and `tests/smoke.mjs` asserting the daemon contract
  end to end.
- **Docs** — `docs/PORT-WINDOWS.md` (design contract),
  `docs/dsh-internals-windows.md` (reverse-engineering notes), Windows sections in
  both READMEs.
- Windows CI job (`windows-latest`): builds overlay + probe, runs the daemon smoke
  test, and renders every demo snapshot.

### Changed

- `daemon.mjs` is now cross-platform: the macOS path keeps `lsof`/`ps`, the
  Windows path uses one cached `Get-CimInstance` process-table query and the lease
  probe.
- Session ids are normalised: DSH writes both `session-<uuid>` and bare `<uuid>`,
  so `shortId`/`colorKey` strip the optional prefix while grouping still matches on
  the full string.
- `fallbackTitle` splits `cwd` on both `/` and `\`, so Windows paths no longer
  produce a one-line title of the whole path.
- Task previews also come from `agent/inbox/spliced` (the current DSH build no
  longer emits `user/message`), and child labels come from the parent's
  `subagent/catalog` events.
- Desktop-host detection normalises `\` to `/` before matching
  `dsh-desktop-host/lib/index.js`; the old forward-slash match never fired on
  Windows.

### Fixed

- **Multi-frame zstd**: DSH appends one zstd frame per event. `zlib.zstdDecompressSync`
  and the stream API silently decode only the first frame, which would have shown
  every session as empty with zero tokens. The Windows decoder walks frame headers
  and keeps the prefix when a partially written frame is hit.
- Atomic status writes retry on transient `EPERM` while the overlay is reading.

### Notes

- If the lease probe cannot run (missing binary, hardened environment), the daemon
  degrades to an `mtime`/sidecar heuristic and reports `"mode": "win-mtime"` in
  `daemon.json` so the reduced fidelity is visible.
- `RUN_BUBBLE_INCLUDE_DESKTOP=1` shows the desktop app's own sessions in the bubble.

## [0.2.0] - 2026-10-18

### Added

- Multiple concurrent ACP roots with stable color grouping and short session ids.
- Source and title sidecar support through `dsh-chat --source/--title`.
- Process-tree source inference as a fallback (`~` marks inferred sources).
- Structured metadata chips: source, id, child count, model, effort, turn.
- Task preview line with a distinct accent.
- Pin button that keeps the expanded panel open; pin state persists.
- Long-press drag with a persisted bottom-right anchor and multi-screen clamping.
- Collapsible child lists per root (`▾` / `▸`, click the root row).
- Vertical scrolling with fixed header/footer for high-concurrency runs.
- `schemaVersion: 2` status document.

### Changed

- Idle panel is always mounted instead of hiding.
- Empty snapshots keep the last non-empty state for 2.5 seconds.
- Higher-contrast muted text and chip-based metadata.

## [0.1.0] - 2026-10-18

### Added

- Initial standalone launchd daemon + AppKit overlay.
- Reads ACP/headless session logs, folds turns, tokens, and child agents.
- Collapsed/idle states, hover expansion, snapshot flag for demos.
