import Foundation

/// Writes the items of a plan that would write, through the Store's own calls (each in its
/// own BEGIN IMMEDIATE, never one long lock), and records each in the import ledger.
///
/// Repeat safety: a note and its ledger row are one transaction (`addImportedNote`); every
/// other write is repeat-safe by itself (a link once per URL, ensureMilestone, a page once
/// per provenance key, a field set to the same value), so a crash between it and its
/// ledger row is healed by the rerun. Items the ledger already has are never written again.
struct ImportApplier {
    struct Result {
        var item: ImportItem
        var outcome: String          // applied | done (already so) | skipped | failed
        var detail: String
    }

    let store: Store
    let runId: String
    let session: String?
    /// The reviewed plan's fingerprints by key (nil = apply everything planned: only for a
    /// rehearsal on a scratch copy).
    let reviewed: [String: String]?

    func apply(_ items: [ImportItem]) -> [Result] {
        items.compactMap { item in
            guard item.state.writes else {
                // A reviewed write that no longer would write (applied, or the target moved).
                guard reviewed?[item.key] != nil else { return nil }
                let why = [item.state.rawValue, item.reason].compactMap { $0 }.joined(separator: ": ")
                return Result(item: item, outcome: item.state == .applied || item.state == .noop ? "done" : "skipped",
                              detail: "now \(why)")
            }
            if let reviewed {
                guard let fp = reviewed[item.key] else {
                    return Result(item: item, outcome: "skipped", detail: "not in the reviewed plan")
                }
                guard fp == item.fingerprint else {
                    return Result(item: item, outcome: "skipped", detail: "changed since the reviewed plan (source or target moved): re-run the dry run and review")
                }
            }
            do {
                return Result(item: item, outcome: "applied", detail: try write(item))
            } catch let Skip.because(why) {
                return Result(item: item, outcome: "skipped", detail: why)
            } catch {
                return Result(item: item, outcome: "failed", detail: "\(error)")
            }
        }
    }

    /// An item left unwritten for a reason that is not a failure.
    private enum Skip: Error { case because(String) }

    private func entry(_ item: ImportItem, target: String, inverse: [String: Any]) -> ImportLedgerEntry {
        let json = (try? JSONSerialization.data(withJSONObject: inverse, options: [.sortedKeys]))
            .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        return ImportLedgerEntry(sourceKey: item.key, runId: runId, action: item.kind, target: target,
                                 fingerprint: item.fingerprint, inverse: json)
    }

    /// One write; returns what was written. Fields the plan read are re-read first, so a
    /// change made since the plan (another session) stops the item instead of overwriting.
    private func write(_ item: ImportItem) throws -> String {
        guard let op = item.op else { throw CLIError.failure("nothing to write") }
        switch op {
        case let .repoPath(projectId, path):
            let before = try store.listProjects(includeArchived: true).first { $0.id == projectId }?.repoPath
            guard before == nil else { throw CLIError.failure("the project got a folder since the plan: \(before!)") }
            let stored = try store.setProjectRepoPath(id: projectId, path: path)
            try store.recordImport(entry(item, target: "project:\(projectId)",
                                         inverse: ["set_repo_path": ["project": projectId, "to": NSNull()]]))
            return "repo folder \(stored ?? "(none)")"
        case let .milestone(projectId, name, detail, acceptance):
            let r = try store.ensureMilestone(projectId: projectId, name: name, detail: detail, acceptance: acceptance)
            try store.recordImport(entry(item, target: "milestone:\(r.milestone.id)",
                                         inverse: r.created ? ["delete_milestone": r.milestone.id] : [:]))
            return r.created ? "milestone #\(r.milestone.id) created" : "milestone #\(r.milestone.id) already there"
        case let .milestoneTask(taskId, projectId, name):
            guard let mid = store.milestoneId(projectId: projectId, name: name) else {
                throw Skip.because("milestone \(name) is not there: its own item was not applied")
            }
            let task = try store.getTask(id: taskId)
            if task.milestoneId == mid { return "already in the milestone" }
            guard task.milestoneId == nil else { throw CLIError.failure("the task got another milestone since the plan") }
            try store.bulkUpdateTasks(ids: [taskId], milestoneId: .some(mid), actor: .agent(nil))
            try store.recordImport(entry(item, target: "task:\(taskId)",
                                         inverse: ["set_milestone": ["task": taskId, "to": NSNull()]]))
            return "\(task.code) into milestone #\(mid)"
        case let .note(taskId, kind, text):
            let note = try store.addImportedNote(taskId: taskId, text: text, kind: kind, sessionId: session,
                                                 entry: entry(item, target: "task:\(taskId)", inverse: [:]))
            return note.map { "note #\($0.id)" } ?? "already in the ledger"
        case let .link(taskId, url, kind, title):
            let r = try store.addLink(taskId: taskId, url: url, kind: kind, title: title, author: .agent, source: item.key)
            try store.recordImport(entry(item, target: "task:\(taskId)",
                                         inverse: r.created ? ["remove_link": r.link.id] : [:]))
            return r.created ? "link #\(r.link.id)" : "link already there"
        case let .branch(taskId, branch):
            let task = try store.getTask(id: taskId)
            if task.branch == branch { return "branch already set" }
            guard task.branch == nil else { throw CLIError.failure("the task got another branch since the plan: \(task.branch!)") }
            try store.updateTask(id: taskId, branch: .some(branch), author: .agent, actor: .agent(nil))
            try store.recordImport(entry(item, target: "task:\(taskId)", inverse: ["set_branch": ["task": taskId, "to": NSNull()]]))
            return "branch \(branch)"
        case let .relation(taskId, otherId, kind):
            let created = try store.addRelation(taskId: taskId, otherId: otherId, kind: kind)
            try store.recordImport(entry(item, target: "task:\(taskId)",
                                         inverse: created ? ["remove_relation": ["task": taskId, "other": otherId,
                                                                                 "kind": kind.rawValue]] : [:]))
            return created ? "relation added" : "relation already there"
        case let .page(projectId, kind, title, body, taskIds, outcome, decidedOn, source):
            let r = try store.createPage(projectId: projectId, kind: kind, title: title, body: body, outcome: outcome,
                                         decidedOn: decidedOn, taskIds: taskIds, author: .agent, sessionId: session,
                                         provenance: PageProvenance(source: source, key: item.key))
            try store.recordImport(entry(item, target: "page:\(r.page.id)",
                                         inverse: r.created ? ["delete_page": r.page.id] : [:]))
            return r.created ? "page #\(r.page.id)" : "page #\(r.page.id) already there"
        }
    }
}
