import Foundation

extension MCPServer {
    /// MCP tool schemas advertised via tools/list.
    static var toolDefinitions: [[String: Any]] {
        func obj(_ props: [String: Any], required: [String] = []) -> [String: Any] {
            ["type": "object", "properties": props, "required": required]
        }
        let str: [String: Any] = ["type": "string"]
        let int: [String: Any] = ["type": "integer"]
        let statusEnum: [String: Any] = ["type": "string", "enum": TaskStatus.allCases.map(\.rawValue)]
        let waitingOnEnum: [String: Any] = ["type": "string", "enum": WaitingOn.allCases.map(\.rawValue), "description": "who a waiting task waits on: user (the human must decide/act) or external (a third party). Required when setting status waiting, unless the task is already waiting."]
        let waitingReasonStr: [String: Any] = ["type": "string", "description": "why the task is waiting (optional); null clears it"]
        let priorityEnum: [String: Any] = ["type": "string", "enum": ["none", "low", "medium", "high"]]
        let dateStr: [String: Any] = ["type": "string", "description": "ISO-8601 or yyyy-MM-dd; null to clear"]
        let tagsArr: [String: Any] = ["type": "array", "items": str]
        let recurrenceEnum: [String: Any] = ["type": "string", "enum": ["daily", "weekly", "monthly"], "description": "repeat interval; null to clear. On completion, spawns the next occurrence with the due date advanced."]
        let estimateInt: [String: Any] = ["type": "integer", "description": "planned effort in minutes (0 = unset). Compared against actual tracked effort_minutes."]
        let noteKindEnum: [String: Any] = ["type": "string", "enum": NoteKind.writable.map(\.rawValue)]
        let sessionStr: [String: Any] = ["type": "string", "description": "optional label for your agent session, recorded with what you write; questions asked with one can be filtered by it"]
        let parentStr: [String: Any] = ["type": ["string", "null"], "description": "code of a top-level task in the same project to make this a subtask of; null makes it a top-level task again"]
        let parentInt: [String: Any] = ["type": ["integer", "null"], "description": "id form of parent_code"]
        let guideScope: [String: Any] = ["global": ["type": "boolean", "description": "true: the user's guide for every project"] as [String: Any],
                                         "project_id": int, "project_code": str]
        let repoPathStr: [String: Any] = ["type": ["string", "null"], "description": "absolute folder (or starting with ~) of the project's repo or workspace; stored with ~ expanded"]
        let questionFilter: [String: Any] = ["project_id": int, "project_code": str,
                                             "session": ["type": "string", "description": "only questions asked with this session label"] as [String: Any]]

        return [
            ["name": "list_projects",
             "description": "List projects in the user's sidebar order (new projects last). Each has a short `code` (e.g. GEN) usable as a handle. Archived projects are left out unless `include_archived` is true; they carry `archived_at` and come after the active ones.",
             "inputSchema": obj(["include_archived": ["type": "boolean", "description": "also list archived projects (default false)"] as [String: Any]])],

            ["name": "create_project",
             "description": "Create a new project. Optional `description` gives context. A short code is auto-generated and returned, or give `code` (1–10 letters A–Z or digits, starting with a letter, not another project's). Optional `repo_path` is the folder its work lives in (see find_project). Optional `guide_template` starts the project's guide (see get_guide) from a template for that kind of project, for the user to edit; pass it only when the user picked the kind.",
             "inputSchema": obj(["name": str, "description": str, "code": str, "repo_path": repoPathStr,
                                 "guide_template": ["type": "string", "enum": GuideTemplate.allCases.map(\.rawValue),
                                                    "description": "web_app, app, research or animation; omit for an empty guide"] as [String: Any],
                                 "session": sessionStr], required: ["name"])],

            ["name": "rename_project",
             "description": "Rename a project, identified by `id` or `code`.",
             "inputSchema": obj(["id": int, "code": str, "name": str], required: ["name"])],

            ["name": "update_project",
             "description": "Update a project's `name`, `description`, code and/or repo folder (identify it by `id` or `code`; `new_code` sets the code: 1–10 letters A–Z or digits, starting with a letter, not another project's). Its tasks keep their codes; new tasks take the new one. `repo_path` sets the folder its work lives in (see find_project); null or \"\" removes it.",
             "inputSchema": obj(["id": int, "code": str, "name": str, "description": str, "new_code": str,
                                 "repo_path": repoPathStr])],

            ["name": "find_project",
             "description": "Which project a folder belongs to, e.g. your working directory: the active project whose `repo_path` is that folder or contains it (a subfolder of a repo matches). When folders nest, such as a workspace and a repo inside it, the deepest one wins. Folders compare as the file system sees them: ~ expanded, symlinks resolved, trailing slashes ignored, whole folder names only (/x/app does not contain /x/app-2). Archived projects and projects without a repo_path never match. Returns {path (resolved), project} where project is null or the project (as in list_projects) plus counts of its tasks: open, in_progress, waiting_on_user.",
             "inputSchema": obj(["path": ["type": "string", "description": "an absolute folder path (or starting with ~)"] as [String: Any]],
                                required: ["path"])],

            ["name": "archive_project",
             "description": "Archive a finished project (identify by `id` or `code`). Its tasks are kept, and it stays usable by id/code, but list_projects and list_tasks without a project leave it out. Its code stays reserved. Returns the project, with `open_tasks` when some are still open. Idempotent.",
             "inputSchema": obj(["id": int, "code": str])],

            ["name": "unarchive_project",
             "description": "Unarchive a project (identify by `id` or `code`), making it active again. Returns the project. Idempotent.",
             "inputSchema": obj(["id": int, "code": str])],

            ["name": "delete_project",
             "description": "Delete a project and all its tasks. Identify by `id` or `code`.",
             "inputSchema": obj(["id": int, "code": str])],

            ["name": "list_tasks",
             "description": "List tasks. By default only open tasks (todo, in_progress, waiting) in the compact view. Without `project_id`/`project_code` or `parent_id`/`parent_code`, tasks of archived projects are left out unless `include_archived` is true. Filters (all optional, combined with AND): `project_id`/`project_code`, `status` (a status, an array of statuses, or \"all\" to include done and dropped), `tag` (one whole tag; case-insensitive for ASCII letters only), `parent_id`/`parent_code` (subtasks of that task). Sorted in_progress, waiting, todo, done, dropped, then by board order (projects in sidebar order, then each project's own task order). With `sort` \"board\" the status grouping is dropped and you get the saved order the app shows (set with reorder_tasks): each top-level task in order, followed by its own subtasks in order; use it to read back an order. The compact view gives code, title, status, and only when set: priority, parent, blocked_by (open dependencies blocking it), tags, due_date, waiting_on. To read detail and the other fields use get_task, or pass view \"full\" for get_task's shape. list_tasks never includes notes; get_task does.",
             "inputSchema": obj([
                "project_id": int, "project_code": str,
                "status": ["anyOf": [
                    ["type": "string", "enum": TaskStatus.allCases.map(\.rawValue) + ["all"]],
                    ["type": "array", "items": statusEnum, "minItems": 1]
                ], "description": "status or statuses to include; \"all\" = every status. Default: open (todo, in_progress, waiting)."] as [String: Any],
                "tag": str, "parent_id": int, "parent_code": str,
                "include_archived": ["type": "boolean", "description": "with no project or parent given, also list tasks of archived projects (default false)"] as [String: Any],
                "view": ["type": "string", "enum": ["compact", "full"], "description": "compact (default) or full (same fields as get_task, without notes)"] as [String: Any],
                "sort": ["type": "string", "enum": TaskSort.allCases.map(\.rawValue), "description": "status (default): status groups, then board order; board: the saved order only, status ignored"] as [String: Any]
             ])],

            ["name": "get_task",
             "description": "Get a single task by `id` or `code` (e.g. GEN-3). Other tasks are referenced by code (`parent`, `depends_on`). Fields that are empty or default are omitted: no priority, tags, link, due_date, detail, effort or estimate; `blocked` appears only when true; `waiting_on`/`waiting_reason`/`waiting_since` only on waiting tasks. Includes the latest notes (see add_note) newest first as `notes` [{id, ts, text, kind, author, session, edited_at, question_id}] (kind omitted when \"note\"; author user|agent, absent on notes from before 1.4.0; no `notes` key when there are none), and `more_notes: true` when older notes were left out. Questions still open or answered-but-not-resumed (see ask_user) are in `questions`. `detail` is markdown; images the user attached in the app are linked as `attachments/<file>`, and `attachments` lists those files' absolute paths so you can open them.",
             "inputSchema": obj([
                "id": int, "code": str,
                "notes_limit": ["type": "integer", "minimum": 0, "maximum": 100, "description": "how many latest notes to include (default 5, 0 = none, max 100)"] as [String: Any]
             ])],

            ["name": "create_task",
             "description": "Create a task under a project (give `project_id` or `project_code`). detail, link, priority, due_date, tags, recurrence optional; status defaults to todo. status waiting needs `waiting_on` (user|external) and takes an optional `waiting_reason`. Pass `parent_id` or `parent_code` to make it a subtask of another task (one level of nesting). The project (given or the parent's) must not be archived. Returns the task with its new code (same shape as get_task, without notes).",
             "inputSchema": obj([
                "project_id": int, "project_code": str, "title": str, "detail": str, "link": str,
                "status": statusEnum, "waiting_on": waitingOnEnum, "waiting_reason": waitingReasonStr,
                "priority": priorityEnum, "due_date": dateStr, "tags": tagsArr, "recurrence": recurrenceEnum,
                "estimate_minutes": estimateInt, "parent_id": int, "parent_code": str
             ], required: ["title"])],

            ["name": "update_task",
             "description": "Update a task by `id` or `code`. Only provided fields change. Pass link:null, due_date:null, or recurrence:null to clear them. Use this to update progress status, priority, due date, tags, recurrence, or estimate_minutes (0 clears the estimate). Priority does not change where a task sits; reorder_tasks does that. status waiting needs `waiting_on` (user|external) unless the task is already waiting; `waiting_reason` is optional. Moving to any other status clears waiting_on/waiting_reason, and setting them on a task that is not (or will not be) waiting is an error. status dropped abandons a task but keeps it and its history: it closes like done (dependents unblock) but is not a completion (no completed_at, not in daily_stats, a recurring task spawns no next occurrence). To log progress use add_note; do not append to detail. Optional `note` adds a note in the same write, linked to the status change: its `note_kind` defaults to summary when the update closes the task (done/dropped) and to note otherwise. A summary is never required to close a task. `parent_code`/`parent_id` moves the task under a top-level task of the same project (one level of nesting: a task with subtasks, or a recurring one, cannot become a subtask); null makes it top-level again. Returns the updated task (same shape as get_task, without notes; omitted fields are empty/default).",
             "inputSchema": obj([
                "id": int, "code": str, "title": str, "detail": str, "link": str,
                "status": statusEnum, "waiting_on": waitingOnEnum, "waiting_reason": waitingReasonStr,
                "priority": priorityEnum, "due_date": dateStr, "tags": tagsArr, "recurrence": recurrenceEnum,
                "estimate_minutes": estimateInt, "parent_code": parentStr, "parent_id": parentInt,
                "note": ["type": "string", "description": "optional note to add with this update, e.g. a closing summary: what was done, files/PRs, what is left"] as [String: Any],
                "note_kind": noteKindEnum, "session": sessionStr
             ])],

            ["name": "delete_task",
             "description": "Delete a task by `id` or `code`.",
             "inputSchema": obj(["id": int, "code": str])],

            ["name": "duplicate_task",
             "description": "Clone a task (by `id` or `code`); the copy gets a fresh code. Without a target (or with its own project) it duplicates in the same project for reuse: the copy starts as a todo, and status, started/completed times and waiting fields are not copied. With another project as `to_project_id`/`to_project_code` it copies the task there as is (original kept): status, started/completed times and waiting fields carry over. A target project must not be archived.",
             "inputSchema": obj(["id": int, "code": str, "to_project_id": int, "to_project_code": str])],

            ["name": "move_task",
             "description": "Move (transfer) a task (by `id` or `code`) to another project (`to_project_id` or `to_project_code`), which must not be archived.",
             "inputSchema": obj(["id": int, "code": str, "to_project_id": int, "to_project_code": str])],

            ["name": "reorder_tasks",
             "description": "Set the order of tasks in a project: the order the app's list and board show, saved for good. Give the tasks in the order you want as `codes` or `ids` (not both). They must be siblings: top-level tasks of one project, or subtasks of one parent (a subtask never leaves its parent, and a parent's subtasks move with it). They go to the top of their siblings in that order (`place` \"bottom\": to the bottom); siblings you leave out keep their order below (or above) them. Closed tasks can be ordered too, though the app lists them in its Done section. Nothing else changes: not status, priority, parent, project or updated_at. Priority does not move a task (update_task priority only sets the field); order is set only here. All or nothing: an unknown task, a task given twice, or tasks of another project or parent leave the order as it was. Returns {project, parent (when subtasks), tasks: the siblings in their new order, compact view}; list_tasks with sort \"board\" reads it back. Example, before a UAT: reorder_tasks {codes: [\"WGS-4\", \"WGS-7\", \"WGS-2\"]} puts the work due before UAT first, then reorder_tasks {codes: [\"WGS-9\", \"WGS-11\"], place: \"bottom\"} sends the tasks waiting on the customer to the bottom.",
             "inputSchema": obj([
                "codes": ["type": "array", "items": str, "minItems": 1, "description": "task codes in the order you want"] as [String: Any],
                "ids": ["type": "array", "items": int, "minItems": 1, "description": "id form of codes"] as [String: Any],
                "place": ["type": "string", "enum": TaskPlacement.allCases.map(\.rawValue), "description": "top (default) or bottom of their siblings"] as [String: Any]
             ])],

            ["name": "bulk_update_tasks",
             "description": "Update many tasks at once (give `ids` and/or `codes` arrays). Applies any of status, waiting_on, waiting_reason, priority, due_date, add_tags, parent_code/parent_id to all. add_tags merges (keeps existing). Waiting and parent rules match update_task. All or nothing: if any task fails (e.g. the waiting rule), no task changes.",
             "inputSchema": obj([
                "ids": ["type": "array", "items": int], "codes": ["type": "array", "items": str],
                "status": statusEnum, "waiting_on": waitingOnEnum, "waiting_reason": waitingReasonStr,
                "priority": priorityEnum, "due_date": dateStr, "add_tags": tagsArr,
                "parent_code": parentStr, "parent_id": parentInt
             ])],

            ["name": "bulk_move_tasks",
             "description": "Move (or copy, if copy=true) many tasks to another project. Give `ids`/`codes` and `to_project_id`/`to_project_code`. A copy to another project keeps each task's status, started/completed times and waiting fields (same rule as duplicate_task). The target project must not be archived. All or nothing: if any task is unknown or the target is archived, no task moves or is copied.",
             "inputSchema": obj([
                "ids": ["type": "array", "items": int], "codes": ["type": "array", "items": str],
                "to_project_id": int, "to_project_code": str, "copy": ["type": "boolean"]
             ])],

            ["name": "bulk_delete_tasks",
             "description": "Delete many tasks at once (with their subtasks). Give `ids` and/or `codes` arrays. All or nothing: if any task is unknown, no task is deleted. Returns how many tasks were deleted, subtasks included.",
             "inputSchema": obj([
                "ids": ["type": "array", "items": int], "codes": ["type": "array", "items": str]
             ])],

            ["name": "inbox",
             "description": "Your inbox: tasks an agent is waiting on you to answer — status waiting with waiting_on user — across all projects that are not archived. Check it to see what needs your decision or action. Longest waiting first. Each item: code, title, project (project code), waiting_since (when it entered waiting), waiting_reason when set, and `questions` [{id, question}] when an agent asked something open on it (ask_user). With `include_external` true, tasks waiting on a third party are included too, and each item has waiting_on. Returns [] when nothing is waiting.",
             "inputSchema": obj(["include_external": ["type": "boolean", "description": "also include tasks waiting on external (default false)"] as [String: Any]])],

            ["name": "add_note",
             "description": "Append a note (comment) to a task (`id` or `code`). Use this instead of appending to the task's detail, which stays the spec. Insert only: you cannot edit or delete a note, and concurrent sessions never lose each other's notes (the user may edit their own notes in the app; get_note_history shows earlier versions). `kind`: note (default), progress (an update while working), decision (what you decided, why, and the options not taken — always record decisions you made yourself), summary (closing: what was done, files/PRs, what is left; optional), review (review or test results). Notes are recorded as written by the agent. Bumps the task's updated_at. Notes are newest first in get_task, not in list_tasks; they stay with the task when it moves, are not copied by duplicate_task, and are deleted with the task. Returns {note_id, task, ts} plus kind when not note.",
             "inputSchema": obj([
                "id": int, "code": str, "text": str, "kind": noteKindEnum, "session": sessionStr
             ], required: ["text"])],

            ["name": "search_notes",
             "description": "Search notes across tasks for text (`query`, case-insensitive substring), e.g. \"how did we decide X\". Optional `project_id`/`project_code`, `kind` (e.g. decision), and `limit` (default 20, max 100). Archived projects are searched too. Newest first; each hit is a note (as in get_task) plus task, title and project.",
             "inputSchema": obj([
                "query": str, "project_id": int, "project_code": str,
                "kind": ["type": "string", "enum": NoteKind.allCases.map(\.rawValue)] as [String: Any],
                "limit": ["type": "integer", "minimum": 1, "maximum": 100] as [String: Any]
             ], required: ["query"])],

            ["name": "get_note_history",
             "description": "A note (`note_id`, the `id` in get_task notes) with `edits`: its earlier texts, newest first, each with when it was replaced. Only the user edits notes, in the app.",
             "inputSchema": obj(["note_id": int], required: ["note_id"])],

            ["name": "ask_user",
             "description": "Leave a question for the user on a task (`id` or `code`) and keep working on something else — do not end your turn to wait. The user answers in the QuestBits app when convenient. `kind`: choice (default; 2–4 `options`), text (free answer; up to 4 suggested options) or approve (approve or edit a draft given in `context`; no options). Options are strings or {label, note}; `recommended` is the option number (from 1) or label you recommend — give one, with the reason in its note or the context. `context`: short markdown the user needs to decide. By default the question blocks the task: it moves to waiting on the user until every blocking question is answered, then back to todo. `blocks_task` false asks without blocking. Also logs a question note. Returns the question with its `id`. Later: get_answers / wait_for_answers, then resume_question.",
             "inputSchema": obj([
                "id": int, "code": str, "question": str,
                "kind": ["type": "string", "enum": QuestionKind.allCases.map(\.rawValue)] as [String: Any],
                "options": ["type": "array", "maxItems": 4, "items": ["anyOf": [
                    str, obj(["label": str, "note": str], required: ["label"])
                ]] as [String: Any]] as [String: Any],
                "recommended": ["anyOf": [int, str], "description": "option number (from 1) or label"] as [String: Any],
                "context": str,
                "blocks_task": ["type": "boolean", "description": "default true: the task waits on the user until answered"] as [String: Any],
                "session": sessionStr
             ], required: ["question"])],

            ["name": "get_answers",
             "description": "Questions the user has answered that are not resumed yet, oldest first, plus how many are still `open`: {answered: [question...], open: N}. Each answered question has `answer` (and `choice`, the option number, when an option was picked). Call it before starting new work and act on answers first: resume_question, then continue the task. Optional project and session filters.",
             "inputSchema": obj(questionFilter)],

            ["name": "wait_for_answers",
             "description": "Wait until the user answers a question, then return like get_answers. Use it only when you have no other work you can do and questions are still open. Returns at once if an answer is already in or nothing is open; otherwise checks every few seconds, for up to `max_minutes` (default 240, max 1440), and returns {answered: [], open: N} when the time is up — then call it again or stop with a summary. Keeps the Mac awake while waiting (not with the lid closed). Cancelling the call stops it. Optional project and session filters.",
             "inputSchema": obj(questionFilter.merging([
                "max_minutes": ["type": "integer", "minimum": 1, "maximum": 1440] as [String: Any]
             ]) { a, _ in a })],

            ["name": "resume_question",
             "description": "Take an answered question (`id`) back up: marks it resumed, records the answer as a decision note by the user, and moves the task to in_progress (unless it is closed, or another open blocking question still holds it). Returns the question, with `answer`, and task_status. Then act on the answer.",
             "inputSchema": obj(["id": int, "session": sessionStr], required: ["id"])],

            ["name": "cancel_question",
             "description": "Withdraw a question (`id`) that is open or answered but no longer needed, e.g. you found the answer yourself. `reason` says why (recorded as a decision note by the agent). A blocking question releases its task as resume_question does.",
             "inputSchema": obj(["id": int, "reason": str, "session": sessionStr], required: ["id"])],

            ["name": "get_task_history",
             "description": "Get the change history (status changes, etc.) for a task by `id` or `code`, newest first.",
             "inputSchema": obj(["id": int, "code": str])],

            ["name": "add_dependency",
             "description": "Make a task blocked by another. The task (`id`/`code`) stays blocked until the dependency (`depends_on_id`/`depends_on_code`) is closed (done or dropped); a task that is itself closed is never blocked. Rejects self-dependency and cycles.",
             "inputSchema": obj(["id": int, "code": str, "depends_on_id": int, "depends_on_code": str])],

            ["name": "remove_dependency",
             "description": "Remove a blocked-by dependency: task (`id`/`code`) no longer depends on (`depends_on_id`/`depends_on_code`).",
             "inputSchema": obj(["id": int, "code": str, "depends_on_id": int, "depends_on_code": str])],

            ["name": "list_templates",
             "description": "List all reusable task templates. Each has an `id`, `name`, and the preset fields (title, detail, priority, tags, estimate_minutes) applied to tasks spawned from it.",
             "inputSchema": obj([:])],

            ["name": "create_template",
             "description": "Create a reusable task template. `name` is the template's handle; `title` is applied to tasks spawned from it. detail, priority, tags, estimate_minutes optional. Returns the template with its new id.",
             "inputSchema": obj([
                "name": str, "title": str, "detail": str, "priority": priorityEnum,
                "tags": tagsArr, "estimate_minutes": estimateInt
             ], required: ["name", "title"])],

            ["name": "new_task_from_template",
             "description": "Create a real task from a template (`template_id`) into a project (`project_id` or `project_code`, not archived). Copies the template's title, detail, priority, tags, and estimate. Returns the new task with its code.",
             "inputSchema": obj([
                "template_id": int, "project_id": int, "project_code": str
             ], required: ["template_id"])],

            ["name": "get_guide",
             "description": "How to work on the user's tasks, as markdown: QuestBits' built-in rules, then the user's guide for every project, then the project's guide (each later part adds to or tightens the earlier ones). Call it before you start on a task: `code` is the task's code (or a project's code); `id` (task) or `project_id`/`project_code` also work. With none, the project part is left out. Each part's header gives its version.",
             "inputSchema": obj(["code": str, "id": int, "project_id": int, "project_code": str])],

            ["name": "update_guide",
             "description": "Replace a guide with `markdown`: the user's guide for every project (`global` true) or a project's (`project_id`/`project_code`); give exactly one. Only when the user asked for it, or after ask_user got a yes. Saves a new version (get_guide_history keeps the earlier ones; an unchanged text saves nothing). `reason` says why. Returns {version, scope, ts}.",
             "inputSchema": obj(guideScope.merging([
                "markdown": str,
                "reason": ["type": "string", "description": "why the guide changes (shown in its history)"] as [String: Any],
                "session": sessionStr
             ]) { a, _ in a }, required: ["markdown"])],

            ["name": "get_guide_history",
             "description": "Versions of a guide, newest first (the first is the current one): the user's guide for every project (`global` true) or a project's (`project_id`/`project_code`). Each has version, ts, author (user|agent), session and reason when known, and markdown. `limit` default 5, max 50.",
             "inputSchema": obj(guideScope.merging([
                "limit": ["type": "integer", "minimum": 1, "maximum": 50] as [String: Any]
             ]) { a, _ in a })],

            ["name": "daily_stats",
             "description": "Today's pomodoro stats: completed count and total focus minutes.",
             "inputSchema": obj([:])]
        ]
    }
}
