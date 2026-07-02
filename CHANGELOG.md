# Changelog

All notable changes to QuestBits are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html)
(`MAJOR.MINOR.PATCH` — the version is stamped into the app bundle from the git tag).

Releases (signed `.dmg`) are published to the public
[`90n9/quest-bits-releases`](https://github.com/90n9/quest-bits-releases/releases)
repo by CI on every `v*` tag. Source history and tags live in the private
`90n9/quest-bits` repo.

## [Unreleased]

_Nothing yet._

## [1.1.0] - 2026-07-02

### Added

- Auto-update via Sparkle: the app checks for new releases hourly, shows an
  in-app "Update Now" banner plus the native install dialog, and offers
  "Check for Updates…" in the app menu, menu-bar dropdown, and Settings.

### Changed

- Full visual refresh aligned to the DESIGN.md design system (Miro-style
  tokens): pill buttons, pastel badges, hairline cards, brand palette,
  light-appearance lock.
- Done tasks now sink to the bottom of the task list so new and in-progress
  work stays in view.

### Fixed

- Menu-bar dropdown hover highlighted the wrong item while the timer was
  running (the live countdown rebuilt the menu every second).
- Selected task rows were unreadable (dark text on the system blue selection
  fill); selection now uses the lavender featured-state background.

## [1.0.0] - 2026-07-02

First public release — a native macOS todo + Pomodoro app with a bundled MCP
server for Claude Code.

### Added
- **Projects → Tasks.** Group work into projects; each task has a title, detail
  notes, an optional link, and a Todo / In Progress / Done status.
- **Subtasks.** One-level nesting with per-parent progress, checkboxes, and MCP
  support.
- **Recurring tasks.** Completing a recurring task spawns its next occurrence.
- **Task dependencies.** Blocked-by relationships with cycle guard, UI badges,
  and a blocked-guard enforced across all views.
- **Due-date reminders.** Local notifications scheduled for task due dates.
- **Time estimates.** Per-task estimates with estimate-vs-actual comparison.
- **Reusable task templates.** Save and reuse task shapes across the app and MCP.
- **Kanban board.** Drag-and-drop board view with a list/board toggle.
- **Live search.** In-memory search/filter bar for the task list.
- **Stats dashboard.** Sidebar dashboard with per-day and per-project stats.
- **Global Pomodoro timer.** One focus timer for the session (25/5/15), with a
  MenuBarExtra showing a live countdown and controls.
- **Claude Code integration.** Bundled MCP server lets Claude create, edit,
  delete, and update tasks.

### Distribution
- Pure-Swift build (`swiftc`, no Xcode/SPM), ad-hoc code-signed. ~860 KB app,
  ~450 KB DMG.
- CI (`release.yml`) builds a universal DMG on `v*` tags and publishes it to the
  public releases repo.

[Unreleased]: https://github.com/90n9/quest-bits/compare/v1.1.0...HEAD
[1.1.0]: https://github.com/90n9/quest-bits/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/90n9/quest-bits/releases/tag/v1.0.0
