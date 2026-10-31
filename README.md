# QuestBits

A native macOS todo-list app with a bundled MCP server, command-line tool and
Claude Code hooks, so **Claude Code** agents can pick up, work on and report on
your tasks while you keep the overview.

- **Projects → Tasks.** Group work into projects; each task has a title, detail,
  typed links, a working branch, relations, an optional milestone, and a status
  (Todo / In Progress / Waiting / Done / Dropped).
- **Claude Code integration.** Ask Claude to add/edit/delete tasks or update
  progress; the open app reflects changes within ~1.5 s. Agents claim tasks,
  leave you questions and keep working, and record their decisions.
- **One place for what needs you.** Waiting on you, Activity and Decisions pages
  in the sidebar; the menu-bar item shows ✋ waiting-on-you and ⚡ working counts.
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
| ⌘4 / ⌘5 / ⌘6 | Set status Waiting on me / Waiting on external / Dropped |

(All also appear in the **Task** menu; change them in **Settings**.)

### Project pages
A project's page has tabs: **Tasks**, **Detail** (counts, milestones, wiki,
questions, agent sessions, repo folder, gate rules, guide), **Wiki** (the
project's decisions and notes, searchable), **Guide** and **Questions**.

### Sidebar pages
- **Waiting on you** — sessions waiting at a terminal, open questions (gate
  approvals included) and tasks waiting on you, across projects, each with its
  quick action.
- **Activity** — every task change, note and wiki edit, newest first, with who
  made it (you, an agent, a hook, the CLI or an import).
- **Decisions** — decisions agents made on their own. Mark them as seen, or
  **Disagree** with a reason: the agent gets it as an answered question.

### Menu bar
The menu-bar item shows ✋ N (things waiting on you) and ⚡ M (tasks being
worked on); zero counts are hidden. Its menu lists the first few of each and
brings the window back. With **Settings → Notifications → Notify me when an
agent needs me**, a new question, a task set waiting on you or a session waiting
at its terminal also posts a notification.

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
how many tasks did I finish today?
```

Claude writes to the shared database; the open app updates within ~1.5 s.

**Tools exposed:**

| Tool | Purpose |
|------|---------|
| `list_projects`, `create_project`, `rename_project`, `delete_project` | manage projects |
| `update_project`, `archive_project`, `unarchive_project` | edit a project (code, description, `repo_path`), archive it |
| `find_project` | which project a folder belongs to (by its repo folder) |
| `list_tasks`, `get_task` | read tasks (filter/lookup by id **or** code; `sort: "board"` for the saved order) |
| `create_task` | add a task: `project_id` or `project_code`, `title`, optional `detail`, `link`, `branch`, `milestone`, `status` |
| `update_task` | edit any field / update `status`; pass `link:null` to clear the link |
| `duplicate_task` | clone a task (same project, or into another via `to_project_code`) |
| `move_task` | transfer a task to another project |
| `delete_task` | remove a task |
| `bulk_update_tasks`, `bulk_move_tasks`, `bulk_delete_tasks` | the same on many tasks, all or nothing |
| `reorder_tasks` | set the task order the list and board show |
| `next_task`, `claim_task`, `release_task`, `heartbeat` | take the next ready task for a session, so parallel sessions never pick the same one |
| `add_link`, `remove_link` | typed links (PR, design, doc, file, branch, other) |
| `add_dependency`, `remove_dependency`, `add_relation`, `remove_relation` | blocked by / blocks / relates / duplicates |
| `list_milestones`, `create_milestone`, `update_milestone`, `delete_milestone` | a project's stages |
| `list_pages`, `get_page`, `create_page`, `update_page`, `delete_page`, `search_pages`, `get_page_history` | the project wiki |
| `daily_stats` | tasks and subtasks completed today |
| `add_note`, `search_notes`, `get_note_history` | add a note (progress, decision, summary, review…), search notes, see a note's earlier versions |
| `decisions` | decisions recorded as notes, with the user's disagreements |
| `get_task_history` | a task's changes and where each came from |
| `inbox` | tasks waiting on you, with their open questions |
| `ask_user`, `get_answers`, `resume_question`, `cancel_question`, `wait_for_answers` | the ask loop (below) |
| `list_gate_rules`, `add_gate_rule` | the gate's rules for a project (below) |
| `get_guide`, `update_guide`, `get_guide_history` | the agent guide: built-in rules, yours, the project's |
| `list_templates`, `create_template`, `new_task_from_template` | task templates |

Status values: `todo`, `in_progress`, `waiting`, `done`, `dropped`.

**Ask loop: start a long job and walk away.** When an agent needs you to
decide, it leaves a question in QuestBits (`ask_user`) and keeps working on
something else. Answer it on the **Questions** page when you have time: pick
an option (1–4), type an answer, or approve. The agent checks `get_answers`
before new work and picks up each answer with `resume_question`. With nothing
left to do, it waits in `wait_for_answers`, which uses no tokens while it
waits. The MCP server sends Claude Code these rules itself. The Mac must stay
awake: QuestBits prevents idle sleep while it waits, but a closed lid still
sleeps.

If a long wait does not suit your setup, run the agent in a self-paced loop
instead, for example:

```
/loop Check QuestBits get_answers. For each answer, resume_question and continue
that task. Then keep working on open tasks; ask_user when you need me to decide.
Stop when nothing is left and no questions are open.
```

**Codes everywhere:** any tool that takes an `id` also accepts a `code` (task code
like `GEN-3`, project code like `GEN`). So you can say "move GEN-3 to DFC" and
Claude calls `move_task {code:"GEN-3", to_project_code:"DFC"}`.

### Command line: `questbits`

The app bundles a CLI at `QuestBits.app/Contents/Resources/cli/questbits`.
**Settings → Command Line → Install Link** puts it on your path as
`~/.local/bin/questbits` (`questbits-dev` for the dev build); it never replaces a
file there, and asks before replacing another link.

```
questbits brief [--path <dir>] [--next <n>]   # start-of-session summary of a folder's project
questbits list [<project>] [--all]            # tasks
questbits show <code> [--format md|json]      # one task
questbits export [--project <code>]...        # every project to markdown/JSON
questbits import --config <mapping.json> --dry-run   # bring in work tracked elsewhere
```

`import` reads a mapping you write and review. `--dry-run` never writes the
database: it plans against a copy and writes a plan and a summary of every item.
`--apply --plan <plan.json>` then writes only the reviewed plan (backing up
first), and a rerun adds nothing twice. Like `todo-mcp`, the CLI honours
`TODO_DB_PATH`.

### Claude Code hooks

**Settings → Claude Code Hooks** installs QuestBits' hooks into
`~/.claude/settings.json` (Install, Update Hooks when the app has newer ones,
Uninstall). They are opt-in: nothing is installed at launch. Install keeps every
other hook and setting, copies the old file to
`settings.json.questbits-<flavor>-backup-<timestamp>` first, and writes
atomically. Each command runs the bundled CLI by its full path and ends with
`# questbits-hook:prod` (or `:dev`), so the production and dev apps each manage
only their own entries. After moving the app, click **Update Hooks**.

The hooks act only in a folder that belongs to a project (its repo folder):

| Hook | What it does |
|------|--------------|
| SessionStart (startup, resume, clear, fork) | records the session and gives it a brief: the project's guide, in progress, waiting on you, next tasks, milestones, latest decisions |
| SessionStart (compact) | after a compaction, gives the session its own claimed tasks, notes, decisions and questions back |
| UserPromptSubmit, Stop, SessionEnd | track whether the session is working, waiting or ended (no prompt or reply text is stored) |
| PreToolUse (Bash and MCP calls) | **the gate**: a risky call is not run; it becomes an approval question |
| Notification | a session waiting at its terminal (permission, question, idle) shows in Waiting on you |

**The gate.** Defaults cover git push, gh release, gh pr merge / create, a
recursive delete outside the repo folder, commands that name the QuestBits
database, and MCP tools that send Slack or Gmail messages; add a project's own
rules in the Gate section of its Detail tab (or MCP `add_gate_rule`). A denied
call becomes an approve question on the session's claimed task (else the
project's "Agent approvals" task). The agent keeps working; once you approve,
the exact same call is allowed once, in the same session, within 24 hours.
Secrets in the call are removed before anything is stored.

**Manual smoke test** (no restart needed):

```bash
MCP="build/QuestBits.app/Contents/Resources/mcp-server/todo-mcp"
echo '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_projects","arguments":{}}}' | "$MCP"
```

---

## Architecture

Three binaries share one SQLite database (WAL mode) so the app, Claude Code and
its hooks can read/write at the same time without clobbering each other:

```
SwiftUI app  ─┐                          ┌─ MCP server (todo-mcp)
(window +     ├─ read/write + polling   ─┤   spawned by Claude Code
 menu bar)   ─┘                          ├─ CLI (questbits), run by
                          │              │   Claude Code hooks or by you
            ~/Library/Application Support/TodoApp/db.sqlite
```

- **App** — SwiftUI: projects sidebar → task list → task detail, plus a menu-bar
  item with counts. Polls the DB file every 1.5 s and reloads on external writes.
- **MCP server** — a single Swift binary inside the bundle at
  `QuestBits.app/Contents/Resources/mcp-server/todo-mcp`. Speaks JSON-RPC 2.0 over
  stdio; no external SDK.
- **CLI** — `QuestBits.app/Contents/Resources/cli/questbits`: brief, list, show,
  export, import, and the `hook` subcommands Claude Code's hooks run.

```
quest-bits/
├── Sources/
│   ├── TodoCore/    Models + SQLite store (shared by all three binaries)
│   ├── TodoApp/     SwiftUI app, menu bar, polling, MCP self-register, hook installer
│   ├── TodoMCP/     MCP JSON-RPC stdio server
│   └── TodoCLI/     questbits CLI and hook commands
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
- **DB override** for testing: set `TODO_DB_PATH` when running `todo-mcp` or
  `questbits`. Only those read it; the app always opens the data location below.
- **Data location:** `~/Library/Application Support/TodoApp/db.sqlite`
  (plus `-wal` / `-shm` sidecars).
