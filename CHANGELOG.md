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

## [1.2.2] - 2026-07-09

### Added

- Dev/prod build flavors: local builds now produce an isolated "QuestBits Dev"
  app (own bundle id, own `TodoAppDev` database, own `todo-dev` MCP
  registration, orange DEV badge in the sidebar footer) so experiments never
  touch production data. `FLAVOR=prod` or CI builds the production app.

### Fixed

- Local builds stamped a hardcoded `1.0.0` as their version; they now derive it
  from `git describe --tags` (e.g. `1.2.1-3-g65a2000`) so the sidebar footer
  shows the build's real provenance. Release builds still use the git tag.

## [1.2.1] - 2026-07-09

### Fixed

- Auto-update signature verification: the Sparkle public key baked into the app
  did not match the private key CI signs releases with, so every shipped build
  silently rejected updates. The correct public key is now baked in.
  **Note:** builds ≤ 1.2.0 carry the wrong key and cannot auto-update to this
  release — update them once manually by downloading the DMG.

### Added

- Custom app icon (parchment quest-scroll) bundled into the app and DMG.
- App version shown in the sidebar footer.

### Changed

- README: added Gatekeeper instructions for opening un-notarized downloads
  ("damaged app" fix via `xattr -dr com.apple.quarantine`).

## [1.2.0] - 2026-07-02

### Added

- Cozy RPG theme ("QuestBit"): parchment / bark / harvest-gold palette replacing
  the previous white-and-blue design; DESIGN.md rewritten as the
  `QuestBit-cozy-rpg` spec.
- Bundled fonts (OFL): Alegreya for headings and the timer, Quicksand for body
  text — registered from the app bundle at launch.
- Bundled icon set: Lucide (ISC) and Tabler (MIT) SVG icons for the sidebar,
  project rows, and pomodoro phases (campfire / beer / bed / embers); license
  texts ship inside the app.
- Decorative art (all CC0): Kenney fantasy border framing the task-detail pane,
  ambientCG paper grain on parchment surfaces, and wood planks under the dark
  hearth bars.
- New due-date picker: a formatted-date button opens a calendar popover with
  Today / Tomorrow / Next week quick picks (replaces the stepper field).
- Done tasks collapse into a "Done (N)" toggle section at the bottom of the
  task list; the expanded/collapsed state persists across launches.

### Changed

- Task-detail pane rebuilt from the system grouped form into themed parchment
  section cards with bright vellum input fields.
- Sidebar restyled as a quest log: "Quests" / "Quest Logs" headers, gold
  selection cards, and per-project code + task-count pills.
- Pomodoro bar and update banner are now dark-bark hearth surfaces with cream
  text and wood-grain texture.

### Fixed

- Input fields in the task-detail pane rendered a doubled outline (a container
  shadow cascaded onto every child view).

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

[Unreleased]: https://github.com/90n9/quest-bits/compare/v1.2.0...HEAD
[1.2.0]: https://github.com/90n9/quest-bits/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/90n9/quest-bits/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/90n9/quest-bits/releases/tag/v1.0.0
