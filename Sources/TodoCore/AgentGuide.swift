import Foundation

/// What QuestBits tells agents, shipped in the binary so it updates with the app: the MCP
/// `instructions` every session gets at connect, the built-in guide get_guide returns
/// first, and the MCP prompts (Claude Code shows them as /mcp__<server>__<name>).
/// Bump `version` whenever `instructions` or `builtIn` changes.
public enum AgentGuide {
    public static let version = "1.4.2"

    /// Short on purpose: it reaches every session of every project, so it starts with
    /// when to ignore QuestBits, and points to get_guide for the rest.
    public static let instructions = """
        QuestBits is the user's task tracker. Tasks have codes (QUE-3); every tool that takes an id also takes a code.
        Scope: use QuestBits only while this session works on a QuestBits task: the user names a task or project code, asks you to work from QuestBits, or the work is already tracked here. Otherwise ignore QuestBits entirely: don't call its tools, don't ask_user, don't write notes, and work as you normally would.
        When you work on a QuestBits task:
        - First call get_guide with the task's code. It has the full rules, the user's own rules and the project's guide; follow them.
        - When the user must decide: ask_user with 2–4 options, the one you recommend and a one-line reason, then move on to other work. Never end your turn just to wait.
        - Push, release, posting, or anything irreversible: always ask and wait for the answer.
        """

    /// The first part of every get_guide answer. The user's guide and the project's guide
    /// follow it (see the last section).
    public static let builtIn = """
        ## Scope
        Follow this guide only while you work on a QuestBits task: the user named a task or project code, asked you to work from QuestBits, or the work is already tracked here. For anything else (a quick question, routine work in a repo) ignore QuestBits and work as usual.

        ## Starting a task
        - Pick a short session label (e.g. the repo and the ticket) and pass it as `session` to ask_user, get_answers, wait_for_answers and the notes you write, so you only pick up answers to your own questions.
        - Read the task with get_task, then call get_answers and finish answered questions first (resume_question, then act on the answer).
        - Move the task to in_progress when you start on it.

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
