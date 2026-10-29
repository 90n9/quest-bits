import Foundation

extension MCPServer {
    /// MCP tool schemas advertised via tools/list.
    static var toolDefinitions: [[String: Any]] {
        func obj(_ props: [String: Any], required: [String] = []) -> [String: Any] {
            ["type": "object", "properties": props, "required": required]
        }
        let str: [String: Any] = ["type": "string"]
        let int: [String: Any] = ["type": "integer"]
        let statusEnum: [String: Any] = ["type": "string", "enum": ["todo", "in_progress", "done"]]
        let priorityEnum: [String: Any] = ["type": "string", "enum": ["none", "low", "medium", "high"]]
        let dateStr: [String: Any] = ["type": "string", "description": "ISO-8601 or yyyy-MM-dd; null to clear"]
        let tagsArr: [String: Any] = ["type": "array", "items": str]
        let recurrenceEnum: [String: Any] = ["type": "string", "enum": ["daily", "weekly", "monthly"], "description": "repeat interval; null to clear. On completion, spawns the next occurrence with the due date advanced."]
        let estimateInt: [String: Any] = ["type": "integer", "description": "planned effort in minutes (0 = unset). Compared against actual tracked effort_minutes."]

        return [
            ["name": "list_projects",
             "description": "List all projects. Each has a short `code` (e.g. GEN) usable as a handle.",
             "inputSchema": obj([:])],

            ["name": "create_project",
             "description": "Create a new project. Optional `description` gives context. A short code is auto-generated and returned.",
             "inputSchema": obj(["name": str, "description": str], required: ["name"])],

            ["name": "rename_project",
             "description": "Rename a project, identified by `id` or `code`.",
             "inputSchema": obj(["id": int, "code": str, "name": str], required: ["name"])],

            ["name": "update_project",
             "description": "Update a project's `name` and/or `description` (identify by `id` or `code`).",
             "inputSchema": obj(["id": int, "code": str, "name": str, "description": str])],

            ["name": "delete_project",
             "description": "Delete a project and all its tasks. Identify by `id` or `code`.",
             "inputSchema": obj(["id": int, "code": str])],

            ["name": "list_tasks",
             "description": "List tasks, optionally filtered by `project_id` or `project_code`. Each task has the same shape as get_task.",
             "inputSchema": obj(["project_id": int, "project_code": str])],

            ["name": "get_task",
             "description": "Get a single task by `id` or `code` (e.g. GEN-3). Other tasks are referenced by code (`parent`, `depends_on`). Fields that are empty or default are omitted: no priority, tags, link, due_date, detail, effort or estimate; `blocked` appears only when true.",
             "inputSchema": obj(["id": int, "code": str])],

            ["name": "create_task",
             "description": "Create a task under a project (give `project_id` or `project_code`). detail, link, priority, due_date, tags, recurrence optional; status defaults to todo. Pass `parent_id` or `parent_code` to make it a subtask of another task (one level of nesting). Returns the task with its new code.",
             "inputSchema": obj([
                "project_id": int, "project_code": str, "title": str, "detail": str, "link": str,
                "status": statusEnum, "priority": priorityEnum, "due_date": dateStr, "tags": tagsArr, "recurrence": recurrenceEnum,
                "estimate_minutes": estimateInt, "parent_id": int, "parent_code": str
             ], required: ["title"])],

            ["name": "update_task",
             "description": "Update a task by `id` or `code`. Only provided fields change. Pass link:null, due_date:null, or recurrence:null to clear them. Use this to update progress status, priority, due date, tags, recurrence, or estimate_minutes (0 clears the estimate). Returns the updated task (same shape as get_task; omitted fields are empty/default).",
             "inputSchema": obj([
                "id": int, "code": str, "title": str, "detail": str, "link": str,
                "status": statusEnum, "priority": priorityEnum, "due_date": dateStr, "tags": tagsArr, "recurrence": recurrenceEnum,
                "estimate_minutes": estimateInt
             ])],

            ["name": "delete_task",
             "description": "Delete a task by `id` or `code`.",
             "inputSchema": obj(["id": int, "code": str])],

            ["name": "duplicate_task",
             "description": "Clone a task (by `id` or `code`). Without a target it duplicates in the same project; with `to_project_id`/`to_project_code` it copies there (original kept). The copy gets a fresh code.",
             "inputSchema": obj(["id": int, "code": str, "to_project_id": int, "to_project_code": str])],

            ["name": "move_task",
             "description": "Move (transfer) a task (by `id` or `code`) to another project (`to_project_id` or `to_project_code`).",
             "inputSchema": obj(["id": int, "code": str, "to_project_id": int, "to_project_code": str])],

            ["name": "bulk_update_tasks",
             "description": "Update many tasks at once (give `ids` and/or `codes` arrays). Applies any of status, priority, due_date, add_tags to all. add_tags merges (keeps existing).",
             "inputSchema": obj([
                "ids": ["type": "array", "items": int], "codes": ["type": "array", "items": str],
                "status": statusEnum, "priority": priorityEnum, "due_date": dateStr, "add_tags": tagsArr
             ])],

            ["name": "bulk_move_tasks",
             "description": "Move (or copy, if copy=true) many tasks to another project. Give `ids`/`codes` and `to_project_id`/`to_project_code`.",
             "inputSchema": obj([
                "ids": ["type": "array", "items": int], "codes": ["type": "array", "items": str],
                "to_project_id": int, "to_project_code": str, "copy": ["type": "boolean"]
             ])],

            ["name": "bulk_delete_tasks",
             "description": "Delete many tasks at once. Give `ids` and/or `codes` arrays.",
             "inputSchema": obj([
                "ids": ["type": "array", "items": int], "codes": ["type": "array", "items": str]
             ])],

            ["name": "get_task_history",
             "description": "Get the change history (status changes, etc.) for a task by `id` or `code`, newest first.",
             "inputSchema": obj(["id": int, "code": str])],

            ["name": "add_dependency",
             "description": "Make a task blocked by another. The task (`id`/`code`) stays blocked until the dependency (`depends_on_id`/`depends_on_code`) is done; a task that is itself done is never blocked. Rejects self-dependency and cycles.",
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
             "description": "Create a real task from a template (`template_id`) into a project (`project_id` or `project_code`). Copies the template's title, detail, priority, tags, and estimate. Returns the new task with its code.",
             "inputSchema": obj([
                "template_id": int, "project_id": int, "project_code": str
             ], required: ["template_id"])],

            ["name": "daily_stats",
             "description": "Today's pomodoro stats: completed count and total focus minutes.",
             "inputSchema": obj([:])]
        ]
    }
}
