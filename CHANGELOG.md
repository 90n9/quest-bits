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

### Added

- New **Waiting** status for tasks parked on someone else. A waiting task says
  who it waits on — `user` (you have to decide or act) or `external` (a reply,
  a review, a deploy) — plus an optional reason. MCP `create_task`,
  `update_task` and `bulk_update_tasks` take `waiting_on` / `waiting_reason`;
  setting `status: waiting` without `waiting_on` is an error unless the task is
  already waiting, and moving to any other status clears both fields. Waiting
  is still open: it can be blocked, and tasks that depend on it stay blocked.
  Changes to who a task waits on show in its history.
- In the app, Waiting has its own clay colour, pause icon, board column and a
  "waiting on me / external" chip with the reason. Set it from the bulk Status
  menu, the Task menu (Mark Waiting on Me ⌘4, Mark Waiting on External ⌘5), a
  drag onto the Waiting column, or the task detail, which also edits who it
  waits on and the reason. Clicking a waiting task's status icon resumes it
  (In Progress).
- New **Dropped** status for work you abandon, so you no longer have to delete
  a task (and lose its history) to stop doing it. A dropped task is closed like
  a done one — it is never blocked, and tasks that depend on it are no longer
  blocked — but it is not a completion: it gets no `completed_at`, does not
  count as completed in stats, and dropping a recurring task spawns no next
  occurrence. Dropping a done task clears its completion.
- In the app, dropped tasks are faded, struck through and marked with a cross;
  they collapse with done tasks into the list's bottom section and sit in the
  board's Done column. Set Dropped from the bulk Status menu, the Task menu
  (Mark Dropped ⌘6) or the task detail. Clicking a dropped task's status icon
  (or a dropped subtask's checkbox) reopens it as Todo, and dropped subtasks
  leave the parent's n/total subtask count.
- MCP `list_tasks` filters: `status` (one status, an array, or `"all"`),
  `tag` (a whole tag, case-insensitive for ASCII letters) and `parent_id` /
  `parent_code` (subtasks of a task), alongside the existing project filter.
  Filtering happens in the database, not after loading every task.
- Task **notes**: a timestamped, append-only log on each task, so the detail
  can stay the task's spec. New MCP tool `add_note` (`id` or `code`, `text`,
  optional `kind`: `note`, `decision` or `review`) only inserts — nothing is
  read and rewritten — so two sessions logging at once never lose each
  other's notes, and the change history no longer stores the whole detail
  again for every added line. Adding a note bumps the task's `updated_at`.
  `get_task` returns the latest 5 notes, newest first (`notes_limit` sets how
  many, 0 for none, up to 100; `more_notes: true` when older ones were left
  out); `list_tasks` never returns notes. Notes stay with a moved task, are
  not copied by duplicate or copy, and are deleted with their task. Progress
  already written into a task's detail is left where it is.
- In the app, the task detail has a Notes section: notes newest first with a
  coloured kind chip, and a field with a kind picker to add your own. Notes
  an agent adds appear within the usual refresh.

### Changed

- MCP responses are compact JSON (no pretty-printing, unescaped `/` in links),
  cutting task output by about a fifth on a real database. Every tool that
  returns tasks now uses one shared serializer: other tasks are referenced by
  code (`parent: "CHU-5"`, `depends_on: ["CHU-2"]`) instead of numeric ids, and
  null, empty or default fields (no priority, no tags, no link, zero effort or
  estimate, `blocked: false`) are left out. `effort_seconds` and
  `estimate_seconds` are dropped in favour of the `*_minutes` fields.
- MCP `list_tasks` now returns only open tasks (todo, in progress, waiting) in
  a compact view by default: code, title, status, and — only when set —
  priority, parent, `blocked_by` (codes of the open dependencies blocking it),
  tags, due date and `waiting_on`. Use `get_task` to read a task's detail, or
  pass `view: "full"` for the old shape and `status: "all"` to include done
  and dropped tasks. Results are sorted In Progress, Waiting, Todo, Done,
  Dropped, then by board order. On a real database a project listing shrank
  from 35,378 to 1,500 characters and from 234,725 to 3,959.
- Reopening a done task (back to Todo or In Progress) now clears its
  `completed_at`, so it no longer counts as completed in the activity stats.
  Marking an already-done task done again keeps the original `completed_at`.
- MCP `update_task` now tells agents to log progress with `add_note` instead
  of appending to the task's detail.

### Fixed

- An MCP `*_code` argument that matches no task or project (e.g.
  `parent_code: "ZZZ-9"`) now fails with "not found: task ZZZ-9" instead of
  "missing or invalid argument".
- A task that is itself done is no longer reported as `blocked`, even when one
  of its dependencies is still open.
- `started_at` and `completed_at` are now set on every path that changes a
  task's status: creating a task straight into In Progress or Done (MCP
  `create_task` with `status`), bulk status updates, and moving a task from
  Todo straight to Done (which used to leave `started_at` empty). All of them
  share one timestamp rule.
- Duplicating a task within its project (`duplicate_task` without a target,
  Duplicate in the app) now creates a fresh todo for reuse — status,
  `started_at` / `completed_at` and waiting fields are not copied — so it no
  longer counts as another completion. Copying a task to another project keeps
  its status, times and waiting fields, and now means the same everywhere:
  `duplicate_task` with `to_project_*`, `bulk_move_tasks` with `copy: true`,
  and Copy to in the app (MCP `duplicate_task` used to reset the copy).
- `bulk_update_tasks` is now all or nothing: every task is checked and written
  in one transaction (including `add_tags`), so a bad or missing task leaves
  the whole batch unchanged instead of half-applied. An `add_tags` that adds
  nothing new no longer marks the task updated. The app's bulk Status and Add
  Tags actions use the same all-or-nothing write and show an error instead of
  a success toast when it fails.
- Every status change now re-reads the task inside its write transaction, so
  a status change racing another process's write logs the status it actually
  replaced. Leaving Waiting no longer adds a separate "waiting on → (empty)"
  history row; the status row already says it.
- The task detail pane no longer overwrites changes an agent made while the
  task was open: it saves only the fields you edited, and fields you have not
  touched refresh from the database. Selecting a blocked task no longer raises
  the "Task is blocked" prompt (whose Cancel could write the previous task's
  status onto it).
- One-time repair on first launch: done and in-progress tasks missing
  `completed_at` / `started_at` get them back from the task's status history,
  falling back to its last-updated time; reopened tasks still carrying a
  `completed_at` have it cleared.

## [1.2.3] - 2026-07-09

### Changed

- MCP registration key renamed from `todo` to `quest-bits` (`todo-dev` →
  `quest-bits-dev` for dev builds) so the entry in `~/.claude.json` clearly
  identifies this app. On launch the app migrates its own legacy entry
  automatically (only when it points at a QuestBits binary).

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
