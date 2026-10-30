# Changelog

All notable changes to QuestBits are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html)
(`MAJOR.MINOR.PATCH` — the top `## [X.Y.Z]` heading below is the version CI
stamps into the app bundle and tags as `vX.Y.Z`).

Releases (signed `.dmg`) are published to the public
[`90n9/quest-bits-releases`](https://github.com/90n9/quest-bits-releases/releases)
repo by CI when a merge to main adds a new `## [X.Y.Z]` here (or on a
hand-pushed `v*` tag). Source history and tags live in the public
`90n9/quest-bits` repo.

## [Unreleased]

_Nothing yet._

## [1.5.0] - 2026-10-31

### Added

- **Guide templates by kind of project.** New Project has a Kind picker
  (Web app, App, Research, Animation, or None) that starts the project's
  agent guide from a short template you then edit. A project whose guide is
  still empty gets a **Start from template** menu in its guide sheet. The
  template is saved as an ordinary guide version, so History shows it and
  can restore past it. The templates are first drafts and will be rewritten
  from the guides you actually keep.
- MCP `create_project` takes an optional `guide_template` (`web_app`, `app`,
  `research` or `animation`) and `session`.
- **Project descriptions use the Notion-style editor** of a task's Detail:
  headings, lists, bold and italic, links and pasted or dropped images. The
  text is still markdown. In the project sheet, Save is ⌘Return, because
  Return belongs to the editor.
- MCP project results (`list_projects`, `create_project`) list the files of
  images in the description as `attachments`, as tasks already do.

## [1.4.2] - 2026-10-30

### Added

- **Agent guides.** Agents get QuestBits' built-in rules with `get_guide`,
  then your guide for every project, then the project's own guide (for
  example "render a preview before exporting" for an animation project).
  Edit your guide in Settings → Agent Guide, and a project's guide from its
  menu in the sidebar (Edit Guide…). History lists every version, yours and
  agents', and can restore one.
- MCP `update_guide` lets an agent change a guide, but only when you asked it
  to or said yes to its question. Every change is a new version with its
  reason. `get_guide_history` lists the versions.
- **Commands to paste into Claude Code.** A task's Detail shows
  `/mcp__quest-bits__work <code>` with a copy button: it starts a session on
  that task. The Questions page shows `/mcp__quest-bits__resume` (and a
  `/loop` form) for a session that stopped waiting for your answers.
- MCP `update_task` and `bulk_update_tasks` take `parent_code` (or
  `parent_id`) to move a task under another top-level task of the same
  project, or `null` to make it top-level again. The change is in the task's
  history.

### Changed

- The rules QuestBits gives every Claude Code session are shorter and say
  when they apply: only while the session works on a QuestBits task. A quick
  question or routine work in another repo no longer brings in the ask loop.
  The full rules moved to `get_guide`.

### Fixed

- The Questions page no longer shows white strips on either side of the
  question card.

## [1.4.1] - 2026-10-30

### Changed

- **Detail is now a Notion-style editor.** Type `/` for blocks: headings,
  lists, to-dos, quotes, tables and images. Drag a block by its handle, and
  format selected text from the toolbar. Paste a link, or select text to add
  one; ⌘-click a link to open it in your browser.
- Attach images to a task's Detail: paste one, drop a file, or use the image
  block. Images are saved in an `attachments` folder next to the database.
- Detail is still saved as markdown, so agents read and write it as before.
  Opening a task never rewrites its Detail; only your edits are saved. A
  single line break stays a line break. MCP `get_task` lists the files of
  attached images in `attachments`, so an agent can open them.
- Detail has no text-field frame any more, so it takes less room.
- Thai text in Detail uses the system Thai font, and long words or paths
  wrap instead of running off the edge.
- Task rows in the list show the code and status chips on their own line,
  so a title in a narrow column wraps between words, not inside one.

### Added

- Click a subtask to open it in the detail column, to give it its own
  Detail and notes.
- The sidebar footer has an **Update to vX** button when a new version is
  out, even after you close the top banner. Otherwise it has a **Check for
  updates** link.

## [1.4.0] - 2026-10-30

### Added

- **Ask loop: agents can leave you questions and keep working.** An agent
  calls the new MCP tool `ask_user` with 2–4 options, the one it recommends
  and why, then moves on to other work. The question shows on the new
  **Questions** page in the sidebar (with a count). Each card shows the task,
  the question, its context and the options, with the recommended one in
  green. Pick an option (click it or press 1–4), type your own answer, or for
  an approval approve or edit the draft. ⌘↵ sends and goes to the next
  question; **Skip for now** leaves it open.
- A question blocks its task by default. The task waits on you until every
  blocking question is answered, then goes back to todo.
- New MCP tools for agents:
  - `get_answers` lists answered questions. Agents check it before new work.
  - `resume_question` takes an answer back up. It logs the answer as your
    decision and moves the task to in progress.
  - `cancel_question` withdraws a question the agent no longer needs.
  - `wait_for_answers` waits inside the tool call until you answer, for up to
    4 hours (max 24). It keeps the Mac from idle sleep while it waits, but a
    closed lid still sleeps. It sends a progress update each minute, so Claude
    Code's 30-minute idle timeout does not end it. After two minutes Claude
    Code moves the call to a background task and the agent is woken when it
    returns. Stopping it (Esc, or stopping the task) ends the wait.
- The MCP server now gives Claude Code the ask-loop rules up front (MCP
  `instructions`): ask instead of stopping, check answers first, record your
  own decisions, and always ask before anything irreversible.
- **Notes v2.** Notes have new kinds: `progress`, `summary` and `question`
  (written by `ask_user`), next to note, decision and review. Each note now
  records who wrote it (you or the agent) and, optionally, the agent session.
- `update_task` takes an optional `note`, saved in the same write and linked
  to the status change. When the update closes the task, the note defaults
  to a summary. A summary is never required to close a task.
- MCP `search_notes` finds notes by text across projects, optionally by
  project and kind (for example "how did we decide X").
- You can edit your own notes in the app (the pencil on a note). Earlier
  versions are kept: click **edited** to see them, or use MCP
  `get_note_history`. Agents can only add notes, never edit them.

### Changed

- The task detail's Notes and History sections are now one **Timeline**:
  notes, status and field changes, and questions, newest first. Filter it by
  kind with **Show**. A question shows whether it waits for you (with a link
  to answer it) and its answer. A note saved with a status change shows that
  change.
- MCP `get_task` notes now include `id`, `author`, `session`, `edited_at`
  and `question_id`. `get_task` also lists the task's open and
  answered-but-not-resumed `questions`. `inbox` items list their open
  `questions`.

### Upgrade notes

- On first open, 1.4.0 rebuilds the notes table to allow the new kinds. Every
  note and its id is kept. Notes from before 1.4.0 have no author and cannot
  be edited. An older app or MCP server still running on the same database
  keeps working.

## [1.3.1] - 2026-10-30

### Fixed

- **Duplicate** on a selection (⌘D or the Task menu) is now one all-or-nothing
  write: if any task can't be copied, no copy is made and a toast says why.
  It used to skip failures silently. A toast now confirms how many tasks were
  duplicated. Copies (and **Copy to project** on a selection) are made in the
  order the list shows, so their codes follow that order.
- **Delete** on a selection is now one all-or-nothing write. If the delete
  fails (for example, the database is locked by the MCP server), no task is
  deleted, the selection is kept and a toast says why. It used to report
  "Deleted N tasks" even when nothing was deleted. Deleting one task from its
  context menu also shows a toast when it fails.
- Setting priority on a selection is now one all-or-nothing write with an
  error toast. It used to report success even when nothing changed.
- A selected task that is deleted elsewhere (for example over MCP) leaves the
  selection on the next reload, so the bulk actions on the rest of the
  selection no longer fail on it.
- MCP `bulk_delete_tasks` checks every task before it deletes any. An unknown
  numeric id is now an error (`not found: task N`) and no task is deleted,
  like an unknown code already was and like the other bulk tools. It used to
  report success. The reply counts the tasks actually deleted, subtasks
  included.
- The MCP bulk tools act once on a task named twice (by `id` and `code`, or
  repeated). `bulk_move_tasks` with `copy: true` used to copy it twice.

### Docs

- CLAUDE.md and the README say clearly that only the MCP server reads
  `TODO_DB_PATH`. The app and a bare `Store()` always open the real database,
  so test scripts must use `Store(url:)` with a throwaway path. The MCP smoke
  test example now sets `TODO_DB_PATH` on the `todo-mcp` process, not on
  `echo`.

## [1.3.0] - 2026-10-30

### Added

- New **Waiting** status for tasks parked on someone else. A waiting task says
  who it waits on — `user` (you have to decide or act) or `external` (a reply,
  a review, a deploy) — plus an optional reason, and remembers when it started
  waiting (`waiting_since`, kept while it stays waiting, also when who it waits
  on changes). MCP `create_task`, `update_task` and `bulk_update_tasks` take
  `waiting_on` / `waiting_reason`; setting `status: waiting` without
  `waiting_on` is an error unless the task is already waiting, and moving to
  any other status clears all three fields. `get_task` shows them. Waiting is
  still open: it can be blocked, and tasks that depend on it stay blocked.
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
- MCP `inbox`: the tasks an agent is waiting on you to answer — waiting tasks
  with `waiting_on: user` — across every project that is not archived,
  longest waiting first. Each item is compact: code, title, project code,
  `waiting_since` and the waiting reason when there is one.
  `include_external: true` adds tasks waiting on a third party (each item then
  says `waiting_on`). An empty inbox is `[]`.
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
- MCP `list_tasks` filters: `status` (one status, an array, or `"all"`),
  `tag` (a whole tag, case-insensitive for ASCII letters) and `parent_id` /
  `parent_code` (subtasks of a task), alongside the existing project filter.
  Filtering happens in the database, not after loading every task.
- Archive finished projects to free up the sidebar. Right-click a project for
  Archive / Unarchive; archived projects move to an "Archived" group at the
  bottom of the sidebar, collapsed by default, and still open and work as
  usual. Archiving a project with open tasks asks first and says how many are
  left; the tasks stay as they are. Archived projects are left out of All
  Tasks, In Progress, the menu bar and the Move/Copy to menus, and their
  in-progress tasks earn no focus time; due-date reminders still fire.
  Archiving the selected project opens the Archived group so it stays in
  view. New Task, New Task from Template and adding a subtask are not offered
  in an archived project. An archived project's code stays taken, so a new
  project never reuses it.
- MCP `archive_project` and `unarchive_project` (by `id` or `code`).
  `archive_project` returns the project with `open_tasks` when some are still
  open. `list_projects` leaves archived projects out unless
  `include_archived: true`, and marks them with `archived_at`. `list_tasks`
  without a project or parent leaves out tasks of archived projects unless
  `include_archived: true`; naming the project still lists them. New or moved
  tasks can't target an archived project (`create_task`, `move_task`,
  `bulk_move_tasks`, `duplicate_task` with a target, `new_task_from_template`
  fail with "project X is archived; unarchive it first"); reading and updating
  its tasks works as usual.
- Drag projects in the sidebar's Quest Logs to reorder them. The new order is
  saved on drop and doesn't jump back on the next refresh; archived projects
  are not reordered, and an unarchived project goes to the end of the list.
  MCP `list_projects` returns projects in the same order (new projects last,
  archived ones after the active ones with `include_archived`), and
  cross-project task lists follow it too.

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
  Dropped, then by board order: projects in sidebar order, then each
  project's own task order. On a real database a project listing shrank
  from 35,378 to 1,500 characters and from 234,725 to 3,959.
- Sidebar project rows show how much is left instead of a bare total: the
  number is the project's open tasks (todo, in progress, waiting), and a thin
  bar under the name fills with done out of the tasks still counted. Dropped
  tasks count as neither left nor done. A clay dot before the number means
  tasks in the project are waiting on you. Hover the number, bar or dot for
  the exact counts. A project with no tasks shows `0` and an empty bar. The
  counts come from the task list the app already loads on each refresh,
  instead of loading every task of every project again on each redraw.
- Reopening a done task (back to Todo or In Progress) now clears its
  `completed_at`, so it no longer counts as completed in the activity stats.
  Marking an already-done task done again keeps the original `completed_at`.
- MCP `update_task` now tells agents to log progress with `add_note` instead
  of appending to the task's detail.
- MCP boolean arguments (`copy`, `include_archived`) accept only `true` or
  `false`; a number such as `1` is now an error instead of being read as true.

### Fixed

- An MCP `*_code` argument that matches no task or project (e.g.
  `parent_code: "ZZZ-9"`) now fails with "not found: task ZZZ-9" instead of
  "missing or invalid argument". In the bulk tools' `codes` arrays an unknown
  code is now the same error instead of being skipped.
- MCP `create_task`, `update_task` and `bulk_update_tasks` reject an unknown
  `status` (e.g. `"waitng"`) instead of silently creating a todo or leaving
  the status unchanged.
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
- Bulk changes are all or nothing: `bulk_update_tasks` (including `add_tags`)
  and `bulk_move_tasks` (move or copy) check and write every task in one
  transaction, so a bad or missing task, or an archived target, leaves the
  whole batch unchanged instead of half-applied. An `add_tags` that adds
  nothing new no longer marks the task updated. The app's bulk Status, Add
  Tags, Move to and Copy to use the same writes, and its single-task Move to,
  Copy to and Duplicate now show the error instead of a success toast when
  the write fails. Like a single task, a batch marked Done still goes through
  when a recurring task's next occurrence can't be created (the occurrence is
  skipped).
- Every status change now re-reads the task inside its write transaction, so
  a status change racing another process's write logs the status it actually
  replaced. Leaving Waiting no longer adds a separate "waiting on → (empty)"
  history row; the status row already says it.
- The task detail pane no longer overwrites changes an agent made while the
  task was open: it saves only the fields you edited, and fields you have not
  touched refresh from the database. Selecting a blocked task no longer raises
  the "Task is blocked" prompt (whose Cancel could write the previous task's
  status onto it).
- Status data is repaired each time the app or MCP server opens the database,
  touching only rows that need it, including rows written by an older
  QuestBits build still running against the same file: done and in-progress tasks missing
  `completed_at` / `started_at` get them back from the task's status history,
  falling back to its last-updated time, and waiting tasks get
  `waiting_since` the same way; a `completed_at` left on a task that is not
  done, and waiting fields left on a task that is not waiting, are cleared.
- Creating projects with the same name from the app and an agent at the same
  moment can no longer give two projects the same code.

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

[Unreleased]: https://github.com/90n9/quest-bits/compare/v1.3.0...HEAD
[1.3.0]: https://github.com/90n9/quest-bits/compare/v1.2.3...v1.3.0
[1.2.3]: https://github.com/90n9/quest-bits/compare/v1.2.2...v1.2.3
[1.2.2]: https://github.com/90n9/quest-bits/compare/v1.2.1...v1.2.2
[1.2.1]: https://github.com/90n9/quest-bits/compare/v1.2.0...v1.2.1
[1.2.0]: https://github.com/90n9/quest-bits/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/90n9/quest-bits/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/90n9/quest-bits/releases/tag/v1.0.0
