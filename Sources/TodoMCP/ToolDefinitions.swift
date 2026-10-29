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

        return [
            ["name": "list_projects",
             "description": "List projects. Each has a short `code` (e.g. GEN) usable as a handle. Archived projects are left out unless `include_archived` is true; they carry `archived_at`.",
             "inputSchema": obj(["include_archived": ["type": "boolean", "description": "also list archived projects (default false)"] as [String: Any]])],

            ["name": "create_project",
             "description": "Create a new project. Optional `description` gives context. A short code is auto-generated and returned.",
             "inputSchema": obj(["name": str, "description": str], required: ["name"])],

            ["name": "rename_project",
             "description": "Rename a project, identified by `id` or `code`.",
             "inputSchema": obj(["id": int, "code": str, "name": str], required: ["name"])],

            ["name": "update_project",
             "description": "Update a project's `name` and/or `description` (identify by `id` or `code`).",
             "inputSchema": obj(["id": int, "code": str, "name": str, "description": str])],

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
             "description": "List tasks. By default only open tasks (todo, in_progress, waiting) in the compact view. Without `project_id`/`project_code` or `parent_id`/`parent_code`, tasks of archived projects are left out unless `include_archived` is true. Filters (all optional, combined with AND): `project_id`/`project_code`, `status` (a status, an array of statuses, or \"all\" to include done and dropped), `tag` (one whole tag; case-insensitive for ASCII letters only), `parent_id`/`parent_code` (subtasks of that task). Sorted in_progress, waiting, todo, done, dropped, then by board order. The compact view gives code, title, status, and only when set: priority, parent, blocked_by (open dependencies blocking it), tags, due_date, waiting_on. To read detail and the other fields use get_task, or pass view \"full\" for get_task's shape. list_tasks never includes notes; get_task does.",
             "inputSchema": obj([
                "project_id": int, "project_code": str,
                "status": ["anyOf": [
                    ["type": "string", "enum": TaskStatus.allCases.map(\.rawValue) + ["all"]],
                    ["type": "array", "items": statusEnum, "minItems": 1]
                ], "description": "status or statuses to include; \"all\" = every status. Default: open (todo, in_progress, waiting)."] as [String: Any],
                "tag": str, "parent_id": int, "parent_code": str,
                "include_archived": ["type": "boolean", "description": "with no project or parent given, also list tasks of archived projects (default false)"] as [String: Any],
                "view": ["type": "string", "enum": ["compact", "full"], "description": "compact (default) or full (same fields as get_task, without notes)"] as [String: Any]
             ])],

            ["name": "get_task",
             "description": "Get a single task by `id` or `code` (e.g. GEN-3). Other tasks are referenced by code (`parent`, `depends_on`). Fields that are empty or default are omitted: no priority, tags, link, due_date, detail, effort or estimate; `blocked` appears only when true; `waiting_on`/`waiting_reason` only on waiting tasks. Includes the latest notes (see add_note) newest first as `notes` [{ts, text, kind}] (kind omitted when \"note\"; no `notes` key when there are none), and `more_notes: true` when older notes were left out.",
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
             "description": "Update a task by `id` or `code`. Only provided fields change. Pass link:null, due_date:null, or recurrence:null to clear them. Use this to update progress status, priority, due date, tags, recurrence, or estimate_minutes (0 clears the estimate). status waiting needs `waiting_on` (user|external) unless the task is already waiting; `waiting_reason` is optional. Moving to any other status clears waiting_on/waiting_reason, and setting them on a task that is not (or will not be) waiting is an error. status dropped abandons a task but keeps it and its history: it closes like done (dependents unblock) but is not a completion (no completed_at, not in daily_stats, a recurring task spawns no next occurrence). To log progress use add_note; do not append to detail. Returns the updated task (same shape as get_task, without notes; omitted fields are empty/default).",
             "inputSchema": obj([
                "id": int, "code": str, "title": str, "detail": str, "link": str,
                "status": statusEnum, "waiting_on": waitingOnEnum, "waiting_reason": waitingReasonStr,
                "priority": priorityEnum, "due_date": dateStr, "tags": tagsArr, "recurrence": recurrenceEnum,
                "estimate_minutes": estimateInt
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

            ["name": "bulk_update_tasks",
             "description": "Update many tasks at once (give `ids` and/or `codes` arrays). Applies any of status, waiting_on, waiting_reason, priority, due_date, add_tags to all. add_tags merges (keeps existing). Waiting rules match update_task. All or nothing: if any task fails (e.g. the waiting rule), no task changes.",
             "inputSchema": obj([
                "ids": ["type": "array", "items": int], "codes": ["type": "array", "items": str],
                "status": statusEnum, "waiting_on": waitingOnEnum, "waiting_reason": waitingReasonStr,
                "priority": priorityEnum, "due_date": dateStr, "add_tags": tagsArr
             ])],

            ["name": "bulk_move_tasks",
             "description": "Move (or copy, if copy=true) many tasks to another project. Give `ids`/`codes` and `to_project_id`/`to_project_code`. A copy to another project keeps each task's status, started/completed times and waiting fields (same rule as duplicate_task). The target project must not be archived.",
             "inputSchema": obj([
                "ids": ["type": "array", "items": int], "codes": ["type": "array", "items": str],
                "to_project_id": int, "to_project_code": str, "copy": ["type": "boolean"]
             ])],

            ["name": "bulk_delete_tasks",
             "description": "Delete many tasks at once. Give `ids` and/or `codes` arrays.",
             "inputSchema": obj([
                "ids": ["type": "array", "items": int], "codes": ["type": "array", "items": str]
             ])],

            ["name": "add_note",
             "description": "Append a note to a task (`id` or `code`): progress, findings, decisions or review results. Use this instead of appending to the task's detail, which stays the spec. Insert only: nothing is read or rewritten, so concurrent sessions never lose each other's notes. `kind` is note (default), decision or review. Bumps the task's updated_at. Notes are newest first in get_task, not in list_tasks; they stay with the task when it moves, are not copied by duplicate_task, and are deleted with the task. Returns {note_id, task, ts} plus kind when not note.",
             "inputSchema": obj([
                "id": int, "code": str, "text": str,
                "kind": ["type": "string", "enum": NoteKind.allCases.map(\.rawValue)] as [String: Any]
             ], required: ["text"])],

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

            ["name": "daily_stats",
             "description": "Today's pomodoro stats: completed count and total focus minutes.",
             "inputSchema": obj([:])]
        ]
    }
}
