# QuestBits

A native macOS todo-list app with a built-in Pomodoro focus timer — and a bundled
MCP server so **Claude Code** can create, edit, and update your tasks for you.

- **Projects → Tasks.** Group work into projects; each task has a title, detail
  notes, an optional link, and a progress status (Todo / In Progress / Done).
- **Global Pomodoro timer.** One focus timer for the whole session (25/5/15,
  configurable). Live countdown in the menu bar. Daily stats: pomodoros completed
  + total focus minutes.
- **Claude Code integration.** Ask Claude to add/edit/delete tasks or update
  progress; the open app reflects changes within ~1.5 s.
- **Tiny & native.** ~860 KB app, ~450 KB DMG. Pure Swift, no Electron/Node.

---

## Install

1. Open `build/QuestBits.dmg` and drag **QuestBits** into Applications.
2. First open (unsigned build, no Apple Developer cert): **right-click the app → Open**,
   then confirm. macOS shows a one-time "unidentified developer" prompt. On the
   machine that built it, there's no prompt.
3. On first launch the app registers its MCP server into `~/.claude.json`
   automatically (under `mcpServers.quest-bits`).

### "QuestBits is damaged and can't be opened"

QuestBits is not notarized by Apple (no Apple Developer certificate), so
Gatekeeper quarantines the downloaded app and — on recent macOS versions — may
refuse to open it at all, claiming it is "damaged". The app is fine; clear the
quarantine flag once:

```bash
xattr -dr com.apple.quarantine /Applications/QuestBits.app
```

Then open the app normally. Alternatively: try to open the app once, then go to
**System Settings → Privacy & Security**, scroll down, and click **Open Anyway**.

You only need this on the first launch of a downloaded build — auto-updates and
rebuilds on the same machine don't re-trigger it.

---

## Using the app

### Create a project
- Sidebar shows a **+** in the toolbar (top), or a **New Project** button when empty.
- Click → type a name → Enter.

### Create a task
- Select a project, then click **+** in the task column's toolbar (or **New Task**
  when empty).
- Type a title → Enter.

### Work with a task
- **Status:** click the circle on the left of a task to cycle
  Todo → In Progress → Done.
- **Edit:** click a task → the right panel edits title, status, link, and detail.
  Save from the **Save** button (top-right toolbar) or ⌘S.
- **Reorder:** drag tasks up/down within a project.
- **Right-click a task:** Copy Code, Duplicate, Move to ▸ <project>, Copy to ▸
  <project>, Delete.

### Short codes
Every project has a short code (e.g. `GEN`) and every task one too (e.g. `GEN-3`),
shown as a pill in the lists and in the task detail. Codes are stable handles for
referring to items — especially when talking to Claude Code ("mark GEN-3 done").
Copy a code via the **Copy code** button in the detail panel, or right-click →
**Copy Code**.

### Keyboard shortcuts
| Shortcut | Action |
|----------|--------|
| ⌘N | New task |
| ⇧⌘N | New project |
| ⌘S | Save task detail |
| ⌘D | Duplicate selected task |
| ⌘⌫ | Delete selected task |
| ⌘1 / ⌘2 / ⌘3 | Set status Todo / In Progress / Done |
| ⌘↩ | Start / Pause timer |
| ⌘K | Skip phase |
| ⌘. | Stop timer |

(All also appear in the **Task** and **Timer** menus.)

### Pomodoro
- Bottom bar: **Start / Pause / Skip / Stop**, the current phase, and the countdown.
- The menu-bar icon mirrors the countdown (🍅 focus, ☕️ break) and stays running
  after you close the window. Click it to bring the window back.
- Durations: **Settings** (⌘,) — focus, short break, long break, and rounds before
  a long break.
- Each completed focus block is logged; the bottom-right shows today's pomodoro
  count and total focus minutes.

---

## Using it from Claude Code

The app's MCP server registers automatically on first launch. **Start a fresh
Claude Code session** (a session already running before registration won't see it),
then just ask in natural language:

```
list my todo projects
add a task "Fix login bug" to the General project and mark it in progress
mark "Review PR" as done
what tasks are still todo?
how many pomodoros did I do today?
```

Claude writes to the shared database; the open app updates within ~1.5 s.

**Tools exposed:**

| Tool | Purpose |
|------|---------|
| `list_projects`, `create_project`, `rename_project`, `delete_project` | manage projects |
| `list_tasks`, `get_task` | read tasks (filter/lookup by id **or** code) |
| `create_task` | add a task: `project_id` or `project_code`, `title`, optional `detail`, `link`, `status` |
| `update_task` | edit any field / update `status`; pass `link:null` to clear the link |
| `duplicate_task` | clone a task (same project, or into another via `to_project_code`) |
| `move_task` | transfer a task to another project |
| `delete_task` | remove a task |
| `daily_stats` | today's completed pomodoros + total focus minutes |

Status values: `todo`, `in_progress`, `done`.

**Codes everywhere:** any tool that takes an `id` also accepts a `code` (task code
like `GEN-3`, project code like `GEN`). So you can say "move GEN-3 to DFC" and
Claude calls `move_task {code:"GEN-3", to_project_code:"DFC"}`.

**Manual smoke test** (no restart needed):

```bash
MCP="build/QuestBits.app/Contents/Resources/mcp-server/todo-mcp"
echo '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_projects","arguments":{}}}' | "$MCP"
```

---

## Architecture

Two processes share one SQLite database (WAL mode) so the app and Claude Code can
read/write at the same time without clobbering each other:

```
SwiftUI app  ─┐                          ┌─ MCP server (todo-mcp)
(window +     ├─ read/write + file-watch ─┤   spawned by Claude Code
 menu bar)   ─┘                          └─ read/write
                          │
            ~/Library/Application Support/TodoApp/db.sqlite
```

- **App** — SwiftUI: projects sidebar → task list → task detail, plus a menu-bar
  countdown. Polls the DB file every 1.5 s and reloads on external (MCP) writes.
- **MCP server** — a single Swift binary inside the bundle at
  `QuestBits.app/Contents/Resources/mcp-server/todo-mcp`. Speaks JSON-RPC 2.0 over
  stdio; no external SDK.
- **Pomodoro** — global timer; completed focus sessions logged to the DB for
  daily stats.

```
quest-bits/
├── Sources/
│   ├── TodoCore/    Models + SQLite store (shared by both binaries)
│   ├── TodoApp/     SwiftUI app, menu bar, pomodoro engine, file-watch, MCP self-register
│   └── TodoMCP/     MCP JSON-RPC stdio server
├── Scripts/         build-app.sh, make-dmg.sh
└── build/           QuestBits.app, QuestBits.dmg
```

---

## Build from source

No Xcode needed — built directly with `swiftc` (Swift 6.3, macOS 14+).

```bash
Scripts/build-app.sh             # dev build → "build/QuestBits Dev.app" (default locally)
FLAVOR=prod Scripts/build-app.sh # production build → build/QuestBits.app
Scripts/make-dmg.sh              # package build/QuestBits.app into build/QuestBits.dmg
```

Local builds default to a separate **QuestBits Dev** app so experiments are safe:
own bundle id, own database (`~/Library/Application Support/TodoAppDev/`), own MCP
registration (`quest-bits-dev`), and an orange **DEV** badge in the sidebar footer. It
coexists with the production app without touching its data.

---

## Notes & limitations

- **No Apple Developer certificate** — fine for personal/local use. Sharing to
  others incurs a one-time right-click-Open. Ad-hoc signing keeps a stable code
  identity so notification permissions and MCP trust don't re-prompt every rebuild.
- **Live reload is 1.5 s polling**, not FSEvents — simple and reliable for WAL,
  with a slight lag.
- **DB override** for testing: set `TODO_DB_PATH` when running `todo-mcp`.
- **Data location:** `~/Library/Application Support/TodoApp/db.sqlite`
  (plus `-wal` / `-shm` sidecars).
