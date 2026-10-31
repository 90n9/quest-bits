import Foundation

/// The mapping `questbits import` reads (JSON): which source items go where. It lives with
/// the user's data, never in this repo. Every source item named here gets a `key`; the
/// importer builds each item's source_key from it (`<namespace>:<project>/<kind>/<key>`),
/// so keys must stay the same between the dry run that was reviewed and the apply.
///
/// Nothing in it is applied blindly: the dry run shows every item with what it would
/// write, and the apply writes only items the reviewed plan has with the same fingerprint.
struct ImportConfig: Decodable {
    /// Prefix of every source_key, e.g. "que22". Change it and every item is new again.
    var namespace: String
    /// Session label on the notes and pages the import writes.
    var session: String?
    /// Source files read for quotes and hashes (read-only; never written).
    var sources: [SourceFile] = []
    var workState: WorkState?
    var projects: [ProjectMap] = []
    /// Projects deliberately left out, with why. A project in the database that is neither
    /// here nor in `projects` is reported unresolved.
    var outOfScopeProjects: [Skip] = []

    enum CodingKeys: String, CodingKey {
        case namespace, session, sources, projects
        case workState = "work_state", outOfScopeProjects = "out_of_scope_projects"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        namespace = try c.decode(String.self, forKey: .namespace)
        session = try c.decodeIfPresent(String.self, forKey: .session)
        sources = try c.decodeIfPresent([SourceFile].self, forKey: .sources) ?? []
        workState = try c.decodeIfPresent(WorkState.self, forKey: .workState)
        projects = try c.decodeIfPresent([ProjectMap].self, forKey: .projects) ?? []
        outOfScopeProjects = try c.decodeIfPresent([Skip].self, forKey: .outOfScopeProjects) ?? []
    }

    static func load(_ url: URL) throws -> ImportConfig {
        let data = try Data(contentsOf: url)
        do {
            let config = try JSONDecoder().decode(ImportConfig.self, from: data)
            guard !config.namespace.isEmpty, !config.namespace.contains(":") else {
                throw CLIError.failure("config: namespace must be non-empty, without ':'")
            }
            return config
        } catch let error as DecodingError {
            throw CLIError.failure("config \(url.lastPathComponent): \(Self.describe(error))")
        }
    }

    private static func describe(_ e: DecodingError) -> String {
        func path(_ c: DecodingError.Context) -> String { c.codingPath.map(\.stringValue).joined(separator: ".") }
        switch e {
        case .keyNotFound(let k, let c): return "missing \(k.stringValue) at \(path(c))"
        case .typeMismatch(_, let c), .valueNotFound(_, let c), .dataCorrupted(let c):
            return "\(c.debugDescription) at \(path(c))"
        @unknown default: return "\(e)"
        }
    }

    /// A file the mapping quotes from. `disposition` says what happens to the file as a
    /// whole: mapped (its items are mapped below), retained (stays in its repo as is).
    struct SourceFile: Decodable {
        var key: String
        var project: String
        var path: String
        var sha256: String?          // as the mapping was written against; a mismatch is reported
        var disposition: String = "mapped"
        var reason: String?

        enum CodingKeys: String, CodingKey { case key, project, path, sha256, disposition, reason }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            key = try c.decode(String.self, forKey: .key)
            project = try c.decode(String.self, forKey: .project)
            path = try c.decode(String.self, forKey: .path)
            sha256 = try c.decodeIfPresent(String.self, forKey: .sha256)
            disposition = try c.decodeIfPresent(String.self, forKey: .disposition) ?? "mapped"
            reason = try c.decodeIfPresent(String.self, forKey: .reason)
        }
    }

    /// Where in a source file an item comes from: one line holding `lineContains` (it must
    /// match exactly one line; `lines` takes that many lines from there), or a whole
    /// `section` (a heading line as written, up to the next heading of the same or a
    /// higher level). The text found is quoted into the note or page.
    struct SourceRef: Decodable {
        var file: String
        var lineContains: String?
        var lines: Int?
        var section: String?

        enum CodingKeys: String, CodingKey {
            case file, lines, section
            case lineContains = "line_contains"
        }
    }

    /// claude-mem work_state lists (append-only partial-field events), read from its
    /// SQLite database opened read-only.
    struct WorkState: Decodable {
        var db: String
        var lists: [LoopList] = []
        /// Lists deliberately left out (`project` "*" matches any). Any other list in the
        /// database is reported unresolved.
        var outOfScope: [ListSkip] = []

        enum CodingKeys: String, CodingKey { case db, lists, outOfScope = "out_of_scope" }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            db = try c.decode(String.self, forKey: .db)
            lists = try c.decodeIfPresent([LoopList].self, forKey: .lists) ?? []
            outOfScope = try c.decodeIfPresent([ListSkip].self, forKey: .outOfScope) ?? []
        }
    }

    struct ListSkip: Decodable {
        var project: String
        var list: String
        var reason: String
    }

    /// One list, split into work items by the `groupBy` field (events that do not set it
    /// belong to the item of the last event that did); no `groupBy` = the whole list is one
    /// item, labelled "*". Every item found must be in `items` or `skipItems`.
    struct LoopList: Decodable {
        var project: String
        var list: String
        var target: String               // the QuestBits project code the items belong to
        var groupBy: String?
        var items: [LoopItem] = []
        var skipItems: [LoopItem] = []

        enum CodingKeys: String, CodingKey {
            case project, list, target, items
            case groupBy = "group_by", skipItems = "skip_items"
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            project = try c.decode(String.self, forKey: .project)
            list = try c.decode(String.self, forKey: .list)
            target = try c.decode(String.self, forKey: .target)
            groupBy = try c.decodeIfPresent(String.self, forKey: .groupBy)
            items = try c.decodeIfPresent([LoopItem].self, forKey: .items) ?? []
            skipItems = try c.decodeIfPresent([LoopItem].self, forKey: .skipItems) ?? []
        }
    }

    /// A work item of a list, matched by `label` (the group_by field's value). `events` are
    /// the entry ids reviewed: an event added since (or one gone) makes the item drifted.
    /// `tasks`: the tasks it is evidence for (many-to-many). `history`: note (one note per
    /// task), page (one wiki note linked to the tasks) or none. `links`: add each
    /// work_product URL to every task. `branch`: set (the item's one branch becomes each
    /// task's branch when it has none, else a branch link), link (branch links only), none.
    struct LoopItem: Decodable {
        var label: String
        var events: [Int64] = []
        var tasks: [String] = []
        var history: String = "note"
        var links: Bool = true
        var branch: String = "set"
        var reason: String?

        enum CodingKeys: String, CodingKey { case label, events, tasks, history, links, branch, reason }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            label = try c.decode(String.self, forKey: .label)
            events = try c.decodeIfPresent([Int64].self, forKey: .events) ?? []
            tasks = try c.decodeIfPresent([String].self, forKey: .tasks) ?? []
            history = try c.decodeIfPresent(String.self, forKey: .history) ?? "note"
            links = try c.decodeIfPresent(Bool.self, forKey: .links) ?? true
            branch = try c.decodeIfPresent(String.self, forKey: .branch) ?? "set"
            reason = try c.decodeIfPresent(String.self, forKey: .reason)
        }
    }

    /// One QuestBits project and what to write to it. `repoPath`: absent = leave it alone;
    /// "" = it must have none (reported as a conflict when it has one); a path = set it
    /// when the project has none.
    struct ProjectMap: Decodable {
        var code: String
        var repoPath: String?
        var milestones: [MilestoneMap] = []
        var notes: [NoteMap] = []
        var links: [LinkMap] = []
        var branches: [BranchMap] = []
        var relations: [RelationMap] = []
        var pages: [PageMap] = []
        var dispositions: [Disposition] = []

        enum CodingKeys: String, CodingKey {
            case code, milestones, notes, links, branches, relations, pages, dispositions
            case repoPath = "repo_path"
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            code = try c.decode(String.self, forKey: .code)
            repoPath = try c.decodeIfPresent(String.self, forKey: .repoPath)
            milestones = try c.decodeIfPresent([MilestoneMap].self, forKey: .milestones) ?? []
            notes = try c.decodeIfPresent([NoteMap].self, forKey: .notes) ?? []
            links = try c.decodeIfPresent([LinkMap].self, forKey: .links) ?? []
            branches = try c.decodeIfPresent([BranchMap].self, forKey: .branches) ?? []
            relations = try c.decodeIfPresent([RelationMap].self, forKey: .relations) ?? []
            pages = try c.decodeIfPresent([PageMap].self, forKey: .pages) ?? []
            dispositions = try c.decodeIfPresent([Disposition].self, forKey: .dispositions) ?? []
        }
    }

    /// A milestone (made with ensureMilestone, so an existing one of that name is reused
    /// as it is) and the tasks put in it; `withSubtasks` adds each listed task's subtasks.
    /// A task already in another milestone is a conflict, never moved.
    struct MilestoneMap: Decodable {
        var key: String
        var name: String
        var detail: String?
        var acceptance: String?
        var tasks: [String] = []
        var withSubtasks: Bool?
        var source: SourceRef?
        var reason: String?

        enum CodingKeys: String, CodingKey {
            case key, name, detail, acceptance, tasks, source, reason
            case withSubtasks = "with_subtasks"
        }
    }

    /// A note on a task: `text` (may be empty) followed by the quoted source text.
    struct NoteMap: Decodable {
        var key: String
        var task: String
        var kind: String?
        var text: String?
        var source: SourceRef?
        var reason: String?
    }

    struct LinkMap: Decodable {
        var key: String
        var task: String
        var url: String
        var kind: String?
        var title: String?
        var reason: String?
    }

    /// The task's working branch: set when it has none; equal = nothing to do; another
    /// branch = a conflict (the task's branch is never replaced).
    struct BranchMap: Decodable {
        var key: String
        var task: String
        var branch: String
        var reason: String?
    }

    struct RelationMap: Decodable {
        var key: String
        var task: String
        var other: String
        var kind: String
        var reason: String?
    }

    /// A wiki page (createPage with provenance key = the item's source_key: never twice).
    /// `body` (may be empty) is followed by the quoted source text.
    struct PageMap: Decodable {
        var key: String
        var kind: String?
        var title: String
        var body: String?
        var tasks: [String]?
        var outcome: String?
        var decidedOn: String?
        var source: SourceRef?
        var reason: String?

        enum CodingKeys: String, CodingKey {
            case key, kind, title, body, tasks, outcome, source, reason
            case decidedOn = "decided_on"
        }
    }

    /// A source item that writes nothing, with why: matched (already covered by these
    /// tasks), retained (stays in its repo), skip, unresolved (needs a decision), conflict.
    struct Disposition: Decodable {
        var key: String
        var disposition: String
        var reason: String
        var tasks: [String]?
        var source: SourceRef?
    }

    struct Skip: Decodable {
        var code: String
        var reason: String
    }
}
