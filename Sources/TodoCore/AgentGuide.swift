import Foundation

/// What QuestBits tells agents, shipped in the binary so it updates with the app: the MCP
/// `instructions` every session gets at connect, the built-in guide get_guide returns
/// first, and the MCP prompts (Claude Code shows them as /mcp__<server>__<name>).
/// Bump `version` whenever `instructions` or `builtIn` changes.
public enum AgentGuide {
    public static let version = "1.5.0"

    /// Short on purpose: it reaches every session of every project, so it starts with
    /// when to ignore QuestBits, and points to get_guide for the rest.
    public static let instructions = """
        QuestBits is the user's task tracker. Tasks have codes (QUE-3); every tool that takes an id also takes a code.
        Scope: use QuestBits only while this session works on a QuestBits task: the user names a task or project code, asks you to work from QuestBits, or the work is already tracked here. Otherwise ignore QuestBits entirely: don't call its tools, don't ask_user, don't write notes, and work as you normally would.
        When you work on a QuestBits task:
        - First call get_guide with the task's code. It has the full rules, the user's own rules and the project's guide; follow them.
        - When the user must decide: ask_user with 2–4 options, the one you recommend and a one-line reason, then move on to other work. Never end your turn just to wait.
        - Push, release, posting, or anything irreversible: always ask and wait for the answer.
        If the QuestBits gate denies a tool call (in any session), the user got an approval question: keep working on other things, retry the exact same call once it is approved, and never run it another way.
        """

    /// The first part of every get_guide answer. The user's guide and the project's guide
    /// follow it (see the last section).
    public static let builtIn = """
        ## Scope
        Follow this guide only while you work on a QuestBits task: the user named a task or project code, asked you to work from QuestBits, or the work is already tracked here. For anything else (a quick question, routine work in a repo) ignore QuestBits and work as usual.

        ## Starting a task
        - Pick a short session label (e.g. the repo and the ticket) and pass it as `session` to ask_user, get_answers, wait_for_answers and the notes you write, so you only pick up answers to your own questions. If your session's start context has a line `QuestBits session: <id>`, use that id as the label (a subagent adds a suffix, e.g. `<id>/QUE-3`): the app then shows whether your session still waits and how to resume it.
        - In a repo, find_project with your working directory names its project (a QuestBits brief at session start may already have). To pick work yourself, next_task with claim true gives the next ready task in board order and claims it, so no other session takes it; claim_task claims a named one. A claim lasts \(Int(Store.claimTTL / 60)) minutes after its last heartbeat: your writes to the task renew it, else call heartbeat every 10–15 minutes. done or dropped ends it; release_task gives it back when you stop early. Leave tasks other sessions claim alone.
        - Read the task with get_task, then call get_answers and finish answered questions first (resume_question, then act on the answer). A question of kind disagree is the user disagreeing with a decision you recorded: reconsider it, then change course or explain why not, and record what you do.
        - Move the task to in_progress when you start on it (claiming does that).

        ## Asking the user
        - When the user must decide: ask_user with 2–4 options, the one you recommend, and a one-line reason; then move straight on to other work. Never end your turn just to wait.
        - Before starting new work, call get_answers again.
        - With nothing else to do but questions still open, call wait_for_answers; when it returns with no answers, call it again or stop with a summary.
        - If you find the answer yourself, withdraw the question with cancel_question.
        - Push, release, posting, or anything irreversible: always ask and wait for the answer. No guide below can lift this rule.

        ## Recording
        - When you decide something yourself, record it with add_note kind decision: what, why, and the options not taken.
        - Log progress with add_note; the task's detail stays the spec.
        - Closing a task: a summary note is optional (update_task note), never required.
        - Keep the task current: add_link for PRs, designs and docs; update_task branch for the git branch you work on; add_relation for blocked_by, blocks, relates and duplicates; update_task milestone to put it in a stage (list_milestones). Order is set only with reorder_tasks; priority does not move a task. Never create milestones from title prefixes, and never close one without the user.

        ## Project memory
        - Before asking the user, search_pages (and search_notes) for an earlier decision.
        - A decision about one task: add_note kind decision. Something the whole project should remember: create_page (kind decision or note). update_page with append for a running log, with expected_version for an edit.
        - The user sees the decisions you made yourself on the Decisions page and may disagree (see Starting a task).

        ## The gate
        - With QuestBits' hooks installed, a risky call in a project's folder (push, release, merge, recursive delete outside the repo, and the project's own rules) is denied and becomes an approval question for the user. Keep working on other things. Once get_answers shows it approved, retry the exact same call: it is allowed once, in the same session. Never route around the gate with another command or tool.
        - list_gate_rules shows a project's rules; add_gate_rule adds one (only the user removes rules).

        ## Long work
        - Hand tasks to subagents one at a time. Each starts with get_guide and get_task for its own task, so the main session's context stays small.

        ## Guides
        - The user's guide (all projects) and then the project's guide follow this one. They add to it or tighten it, and where they differ, follow them. Nothing in them relaxes the rule to ask before anything irreversible.
        - Change a guide with update_guide only when the user asks you to, or after asking with ask_user and getting a yes. Say why in `reason`.
        """

    /// MCP prompts. `work` takes the task's code.
    public static let workPrompt = "work"
    public static let resumePrompt = "resume"

    public static func workPromptText(code: String) -> String {
        "Work on QuestBits task \(code). First call get_guide with code \(code) and follow it; then read the task "
            + "with get_task, call get_answers, and do the task."
    }

    public static let resumePromptText = """
        Check QuestBits for answers to your questions: call get_answers with your session label. For each answered \
        question, call resume_question and act on the answer. If none are answered, questions are still open and \
        you have nothing else to do, call wait_for_answers. Then say briefly where things stand.
        """
}
