import Foundation

/// `questbits export`: a full snapshot of projects as files, one per project and format
/// (<CODE>.md, <CODE>.json), to keep or commit to a repo. Every task of any status with all
/// its notes, history, links, relations and questions; milestones; wiki pages with history;
/// the guide with every version. Images the task details link to are copied to
/// attachments/ beside them. A readable snapshot, not a database backup (that is the app's
/// Settings → Export Backup).
enum ExportCommand {
    static let command = CLICommand(
        name: "export",
        usage: "export [--project <code>]... [--include-archived] [--format md|json|both] [--out <dir>|-]",
        summary: "Write a full snapshot of projects as markdown and/or JSON, one file per project.",
        details: """
        --project <code>    a project to export (repeat, or comma-separate; archived ones too).
                            Default: every active project, plus index.md/index.json with the
                            guide for all projects.
        --include-archived  with no --project: archived projects too
        --format            md (default), json, or both
        --out <dir>         folder to write to (default: ./questbits-export); files in it are
                            replaced. "-" prints one project's snapshot to stdout instead.
        """,
        options: ["project", "format", "out"],
        flags: ["include-archived"],
        run: { try run($0, $1) })

    private struct Output {
        var files: [(name: String, content: String)] = []
        var attachments: [URL] = []
        var summary: [String] = []
    }

    static func run(_ args: CLIArgs, _ ctx: CLIContext) throws -> Int32 {
        guard args.positionals.isEmpty else { throw CLIError.usage("unexpected argument '\(args.positionals[0])'") }
        let format = args.value("format") ?? "md"
        guard ["md", "json", "both"].contains(format) else { throw CLIError.usage("--format must be md, json or both") }
        let codes = args.list("project")
        let toStdout = args.value("out") == "-"
        if toStdout && (codes.count != 1 || format == "both") {
            throw CLIError.usage("--out - prints one project in one format: give one --project and --format md or json")
        }
        try ctx.requireDatabase()
        let output = try ctx.withStore { store in
            try build(codes: codes, includeArchived: args.has("include-archived"), format: format, store: store)
        }
        if toStdout {
            ctx.write(output.files.first?.content ?? "")
            return 0
        }
        let dir = URL(fileURLWithPath: ctx.absolutePath(args.value("out") ?? "questbits-export"), isDirectory: true)
        try write(output, to: dir)
        ctx.write(output.summary.joined(separator: "\n") + "\nWrote \(output.files.count) files to \(dir.path)\n")
        return 0
    }

    private static func build(codes: [String], includeArchived: Bool, format: String, store: Store) throws -> Output {
        let projects: [Project]
        if codes.isEmpty {
            projects = try store.listProjects(includeArchived: includeArchived)
        } else {
            let all = try store.listProjects(includeArchived: true)
            projects = try codes.map { code in
                guard let pid = store.projectId(forCode: code), let p = all.first(where: { $0.id == pid }) else {
                    throw CLIError.failure("no project with code \(code)")
                }
                return p
            }
        }
        var out = Output()
        var seen = Set<String>()
        for p in projects {
            let snapshot = try ProjectSnapshot.read(p, store: store)
            if format != "json" { out.files.append(("\(p.code).md", ExportMarkdown.project(snapshot))) }
            if format != "md" { out.files.append(("\(p.code).json", try Fmt.json(ExportJSON.project(snapshot)))) }
            for path in snapshot.attachmentPaths {
                if let file = store.attachmentFile(path), seen.insert(file.path).inserted,
                   FileManager.default.fileExists(atPath: file.path) {
                    out.attachments.append(file)
                }
            }
            out.summary.append("\(p.code): " + snapshot.counts.filter { $0.value > 0 || $0.key == "tasks" }
                .map { "\($0.key)=\($0.value)" }.joined(separator: " "))
        }
        if codes.isEmpty { out.files += try index(projects, format: format, store: store) }
        return out
    }

    /// index.md / index.json for a whole export: when it was made, the projects in it, and
    /// the guide for all projects (not part of any one project's file).
    private static func index(_ projects: [Project], format: String, store: Store) throws -> [(name: String, content: String)] {
        let guides = try store.guideHistory(projectId: nil, limit: ProjectSnapshot.unlimited)
        let now = Fmt.iso(Date())
        var files: [(name: String, content: String)] = []
        if format != "json" {
            var md = ["# QuestBits export", "", "Exported \(now).", "", "## Projects", ""]
            md += projects.map { "- [\($0.code) · \($0.name)](\($0.code).md)" + ($0.isArchived ? " (archived)" : "") }
            if let current = guides.first {
                md += ["", "## Guide for all projects", "",
                       "Version \(current.id) · \(Fmt.iso(current.timestamp)) · \(current.author.rawValue)", "",
                       Fmt.quote(current.markdown)]
                for g in guides.dropFirst() {
                    md += ["", "### Earlier version \(g.id) · \(Fmt.iso(g.timestamp)) · \(g.author.rawValue)", "",
                           Fmt.quote(g.markdown)]
                }
            }
            files.append(("index.md", md.joined(separator: "\n") + "\n"))
        }
        if format != "md" {
            let obj: [String: Any] = ["exported_at": now,
                                      "projects": projects.map { ["code": $0.code, "name": $0.name, "file": "\($0.code).json"] },
                                      "guide_versions": guides.map(ExportJSON.guide)]
            files.append(("index.json", try Fmt.json(obj)))
        }
        return files
    }

    private static func write(_ output: Output, to dir: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        for f in output.files {
            try Data(f.content.utf8).write(to: dir.appendingPathComponent(f.name), options: .atomic)
        }
        guard !output.attachments.isEmpty else { return }
        let target = dir.appendingPathComponent("attachments", isDirectory: true)
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        for src in output.attachments {
            let dest = target.appendingPathComponent(src.lastPathComponent)
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.copyItem(at: src, to: dest)
        }
    }
}
