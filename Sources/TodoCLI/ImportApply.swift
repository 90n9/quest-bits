import Foundation

/// Writes the items of a plan that would write, through the Store (each item in its own
/// BEGIN IMMEDIATE, never one long lock), and records each in the import ledger.
///
/// Crash and repeat safety: every write and its ledger row (with the write's inverse) are
/// one transaction (`Store.importWrite`, `addImportedNote` for a note), and the checks that
/// the target is still as the plan read it run inside it too. Items the ledger already has
/// are never written again.
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
                if case let .note(taskId, kind, text)? = item.op {
                    return Result(item: item, outcome: "applied", detail: try writeNote(item, taskId: taskId, kind: kind, text: text))
                }
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

    /// One write; returns what was written. Each runs in `Store.importWrite`: the fields
    /// the plan read are re-read inside the write's transaction, so a change made since the
    /// plan (another session) stops the item instead of overwriting, and the ledger row,
    /// with the write's inverse, is written in that same transaction.
    private func write(_ item: ImportItem) throws -> String {
        guard let op = item.op else { throw CLIError.failure("nothing to write") }
        typealias Out = (result: String, entry: ImportLedgerEntry?)
        let done = try store.importWrite(key: item.key) { (w: Store.ImportWriter) throws -> Out in
            switch op {
            case let .repoPath(projectId, path):
                let stored = try w.setRepoPathIfUnset(projectId: projectId, path: path)
                return ("repo folder \(stored ?? "(none)")",
                        entry(item, target: "project:\(projectId)", inverse: ["set_repo_path": ["project": projectId, "to": NSNull()]]))
            case let .milestone(projectId, name, detail, acceptance):
                let r = try w.ensureMilestone(projectId: projectId, name: name, detail: detail, acceptance: acceptance)
                return (r.created ? "milestone #\(r.milestone.id) created" : "milestone #\(r.milestone.id) already there",
                        entry(item, target: "milestone:\(r.milestone.id)",
                              inverse: r.created ? ["delete_milestone": r.milestone.id] : [:]))
            case let .milestoneTask(taskId, projectId, name):
                guard let mid = w.milestoneId(projectId: projectId, name: name) else {
                    throw Skip.because("milestone \(name) is not there: its own item was not applied")
                }
                guard try w.setMilestoneIfUnset(taskId: taskId, milestoneId: mid) else { return ("already in the milestone", nil) }
                return ("into milestone #\(mid)",
                        entry(item, target: "task:\(taskId)", inverse: ["set_milestone": ["task": taskId, "to": NSNull()]]))
            case .note:
                throw CLIError.failure("a note is written by addImportedNote")
            case let .link(taskId, url, kind, title):
                let r = try w.addLink(taskId: taskId, url: url, kind: kind, title: title, author: .agent, source: item.key)
                return (r.created ? "link #\(r.link.id)" : "link already there",
                        entry(item, target: "task:\(taskId)", inverse: r.created ? ["remove_link": r.link.id] : [:]))
            case let .branch(taskId, branch):
                guard try w.setBranchIfUnset(taskId: taskId, branch: branch, author: .agent) else { return ("branch already set", nil) }
                return ("branch \(branch)",
                        entry(item, target: "task:\(taskId)", inverse: ["set_branch": ["task": taskId, "to": NSNull()]]))
            case let .relation(taskId, otherId, kind):
                let created = try w.addRelation(taskId: taskId, otherId: otherId, kind: kind)
                return (created ? "relation added" : "relation already there",
                        entry(item, target: "task:\(taskId)",
                              inverse: created ? ["remove_relation": ["task": taskId, "other": otherId, "kind": kind.rawValue]] : [:]))
            case let .page(projectId, kind, title, body, taskIds, outcome, decidedOn, source, timestamp):
                let r = try w.createPage(projectId: projectId, kind: kind, title: title, body: body, outcome: outcome,
                                         decidedOn: decidedOn, taskIds: taskIds, sessionId: session,
                                         provenance: PageProvenance(source: source, key: item.key, timestamp: timestamp))
                return (r.created ? "page #\(r.page.id)" : "page #\(r.page.id) already there",
                        entry(item, target: "page:\(r.page.id)", inverse: r.created ? ["delete_page": r.page.id] : [:]))
            }
        }
        return done ?? "already in the ledger"
    }

    /// A note and its ledger row: `Store.addImportedNote` (one transaction).
    private func writeNote(_ item: ImportItem, taskId: Int64, kind: NoteKind, text: String) throws -> String {
        let note = try store.addImportedNote(taskId: taskId, text: text, kind: kind, sessionId: session,
                                             entry: entry(item, target: "task:\(taskId)", inverse: [:]))
        return note.map { "note #\($0.id)" } ?? "already in the ledger"
    }
}
