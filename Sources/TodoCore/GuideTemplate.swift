import Foundation

/// Starting points for a project's guide, by the kind of project: picked when a project is
/// created (the app's New Project sheet, or create_project's `guide_template`), or from the
/// Guide sheet of a project whose guide is still empty. The text becomes an ordinary guide
/// version the user edits from there. These are drafts: rewrite them from the project
/// guides people actually keep.
public enum GuideTemplate: String, CaseIterable, Identifiable, Sendable {
    case webApp = "web_app"
    case app
    case research
    case animation

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .webApp: return "Web app"
        case .app: return "App"
        case .research: return "Research"
        case .animation: return "Animation"
        }
    }

    /// The reason recorded with the guide version a template starts.
    public var reason: String { "Started from the \(label) template" }

    public var markdown: String {
        switch self {
        case .webApp:
            return """
                ## Done means
                - CI passes on the PR, not only a local build.
                - You opened the change in a browser yourself; say which pages you checked.

                ## Before asking
                - Read the repo's README and CLAUDE.md (or AGENTS.md) for how to build, test and deploy.

                ## Ask first
                - Deploys, migrations on shared data, and anything that touches production.
                """
        case .app:
            return """
                ## Done means
                - The app builds and you ran it to see the change work; say what you checked.
                - CI passes on the PR when the repo has CI.

                ## Before asking
                - Read the repo's README and CLAUDE.md (or AGENTS.md) for how to build and run it.

                ## Ask first
                - Releases, signing changes, and anything that ships to users.
                """
        case .research:
            return """
                ## Sources
                - Every conclusion cites its source: a link, or a file and line. Mark what is your own inference.
                - Prefer primary sources, and date anything that may go stale.

                ## Closing
                - End with a note of kind summary: the findings, their sources, and the open questions.
                """
        case .animation:
            return """
                ## Before exporting
                - Render a short preview (a few frames or a low-resolution clip) and show it to the user before the full export.

                ## Done means
                - The final export matches the preview the user approved; give its path, length and resolution.

                ## Files
                - Keep sources and exports apart, and never overwrite an export the user approved.
                """
        }
    }
}
