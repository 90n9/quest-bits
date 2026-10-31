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
        let estimateInt: [String: Any] = ["type": "integer", "description": "planned effort in minutes (0 = unset). Shown beside the task's effort_minutes when it has any."]
        let noteKindEnum: [String: Any] = ["type": "string", "enum": NoteKind.writable.map(\.rawValue)]
        let branchStr: [String: Any] = ["type": "string", "description": "the git branch the task's work is on now; null clears it"]
        let linkKindEnum: [String: Any] = ["type": "string", "enum": LinkKind.allCases.map(\.rawValue), "description": "what the link points at; guessed from the url when omitted"]
        let relationKindEnum: [String: Any] = ["type": "string", "enum": RelationKind.allCases.map(\.rawValue), "description": "how the task relates to the other, seen from the task"]
        let sessionStr: [String: Any] = ["type": "string", "description": "optional label for your agent session, recorded with what you write; questions asked with one can be filtered by it. When your session's start context has a line `QuestBits session: <id>`, use that id (a subagent may add a suffix: <id>/QUE-3)"]
        let parentStr: [String: Any] = ["type": ["string", "null"], "description": "code of a top-level task in the same project to make this a subtask of; null makes it a top-level task again"]
        let parentInt: [String: Any] = ["type": ["integer", "null"], "description": "id form of parent_code"]
        let guideScope: [String: Any] = ["global": ["type": "boolean", "description": "true: the user's guide for every project"] as [String: Any],
                                         "project_id": int, "project_code": str]
        let repoPathStr: [String: Any] = ["type": ["string", "null"], "description": "absolute folder (or starting with ~) of the project's repo or workspace; stored with ~ expanded"]
        let milestoneStr: [String: Any] = ["type": ["string", "null"], "description": "name of an open milestone of the task's project (see list_milestones); null takes the task out of its milestone"]
        let milestoneInt: [String: Any] = ["type": ["integer", "null"], "description": "id form of milestone"]
        let milestoneRef: [String: Any] = ["id": int, "project_id": int, "project_code": str,
                                           "name": ["type": "string", "description": "the milestone's name, with project_code or project_id (or give its id)"] as [String: Any]]
        let pageKindEnum: [String: Any] = ["type": "string", "enum": PageKind.allCases.map(\.rawValue)]
        let codesArr: [String: Any] = ["type": "array", "items": str]
        let idsArr: [String: Any] = ["type": "array", "items": int]
        let pageRef: [String: Any] = ["id": int, "project_id": int, "project_code": str,
                                      "title": ["type": "string", "description": "the page's whole title (case-insensitive), with project_code or project_id (or give its id)"] as [String: Any],
                                      "source_key": ["type": "string", "description": "the source_key it was created with, with project_code or project_id"] as [String: Any]]
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
             "description": "Which project a folder belongs to, e.g. your working directory: the active project whose `repo_path` is that folder or contains it (a subfolder of a repo matches). When folders nest, such as a workspace and a repo inside it, the deepest one wins. Folders compare as the file system sees them: ~ expanded, symlinks resolved, trailing slashes ignored, whole folder names only (/x/app does not contain /x/app-2). Archived projects and projects without a repo_path never match. Returns {path (resolved), project} where project is null or the project (as in list_projects) plus counts of its tasks: open, in_progress, waiting_on_user; `guide` (the project's own guide markdown, with `guide_version`; only when it has one; get_guide gives the full guide) and `wiki` {decisions, notes}: how many wiki pages it has (see search_pages).",
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
             "description": "List tasks. By default only open tasks (todo, in_progress, waiting) in the compact view. Without `project_id`/`project_code` or `parent_id`/`parent_code`, tasks of archived projects are left out unless `include_archived` is true. Filters (all optional, combined with AND): `project_id`/`project_code`, `status` (a status, an array of statuses, or \"all\" to include done and dropped), `tag` (one whole tag; case-insensitive for ASCII letters only), `parent_id`/`parent_code` (subtasks of that task), `milestone` (a milestone's name — within the project when one is given, else in any project — or \"none\" for tasks in no milestone) or `milestone_id`. Sorted in_progress, waiting, todo, done, dropped, then by board order (projects in sidebar order, then each project's own task order). With `sort` \"board\" the status grouping is dropped and you get the saved order the app shows (set with reorder_tasks): each top-level task in order, followed by its own subtasks in order; use it to read back an order. The compact view gives code, title, status, and only when set: priority, parent, blocked_by (open dependencies blocking it), tags, due_date, waiting_on, branch, milestone (its name), claimed_by (the session holding it; claim_expired when its claim lapsed). To read detail, links and the other fields use get_task, or pass view \"full\" for get_task's shape. list_tasks never includes notes; get_task does.",
             "inputSchema": obj([
                "project_id": int, "project_code": str,
                "status": ["anyOf": [
                    ["type": "string", "enum": TaskStatus.allCases.map(\.rawValue) + ["all"]],
                    ["type": "array", "items": statusEnum, "minItems": 1]
                ], "description": "status or statuses to include; \"all\" = every status. Default: open (todo, in_progress, waiting)."] as [String: Any],
                "tag": str, "parent_id": int, "parent_code": str,
                "milestone": ["type": "string", "description": "a milestone name, or \"none\" for tasks in no milestone"] as [String: Any],
                "milestone_id": int,
                "include_archived": ["type": "boolean", "description": "with no project or parent given, also list tasks of archived projects (default false)"] as [String: Any],
                "view": ["type": "string", "enum": ["compact", "full"], "description": "compact (default) or full (same fields as get_task, without notes)"] as [String: Any],
                "sort": ["type": "string", "enum": TaskSort.allCases.map(\.rawValue), "description": "status (default): status groups, then board order; board: the saved order only, status ignored"] as [String: Any]
             ])],

            ["name": "get_task",
             "description": "Get a single task by `id` or `code` (e.g. GEN-3). Other tasks are referenced by code (`parent`, `depends_on`). `claim` {by, holder, label, claimed_at, heartbeat_at, expires_at, expired} is there while a session holds the task (next_task / claim_task; `expired` once its claim lapsed). Fields that are empty or default are omitted: no priority, tags, link, links, branch, due_date, detail, effort or estimate; `links` [{id, kind, url, title, author, source, created_at}] lists the task's links oldest first (kind pr|design|doc|file|branch|other; title, author and source only when known), `link` is the url of the first one that is not a branch (the older single-link field), and `branch` is the git branch the work is on now; `blocked` appears only when true; `waiting_on`/`waiting_reason`/`waiting_since` only on waiting tasks; `milestone` (name) and `milestone_id` only when the task is in one. Includes the latest notes (see add_note) newest first as `notes` [{id, ts, text, kind, author, session, edited_at, question_id}] (kind omitted when \"note\"; author user|agent, absent on notes from before 1.4.0; no `notes` key when there are none), and `more_notes: true` when older notes were left out. Questions still open or answered-but-not-resumed (see ask_user) are in `questions`. `relations` (only when it has any) groups the tasks it is related to, across projects, by kind: blocked_by (its dependencies, open or closed), blocks (tasks that depend on it), relates, duplicates (it is a duplicate of these), duplicated_by; each entry is {code, title, status}. `detail` is markdown; images the user attached in the app are linked as `attachments/<file>`, and `attachments` lists those files' absolute paths so you can open them.",
             "inputSchema": obj([
                "id": int, "code": str,
                "notes_limit": ["type": "integer", "minimum": 0, "maximum": 100, "description": "how many latest notes to include (default 5, 0 = none, max 100)"] as [String: Any]
             ])],

            ["name": "create_task",
             "description": "Create a task under a project (give `project_id` or `project_code`). detail, link, branch, priority, due_date, tags, recurrence optional (link becomes the task's primary link, its kind guessed; add more with add_link); status defaults to todo. status waiting needs `waiting_on` (user|external) and takes an optional `waiting_reason`. Pass `parent_id` or `parent_code` to make it a subtask of another task (one level of nesting). `milestone` (name) or `milestone_id` puts it in an open milestone of its project. The project (given or the parent's) must not be archived. Returns the task with its new code (same shape as get_task, without notes).",
             "inputSchema": obj([
                "project_id": int, "project_code": str, "title": str, "detail": str, "link": str, "branch": branchStr,
                "status": statusEnum, "waiting_on": waitingOnEnum, "waiting_reason": waitingReasonStr,
                "priority": priorityEnum, "due_date": dateStr, "tags": tagsArr, "recurrence": recurrenceEnum,
                "estimate_minutes": estimateInt, "parent_id": int, "parent_code": str,
                "milestone": milestoneStr, "milestone_id": milestoneInt
             ], required: ["title"])],

            ["name": "update_task",
             "description": "Update a task by `id` or `code`. Only provided fields change. Pass link:null, branch:null, due_date:null, or recurrence:null to clear them. `link` is the older single-link field: it replaces the task's primary link (the first that is not a branch) or adds it, and null removes that link; to keep several links use add_link / remove_link. `branch` is the git branch the work is on now. Use this to update progress status, priority, due date, tags, recurrence, or estimate_minutes (0 clears the estimate). Priority does not change where a task sits; reorder_tasks does that. status waiting needs `waiting_on` (user|external) unless the task is already waiting; `waiting_reason` is optional. Moving to any other status clears waiting_on/waiting_reason, and setting them on a task that is not (or will not be) waiting is an error. status dropped abandons a task but keeps it and its history: it closes like done (dependents unblock) but is not a completion (no completed_at, not in daily_stats, a recurring task spawns no next occurrence). To log progress use add_note; do not append to detail. Optional `note` adds a note in the same write, linked to the status change: its `note_kind` defaults to summary when the update closes the task (done/dropped) and to note otherwise. A summary is never required to close a task. While another session holds a live claim on the task (claim_task / next_task), its status cannot be changed from your session; done or dropped ends the task's claim, and an update to a task you claimed renews your claim. `parent_code`/`parent_id` moves the task under a top-level task of the same project (one level of nesting: a task with subtasks, or a recurring one, cannot become a subtask); null makes it top-level again. `milestone` (name of an open milestone of the task's project) or `milestone_id` puts the task in that milestone; null takes it out. A milestone is a grouping beside parent/subtask: setting one never moves the task under a parent, and finishing a milestone's tasks never closes it. Returns the updated task (same shape as get_task, without notes; omitted fields are empty/default).",
             "inputSchema": obj([
                "id": int, "code": str, "title": str, "detail": str, "link": str, "branch": branchStr,
                "status": statusEnum, "waiting_on": waitingOnEnum, "waiting_reason": waitingReasonStr,
                "priority": priorityEnum, "due_date": dateStr, "tags": tagsArr, "recurrence": recurrenceEnum,
                "estimate_minutes": estimateInt, "parent_code": parentStr, "parent_id": parentInt,
                "milestone": milestoneStr, "milestone_id": milestoneInt,
                "note": ["type": "string", "description": "optional note to add with this update, e.g. a closing summary: what was done, files/PRs, what is left"] as [String: Any],
                "note_kind": noteKindEnum, "session": sessionStr
             ])],

            ["name": "delete_task",
             "description": "Delete a task by `id` or `code`.",
             "inputSchema": obj(["id": int, "code": str])],

            ["name": "duplicate_task",
             "description": "Clone a task (by `id` or `code`); the copy gets a fresh code. Without a target (or with its own project) it duplicates in the same project for reuse: the copy starts as a todo, and status, started/completed times and waiting fields are not copied. With another project as `to_project_id`/`to_project_code` it copies the task there as is (original kept): status, started/completed times and waiting fields carry over. A copy keeps the task's milestone within the same project (while that milestone is open), never in another project. A target project must not be archived.",
             "inputSchema": obj(["id": int, "code": str, "to_project_id": int, "to_project_code": str])],

            ["name": "move_task",
             "description": "Move (transfer) a task (by `id` or `code`) to another project (`to_project_id` or `to_project_code`), which must not be archived. Milestones belong to a project, so the task and its subtasks leave theirs.",
             "inputSchema": obj(["id": int, "code": str, "to_project_id": int, "to_project_code": str])],

            ["name": "reorder_tasks",
             "description": "Set the order of tasks in a project: the order the app's list and board show, saved for good. Give the tasks in the order you want as `codes` or `ids` (not both). They must be siblings: top-level tasks of one project, or subtasks of one parent (a subtask never leaves its parent, and a parent's subtasks move with it). They go to the top of their siblings in that order (`place` \"bottom\": to the bottom); siblings you leave out keep their order below (or above) them. Closed tasks can be ordered too, though the app lists them in its Done section. Nothing else changes: not status, priority, parent, project or updated_at. Priority does not move a task (update_task priority only sets the field); order is set only here. All or nothing: an unknown task, a task given twice, or tasks of another project or parent leave the order as it was. Returns {project, parent (when subtasks), tasks: the siblings in their new order, compact view}; list_tasks with sort \"board\" reads it back. Example, before a UAT: reorder_tasks {codes: [\"WGS-4\", \"WGS-7\", \"WGS-2\"]} puts the work due before UAT first, then reorder_tasks {codes: [\"WGS-9\", \"WGS-11\"], place: \"bottom\"} sends the tasks waiting on the customer to the bottom.",
             "inputSchema": obj([
                "codes": ["type": "array", "items": str, "minItems": 1, "description": "task codes in the order you want"] as [String: Any],
                "ids": ["type": "array", "items": int, "minItems": 1, "description": "id form of codes"] as [String: Any],
                "place": ["type": "string", "enum": TaskPlacement.allCases.map(\.rawValue), "description": "top (default) or bottom of their siblings"] as [String: Any]
             ])],

            ["name": "next_task",
             "description": "The next task to work on, in board order (the order the app shows; priority does not reorder), and with `claim` true take it for your session in the same step: two sessions never get the same task. Scope: `project_code`/`project_id`, or `path` (a folder, mapped as find_project does), else every active project. Eligible: a todo task that is not blocked, has no open subtasks (its first eligible subtask comes next instead), is not under a waiting or blocked parent, and has no live claim of another session; or an in-progress task whose claim expired (a takeover: the output has `took_over_from` and `latest_notes`; read them before carrying on). Waiting and in-progress tasks are skipped. Claiming moves a todo task to in_progress. A claim lasts \(Int(Store.claimTTL / 60)) minutes after its last heartbeat: call heartbeat while you work (any update_task, add_note, add_link or ask_user on the task renews it too), and finish with update_task status done/dropped or release_task, which end it. Returns {project?, task (get_task's shape, with `claim`), claimed, outcome (claimed|renewed|took_over), took_over_from?, latest_notes?, your_other_claims?}; nothing eligible: {task: null, skipped: {claimed_by_others, blocked, waiting, in_progress}}. Without claim it only looks (claim_task can take the task later, if still free).",
             "inputSchema": obj([
                "project_code": str, "project_id": int,
                "path": ["type": "string", "description": "a folder inside a project's repo (instead of project_code)"] as [String: Any],
                "claim": ["type": "boolean", "description": "take the task for your session (default false: only look)"] as [String: Any],
                "session": ["type": "string", "description": "your session label, the same on every call (your session id when your start context has a line `QuestBits session: <id>`). Claims belong to your Claude Code session when QuestBits knows it (hooks installed), else to this label; needed when neither is known"] as [String: Any]
             ])],

            ["name": "claim_task",
             "description": "Claim a task (`id` or `code`) for your session, so other sessions leave it alone (next_task skips it, and their status changes to it are refused). Refused while another session holds a live claim; a claim that expired (no heartbeat for \(Int(Store.claimTTL / 60)) minutes, or its session ended) is taken over, and the output then has `took_over_from` and `latest_notes`. Your own claim is renewed. A todo task moves to in_progress; done or dropped tasks cannot be claimed. Returns {task, claimed, outcome (claimed|renewed|took_over), took_over_from?, latest_notes?}.",
             "inputSchema": obj(["id": int, "code": str, "session": ["type": "string", "description": "your session label, the same on every call (your session id when your start context has a line `QuestBits session: <id>`). Claims belong to your Claude Code session when QuestBits knows it (hooks installed), else to this label; needed when neither is known"] as [String: Any]])],

            ["name": "release_task",
             "description": "Give back your claim on a task (`id` or `code`) without finishing it, e.g. when you stop before it is done. An in-progress task goes back to todo so next_task offers it again (`keep_status` true leaves the status). Only your own claim can be released. Closing a task (update_task status done or dropped) ends its claim by itself. Returns {task, released, status}.",
             "inputSchema": obj(["id": int, "code": str,
                                 "keep_status": ["type": "boolean", "description": "leave the status as is (default false: in_progress goes back to todo)"] as [String: Any],
                                 "session": ["type": "string", "description": "your session label, the same on every call (your session id when your start context has a line `QuestBits session: <id>`). Claims belong to your Claude Code session when QuestBits knows it (hooks installed), else to this label; needed when neither is known"] as [String: Any]])],

            ["name": "heartbeat",
             "description": "Keep your claims: renews every claim your session holds (or only the task's, with `id`/`code`) for another \(Int(Store.claimTTL / 60)) minutes. Call it every 10–15 minutes while you work on a claimed task without other QuestBits writes to it. A claim another session took over is no longer yours and is not renewed (with `id`/`code` that is an error). Returns {renewed: [codes], ttl_minutes, expires_at}.",
             "inputSchema": obj(["id": int, "code": str, "session": ["type": "string", "description": "your session label, the same on every call (your session id when your start context has a line `QuestBits session: <id>`). Claims belong to your Claude Code session when QuestBits knows it (hooks installed), else to this label; needed when neither is known"] as [String: Any]])],

            ["name": "bulk_update_tasks",
             "description": "Update many tasks at once (give `ids` and/or `codes` arrays). Applies any of status, waiting_on, waiting_reason, priority, due_date, add_tags, parent_code/parent_id, milestone/milestone_id (a milestone name is looked up in the first task's project; every task must be in that project) to all. add_tags merges (keeps existing). Waiting and parent rules match update_task. All or nothing: if any task fails (e.g. the waiting rule), no task changes.",
             "inputSchema": obj([
                "ids": ["type": "array", "items": int], "codes": ["type": "array", "items": str],
                "status": statusEnum, "waiting_on": waitingOnEnum, "waiting_reason": waitingReasonStr,
                "priority": priorityEnum, "due_date": dateStr, "add_tags": tagsArr,
                "parent_code": parentStr, "parent_id": parentInt,
                "milestone": milestoneStr, "milestone_id": milestoneInt, "session": sessionStr
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

            ["name": "decisions",
             "description": "Decisions recorded as notes (add_note kind decision), newest first, across projects — e.g. to look back at what agents decided on their own. `author`: agent (default: decisions agents made themselves, not answers they resumed), user (the user's: answers an agent resumed, notes they wrote), or any. Optional `project_id`/`project_code`, `since` (ISO-8601 or yyyy-MM-dd), `disagreed` true (only those the user disagreed with), `limit` (default 50, max 200). Archived projects are included. Each is a note (as in get_task) plus task, title, task_status, project, seen_at (when the user marked it seen in the app) and `disagreements` [{question_id, task, why, at, status, resumed_at?}]: a disagreement reaches you as a question of kind disagree, already answered with the user's reason (get_answers, get_task); resume it, then change course or explain, and record what you do.",
             "inputSchema": obj([
                "project_id": int, "project_code": str, "since": str,
                "author": ["type": "string", "enum": DecisionAuthor.allCases.map(\.rawValue)] as [String: Any],
                "disagreed": ["type": "boolean"] as [String: Any],
                "limit": ["type": "integer", "minimum": 1, "maximum": 200] as [String: Any]
             ])],

            ["name": "get_note_history",
             "description": "A note (`note_id`, the `id` in get_task notes) with `edits`: its earlier texts, newest first, each with when it was replaced. Only the user edits notes, in the app.",
             "inputSchema": obj(["note_id": int], required: ["note_id"])],

            ["name": "ask_user",
             "description": "Leave a question for the user on a task (`id` or `code`) and keep working on something else — do not end your turn to wait. The user answers in the QuestBits app when convenient. `kind`: choice (default; 2–4 `options`), text (free answer; up to 4 suggested options) or approve (approve or edit a draft given in `context`; no options). Options are strings or {label, note}; `recommended` is the option number (from 1) or label you recommend — give one, with the reason in its note or the context. `context`: short markdown the user needs to decide. By default the question blocks the task: it moves to waiting on the user until every blocking question is answered, then back to todo. `blocks_task` false asks without blocking. Also logs a question note. Returns the question with its `id` (and `claude_session`, the Claude Code session it was linked to, when QuestBits' hooks recorded it). Later: get_answers / wait_for_answers, then resume_question.",
             "inputSchema": obj([
                "id": int, "code": str, "question": str,
                "kind": ["type": "string", "enum": QuestionKind.askable.map(\.rawValue)] as [String: Any],
                "options": ["type": "array", "maxItems": 4, "items": ["anyOf": [
                    str, obj(["label": str, "note": str], required: ["label"])
                ]] as [String: Any]] as [String: Any],
                "recommended": ["anyOf": [int, str], "description": "option number (from 1) or label"] as [String: Any],
                "context": str,
                "blocks_task": ["type": "boolean", "description": "default true: the task waits on the user until answered"] as [String: Any],
                "session": sessionStr
             ], required: ["question"])],

            ["name": "get_answers",
             "description": "Questions the user has answered that are not resumed yet, oldest first, plus how many are still `open`: {answered: [question...], open: N}. Each answered question has `answer` (and `choice`, the option number, when an option was picked). A question of kind disagree is the user disagreeing with a decision you recorded (`about_note` is that note; `answer` says why): reconsider it. Call it before starting new work and act on answers first: resume_question, then continue the task. Optional project and session filters.",
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
             "description": "Withdraw a question (`id`) that is open or answered but no longer needed, e.g. you found the answer yourself (not a disagreement: resume that one). `reason` says why (recorded as a decision note by the agent). A blocking question releases its task as resume_question does.",
             "inputSchema": obj(["id": int, "reason": str, "session": sessionStr], required: ["id"])],

            ["name": "get_task_history",
             "description": "Get the change history (status changes, links, claims, dependencies and relations, etc.) for a task by `id` or `code`, newest first: [{timestamp, field, old, new, source?, claude_session?, session?}]. `source` is where the change came from (app = the user in QuestBits, mcp = an agent, hook, cli, import), absent on changes from before 1.5.0; `claude_session` the agent's Claude Code session id and `session` its label, when known.",
             "inputSchema": obj(["id": int, "code": str])],

            ["name": "add_dependency",
             "description": "Make a task blocked by another. The task (`id`/`code`) stays blocked until the dependency (`depends_on_id`/`depends_on_code`) is closed (done or dropped); a task that is itself closed is never blocked. Rejects self-dependency and cycles.",
             "inputSchema": obj(["id": int, "code": str, "depends_on_id": int, "depends_on_code": str])],

            ["name": "remove_dependency",
             "description": "Remove a blocked-by dependency: task (`id`/`code`) no longer depends on (`depends_on_id`/`depends_on_code`).",
             "inputSchema": obj(["id": int, "code": str, "depends_on_id": int, "depends_on_code": str])],

            ["name": "add_relation",
             "description": "Relate a task (`id`/`code`) to another (`other_id`/`other_code`), in any project. `kind` is seen from the task: blocked_by (the task depends on the other, same as add_dependency), blocks (the other depends on the task), relates (both ways, stored once), duplicates (the task is a duplicate of the other), duplicated_by (the other is a duplicate of the task). Only blocked_by/blocks block, with the dependency rules: self and cycles are rejected. relates and duplicates never block; a task cannot relate to itself, and two tasks cannot each duplicate the other. Repeat-safe: an existing relation returns created:false. `drop: true` (duplicates/duplicated_by only) also drops the duplicate unless it is already closed, with a summary note. Returns {task, other, kind, created, relations, dropped?} where relations is the task's relations as get_task shows them.",
             "inputSchema": obj([
                "id": int, "code": str, "other_id": int, "other_code": str,
                "kind": relationKindEnum,
                "drop": ["type": "boolean", "description": "duplicates/duplicated_by only: also set the duplicate's status to dropped"] as [String: Any],
                "session": sessionStr
             ], required: ["kind"])],

            ["name": "remove_relation",
             "description": "Remove a relation between a task (`id`/`code`) and another (`other_id`/`other_code`); `kind` as in add_relation (blocked_by/blocks remove the dependency, relates matches either way round). Returns {task, other, kind, removed, relations}; removed:false when there was none.",
             "inputSchema": obj(["id": int, "code": str, "other_id": int, "other_code": str, "kind": relationKindEnum],
                                required: ["kind"])],

            ["name": "add_link",
             "description": "Add a link to a task (`id` or `code`): a pull request, design, doc, file, an earlier or extra git branch, or anything else. A task keeps any number of links, oldest first, and one PR may be linked from several tasks. `kind` is guessed from the url when not given (GitHub/GitLab/Bitbucket PRs → pr, claude.ai artifacts and Figma → design, Google Docs/Notion/Confluence → doc, a path → file, else other; branch is never guessed). The url is stored once per task (trimmed, trailing slashes dropped): adding one the task already has adds nothing, sets the `kind`/`title` you give, and returns it with created:false, so repeating a call is safe. `source` records where the link came from (e.g. an import's source key) and is kept on a new link only. The task's working branch is not a link: set it with update_task branch. Returns {task, link: {id, kind, url, title, author, source, created_at}, created}.",
             "inputSchema": obj([
                "id": int, "code": str, "url": ["type": "string", "description": "a URL, a file path, or (kind branch) a branch name"] as [String: Any],
                "kind": linkKindEnum,
                "title": ["type": "string", "description": "optional short label shown instead of the url"] as [String: Any],
                "source": ["type": "string", "description": "optional provenance, e.g. an importer's source key"] as [String: Any],
                "session": sessionStr
             ], required: ["url"])],

            ["name": "remove_link",
             "description": "Remove a link from a task: give the task (`id` or `code`) and the link's `url`, or the link's `link_id` alone. Returns {task, removed: {id, kind, url, ...}}; a link the task does not have is an error.",
             "inputSchema": obj(["id": int, "code": str, "url": str, "link_id": int])],

            ["name": "list_gate_rules",
             "description": "The QuestBits gate's rules for a project (`project_id`/`project_code`). When QuestBits' Claude Code hooks are installed, a Bash or MCP tool call in the project's repo folder that a rule matches is not run: an approve question goes to the user, and once they approve, the exact same call is allowed once, in the same session, within 24 hours. Returns {project, defaults, rules}: `defaults` always apply (git push, gh release, gh pr merge, gh pr create, recursive rm outside the repo folder, commands that name the QuestBits database, MCP tools that send Slack or Gmail messages); `rules` are the project's own. Rule syntax: a shell command as plain words, program first (`terraform apply`, `git push --force`; words starting with - must be present too), or `tool:` and an MCP tool name where * matches anything (`tool:mcp__*__create_issue`).",
             "inputSchema": obj(["project_id": int, "project_code": str])],

            ["name": "add_gate_rule",
             "description": "Add a rule to a project's QuestBits gate (`project_id`/`project_code`), in list_gate_rules' syntax, e.g. `npm publish` or `tool:mcp__*__create_issue`. Repeat-safe (`added` false when it was already there or is a default). Agents can only add rules; the user removes them in the app (the project's Overview). Returns {project, defaults, rules, added}.",
             "inputSchema": obj(["project_id": int, "project_code": str,
                                 "rule": ["type": "string", "description": "one rule, e.g. \"npm publish\" or \"tool:mcp__*__create_issue\""] as [String: Any]],
                                required: ["rule"])],

            ["name": "list_milestones",
             "description": "A project's milestones (`project_id`/`project_code`), or with no project those of every active project, in order. A milestone is a named stage of one project (e.g. \"Phase 2 Hide\", \"v1.5.0\") that tasks count toward, beside parent/subtask. Closed ones are left out unless `include_closed` is true. Each: {id, project (code), name, done, total, open, description?, acceptance?, target_date?, closed_at?}; done/total count its tasks (subtasks included, dropped ones in neither), open counts those not done or dropped. `acceptance` is its exit criteria: a milestone whose tasks are all done is not finished until its acceptance is met and someone closes it.",
             "inputSchema": obj(["project_id": int, "project_code": str,
                                 "include_closed": ["type": "boolean", "description": "also list closed milestones (default false)"] as [String: Any]])],

            ["name": "create_milestone",
             "description": "Add a milestone at the end of a project's list (`project_id`/`project_code`, not archived). `name` is unique in the project (case-insensitive, not \"none\"). Optional `description`, `acceptance` (the exit criteria, e.g. \"CHU-29 daily driver for a week\") and `target_date`. Put tasks in it with update_task / bulk_update_tasks `milestone`. Do not create milestones from title prefixes such as \"P2.1 ·\" on your own: a prefix is a hint, not proof of the stage. Returns the milestone as list_milestones does.",
             "inputSchema": obj(["project_id": int, "project_code": str, "name": str, "description": str,
                                 "acceptance": ["type": "string", "description": "exit criteria, kept apart from the tasks"] as [String: Any],
                                 "target_date": dateStr], required: ["name"])],

            ["name": "update_milestone",
             "description": "Change a milestone, by `id` or by `name` with `project_code`/`project_id`: `new_name`, `description`, `acceptance`, `target_date` (null clears it), `closed` (true closes, false reopens). A milestone never closes by itself when its tasks are done; close it only when its acceptance is met and the user agrees. Closing one that still has open tasks is refused unless `force` is true. A closed milestone takes no new tasks (its tasks keep it). Returns the milestone.",
             "inputSchema": obj(milestoneRef.merging([
                "new_name": str, "description": str,
                "acceptance": ["type": "string", "description": "exit criteria, kept apart from the tasks"] as [String: Any],
                "target_date": dateStr,
                "closed": ["type": "boolean", "description": "true closes the milestone, false reopens it"] as [String: Any],
                "force": ["type": "boolean", "description": "close even though tasks are still open"] as [String: Any]
             ]) { a, _ in a })],

            ["name": "delete_milestone",
             "description": "Delete a milestone, by `id` or by `name` with `project_code`/`project_id`. Its tasks are kept, in no milestone. Returns {deleted (name), project, unassigned (how many tasks it had)}.",
             "inputSchema": obj(milestoneRef)],

            ["name": "list_pages",
             "description": "A project's wiki (`project_id`/`project_code`): pages that keep its decisions and notes, for agents to look up instead of asking again. Without bodies: each page is {id, kind (decision|note), title, updated_at, decided_on (decisions)}; read one with get_page. Decisions come first, newest date first, then notes by title. `kind` keeps one kind. Unless kind is note or `include_notes` is false, `decision_notes` also lists the decision notes of the project's tasks (add_note kind decision; up to 50, newest first: {note_id, task, ts, text (first line)}): they belong to the project's decisions without being copied into pages. The project's guide is not in the wiki: see get_guide.",
             "inputSchema": obj(["project_id": int, "project_code": str, "kind": pageKindEnum,
                                 "include_notes": ["type": "boolean", "description": "list the decision notes of its tasks too (default true)"] as [String: Any]])],

            ["name": "get_page",
             "description": "A wiki page in full, by `id`, or in a project (`project_code`/`project_id`) by `title` or `source_key`: {id, project, kind, title, body (markdown), version, author (who wrote the row: user|agent), created_at, updated_at, and when set: outcome and decided_on (decisions), tasks [{code, title, status}] it refers to, session, source, source_key, source_author, source_session, source_timestamp (where an imported page came from)}.",
             "inputSchema": obj(pageRef)],

            ["name": "create_page",
             "description": "Add a wiki page to a project (`project_id`/`project_code`, not archived). `kind` decision (something decided for the project: `outcome` says what, `body` why and the options not taken, `decided_on` yyyy-MM-dd defaults to today) or note (default; findings, how-tos, a running log; no outcome or decided_on). `title` one line. `tasks` (codes) or `task_ids`: the tasks it refers to, any project. A decision about one task belongs in add_note kind decision on that task; use a page for what the whole project should remember. Importers: `source` (where it came from), `source_key` (the source item's stable identity: a second create_page with the same source_key in the project returns the existing page unchanged with created false, so a rerun never duplicates), `source_author`, `source_session`, `source_timestamp` (the original's, when known; leave them out when not known). The page's author is always the agent. Returns the page as get_page, plus `created`.",
             "inputSchema": obj([
                "project_id": int, "project_code": str, "kind": pageKindEnum, "title": str,
                "body": ["type": "string", "description": "markdown"] as [String: Any],
                "outcome": ["type": "string", "description": "a decision's result, short"] as [String: Any],
                "decided_on": ["type": "string", "description": "yyyy-MM-dd; a decision's date (default today)"] as [String: Any],
                "tasks": codesArr, "task_ids": idsArr, "session": sessionStr,
                "source": ["type": "string", "description": "provenance: where the page came from, e.g. PLAN.md#Decisions"] as [String: Any],
                "source_key": ["type": "string", "description": "the source item's stable identity; makes the call repeat-safe"] as [String: Any],
                "source_author": ["type": "string", "description": "who wrote the original (only when known)"] as [String: Any],
                "source_session": ["type": "string", "description": "the session that wrote the original (only when known)"] as [String: Any],
                "source_timestamp": ["type": "string", "description": "when the original was written, ISO-8601 or yyyy-MM-dd (only when known)"] as [String: Any]
             ], required: ["title"])],

            ["name": "update_page",
             "description": "Change a wiki page, by `id` or in a project by `title`/`source_key` (only given fields change): `new_title`, `body` (replaces the text), `append` (adds a paragraph at the end instead: use it for a running log, so two sessions appending never lose each other's text; not with body), `kind`, `outcome` (null clears it), `decided_on`, `tasks`/`task_ids` (replace the page's tasks) or `add_tasks`/`add_task_ids`. Turning a decision into a note drops its outcome and date. `expected_version`: the version you read (get_page); if the page changed since, nothing is written and the error says so: read it again and redo the edit. Every change is kept (get_page_history). Returns the page as get_page.",
             "inputSchema": obj(pageRef.merging([
                "new_title": str, "body": ["type": "string", "description": "markdown; replaces the whole text"] as [String: Any],
                "append": ["type": "string", "description": "markdown paragraph to add at the end"] as [String: Any],
                "kind": pageKindEnum, "outcome": ["type": ["string", "null"], "description": "a decision's result; null clears it"] as [String: Any],
                "decided_on": ["type": "string", "description": "yyyy-MM-dd"] as [String: Any],
                "tasks": codesArr, "task_ids": idsArr, "add_tasks": codesArr, "add_task_ids": idsArr,
                "expected_version": ["type": "integer", "description": "the page's version your edit is based on"] as [String: Any],
                "session": sessionStr
             ]) { a, _ in a })],

            ["name": "delete_page",
             "description": "Delete a wiki page (by `id`, or in a project by `title`/`source_key`) and its history. Only when the user asked for it. Returns {deleted (title), id, project}.",
             "inputSchema": obj(pageRef)],

            ["name": "search_pages",
             "description": "Search the wiki before asking the user something the project may already have decided: pages whose title, outcome or body hold every word of `query` (any part of a word matches, Thai included; ASCII case-insensitive), across every project (archived too) or one (`project_id`/`project_code`), optionally one `kind`. Returns {engine (fts5: best matches first; like: newest first, used when a word is under 3 characters or full-text search is unavailable), pages [{id, project, kind, title, updated_at, decided_on?, outcome?, snippet}], decision_notes [{note_id, task, project, ts, snippet}] (decision notes of tasks holding every word; not with kind note)}. `limit` (default 20, max 100) caps each list. Read a hit with get_page or get_task.",
             "inputSchema": obj([
                "query": str, "project_id": int, "project_code": str, "kind": pageKindEnum,
                "limit": ["type": "integer", "minimum": 1, "maximum": 100] as [String: Any]
             ], required: ["query"])],

            ["name": "get_page_history",
             "description": "A wiki page's changes (by `id`, or in a project by `title`/`source_key`), newest first: {page, title, version, events [{ts, field (created, title, kind, outcome, decided_on, body, tasks), old, new, author, session}]}; body events carry the whole old and new text. `limit` default 10, max 50.",
             "inputSchema": obj(pageRef.merging([
                "limit": ["type": "integer", "minimum": 1, "maximum": 50] as [String: Any]
             ]) { a, _ in a })],

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
             "description": "Tasks completed today (local day), across every project: {date (yyyy-MM-dd), tasks_completed (top-level tasks), subtasks_completed}. Dropped tasks are not completions and never count.",
             "inputSchema": obj([:])]
        ]
    }
}
