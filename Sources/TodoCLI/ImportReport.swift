import Foundation

/// The markdown `questbits import` writes for a reviewer: one manifest per project, a
/// summary, and the apply report. Written to explain itself: what each state means, what
/// would be written, before and after, and where each item came from.
enum ImportReport {
    struct Header {
        let generated: String
        let config: String
        let configSHA: String
        let db: String
        let namespace: String
    }

    struct Rehearsal {
        let first: [ImportApplier.Result]
        let replanned: [ImportItem]
        let second: [ImportApplier.Result]
        let copy: String
    }

    static let legend = """
    States: **create** / **update** = the apply would write this (nothing else is ever written) · \
    **noop** = the target already is so · **applied** = in the import ledger from an earlier run · \
    **conflict** = the target disagrees with the mapping (never overwritten) · **drifted** = the source \
    changed since the mapping was written · **error** = bad reference in the mapping · \
    **unresolved** = a source item with no mapping, or one that needs a decision · \
    **matched** / **retained** / **skip** = a disposition that writes nothing (already covered by \
    existing tasks / stays in its repo / left out on purpose). Task statuses, claims and existing \
    fields are never changed; notes and links are only added.
    """

    private static let attention: [ImportItem.State] = [.unresolved, .conflict, .drifted, .error]
    private static let order: [ImportItem.State] = [.unresolved, .conflict, .drifted, .error, .create, .update,
                                                   .noop, .applied, .matched, .retained, .skip]

    private static func headerLines(_ h: Header, title: String) -> [String] {
        ["# \(title)", "",
         "Generated \(h.generated) · mapping `\(h.config)` (sha256 \(h.configSHA.prefix(12))) · database `\(h.db)` "
            + "(read through a backup copy) · source keys `\(h.namespace):…`", "", legend, ""]
    }

    static func counts(_ items: [ImportItem]) -> String {
        order.compactMap { s in
            let n = items.filter { $0.state == s }.count
            return n > 0 ? "\(s.rawValue) \(n)" : nil
        }.joined(separator: " · ")
    }

    // MARK: - Per project

    static func manifest(_ project: String, _ items: [ImportItem], header: Header) -> String {
        var md = headerLines(header, title: "Import manifest · \(project)")
        md += ["**\(items.count) items:** \(counts(items))", ""]
        let needs = items.filter { attention.contains($0.state) }
        if !needs.isEmpty {
            md += ["## Needs review (\(needs.count))", "", "Nothing here is written. Each needs a mapping change, a decision, or acceptance as is.", ""]
            md += needs.flatMap(detail)
        }
        let writes = items.filter { $0.state.writes }
        if !writes.isEmpty {
            md += ["## Would write (\(writes.count))", ""]
            md += writes.flatMap(detail)
        }
        let rest = items.filter { !$0.state.writes && !attention.contains($0.state) }
        if !rest.isEmpty {
            md += ["## Writes nothing (\(rest.count))", "", "| State | Kind | Target | What | Source | Reason |", "|---|---|---|---|---|---|"]
            md += rest.map { "| \($0.state.rawValue) | \($0.kind) | \(cell($0.target)) | \(cell($0.summary)) | \(cell($0.source ?? "")) | \(cell($0.reason ?? "")) |" }
            for i in rest where i.payload != nil && i.kind == "disposition" {
                md += ["", "Quoted for `\(i.key)`:", "", i.payload!]
            }
        }
        return md.joined(separator: "\n") + "\n"
    }

    private static func detail(_ i: ImportItem) -> [String] {
        var md = ["### \(i.state.rawValue) · \(i.kind) · \(i.target)", "", "- key: `\(i.key)`", "- what: \(i.summary)"]
        if i.before != nil || i.after != nil { md.append("- change: \(i.before ?? "—") → \(i.after ?? "—")") }
        if let s = i.source { md.append("- source: \(s)") }
        if let r = i.reason, !r.isEmpty { md.append("- reason: \(r)") }
        if let p = i.payload {
            md += ["- text written:", "", "````text", p, "````"]
        }
        md.append("")
        return md
    }

    private static func cell(_ s: String) -> String {
        Fmt.oneLine(s, max: 300).replacingOccurrences(of: "|", with: "\\|")
    }

    // MARK: - Summary

    static func summary(_ items: [ImportItem], header: Header, files: [String: ImportSources.File],
                        rehearsal: Rehearsal, applyCommand: String) -> String {
        var md = headerLines(header, title: "Import dry run · summary")
        md += ["## Counts per project", "", "| Project | Items | " + order.map(\.rawValue).joined(separator: " | ") + " |",
               "|---|---:|" + order.map { _ in "---:" }.joined(separator: "|") + "|"]
        var projects: [String] = []
        for i in items where !projects.contains(i.project) { projects.append(i.project) }
        for p in projects {
            let its = items.filter { $0.project == p }
            md.append("| [\(p)](manifest-\(p.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" }.map(String.init).joined()).md) | \(its.count) | "
                      + order.map { s in String(its.filter { $0.state == s }.count) }.joined(separator: " | ") + " |")
        }
        md += ["", "**Total \(items.count):** \(counts(items))", ""]
        let needs = items.filter { attention.contains($0.state) }
        md += ["## Needs review (\(needs.count))", ""]
        md += needs.isEmpty ? ["None."] : ["| Project | State | Kind | Target | What | Reason |", "|---|---|---|---|---|---|"]
            + needs.map { "| \($0.project) | \($0.state.rawValue) | \($0.kind) | \(cell($0.target)) | \(cell($0.summary)) | \(cell($0.reason ?? "")) |" }
        md += ["", "## Source files (read-only)", "", "| Project | File | sha256 | Lines | Modified | Disposition |", "|---|---|---|---:|---|---|"]
        for f in files.values.sorted(by: { ($0.config.project, $0.path) < ($1.config.project, $1.path) }) {
            md.append("| \(f.config.project) | `\(f.path)` | \(f.sha256.map { String($0.prefix(16)) } ?? f.error ?? "?") | \(f.lines.count) | "
                      + "\(f.modified.map(Fmt.iso) ?? "?") | \(f.config.disposition) |")
        }
        let first = rehearsal.first
        let applied = first.filter { $0.outcome == "applied" }.count
        let failed = first.filter { $0.outcome == "failed" }
        let rerunWrites = rehearsal.second.filter { $0.outcome == "applied" }.count
        md += ["", "## Rehearsal on the copy", "",
               "The apply was run on the dry run's own copy of the database (`\(rehearsal.copy)`), then planned and run again.", "",
               "- first pass: \(applied) applied, \(failed.count) failed",
               "- plan after it: \(counts(rehearsal.replanned))",
               "- second pass (rerun): \(rerunWrites) writes — \(rerunWrites == 0 ? "the ledger kept it from writing anything twice" : "NOT idempotent: check")",
               ""]
        if !failed.isEmpty {
            md += ["Failures:", ""] + failed.map { "- `\($0.item.key)`: \($0.detail)" } + [""]
        }
        md += ["The copy is kept with the rehearsal's writes, for checking the result (it is not the real database).", "",
               "## Applying (a later, deliberate step)", "",
               "After the review, with this plan.json unchanged:", "", "```sh", applyCommand, "```", "",
               "The apply backs the database up first, writes only this plan's create/update items whose fingerprint is unchanged "
               + "(anything moved since is skipped and reported), and records each in the import ledger.", ""]
        return md.joined(separator: "\n") + "\n"
    }

    // MARK: - Apply

    static func applyReport(_ results: [ImportApplier.Result], after: [ImportItem], header: Header, backup: String) -> String {
        var md = headerLines(header, title: "Import apply")
        md += ["Backup taken first: `\(backup)`", "",
               "Applied \(results.filter { $0.outcome == "applied" }.count) · already done \(results.filter { $0.outcome == "done" }.count) · skipped \(results.filter { $0.outcome == "skipped" }.count)"
               + " · failed \(results.filter { $0.outcome == "failed" }.count)", "",
               "Plan after the apply: \(counts(after))", "",
               "| Outcome | Project | Kind | Target | Key | Detail |", "|---|---|---|---|---|---|"]
        md += results.map { "| \($0.outcome) | \($0.item.project) | \($0.item.kind) | \(cell($0.item.target)) | `\($0.item.key)` | \(cell($0.detail)) |" }
        return md.joined(separator: "\n") + "\n"
    }
}
