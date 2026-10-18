# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]

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
