import Foundation

/// `questbits import`: move work tracked elsewhere (plan files, agent loop logs) into
/// QuestBits from a reviewed mapping, without ever writing twice.
///
/// - `--dry-run` never writes the given database: it takes a consistent copy (SQLite backup
///   API), plans against it, writes the manifests (plan.json, one manifest per project,
///   summary.md), then rehearses the apply on that copy and runs it a second time to show
///   the rerun writes nothing. The copy is kept as rehearsal-after.sqlite for review.
/// - `--apply --plan <reviewed plan.json>` writes only the items of that plan whose
///   fingerprint is unchanged, after backing the database up. It stops before writing
///   anything when a source drifted or a source item appeared that the plan did not have
///   unmapped (unless `--allow-drift`). It refuses QuestBits' own
///   databases (either flavor) without `--allow-real-db`, so applying to real data is
///   always a deliberate step.
///
/// The mapping, the sources and every output stay outside this repo (they hold the user's
/// data). Sources are only read: files whole, claude-mem's work_state database read-only.
enum ImportCommand {
    static let command = CLICommand(
        name: "import",
        usage: "import --config <file> (--dry-run | --apply --plan <plan.json>) [--db <path>] [--out <dir>] [--allow-real-db] [--allow-drift]",
        summary: "Import work from plan files and agent loop logs, from a reviewed mapping (dry run first).",
        details: """
        --config <file>    the mapping (JSON; see ImportConfig.swift for its shape)
        --dry-run          plan on a copy of the database, write the manifests, rehearse the
                           apply on that copy (and a rerun, which must write nothing)
        --apply            write the reviewed items; needs --plan
        --plan <file>      the dry run's plan.json, as reviewed: only its items, unchanged, are written
        --db <path>        the database (default: TODO_DB_PATH, else QuestBits' own)
        --out <dir>        where manifests and reports go (default: next to the config, dated)
        --allow-real-db    let --apply write QuestBits' own database (it is backed up first)
        --allow-drift      let --apply go on when a source drifted or has new unmapped items
                           (they are still not written; without it, --apply writes nothing)
        """,
        options: ["config", "plan", "db", "out"],
        flags: ["dry-run", "apply", "allow-real-db", "allow-drift"],
        run: { try run($0, $1) })

    static func run(_ args: CLIArgs, _ ctx: CLIContext) throws -> Int32 {
        guard args.positionals.isEmpty else { throw CLIError.usage("unexpected argument '\(args.positionals[0])'") }
        guard let configPath = args.value("config") else { throw CLIError.usage("--config is required") }
        guard args.has("dry-run") != args.has("apply") else { throw CLIError.usage("give exactly one of --dry-run and --apply") }
        let configURL = URL(fileURLWithPath: ctx.absolutePath(configPath))
        let config = try ImportConfig.load(configURL)
        let configSHA = ImportSources.sha256(try Data(contentsOf: configURL))
        let dbURL = args.value("db").map { URL(fileURLWithPath: ctx.absolutePath($0)) } ?? ctx.dbURL
        if args.has("apply") {
            guard args.value("plan") != nil else { throw CLIError.usage("--apply needs --plan <reviewed plan.json>") }
            if Self.isRealDatabase(dbURL) && !args.has("allow-real-db") {
                throw CLIError.usage("\(dbURL.path) is QuestBits' own database: add --allow-real-db to write it (it is backed up first)")
            }
        }
        let stamp = Self.stamp(Date())
        let outDir = URL(fileURLWithPath: args.value("out").map(ctx.absolutePath)
                         ?? configURL.deletingLastPathComponent().appendingPathComponent("run-\(stamp)").path, isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        var run = Run(config: config, configURL: configURL, configSHA: configSHA, dbURL: dbURL, outDir: outDir,
                      stamp: stamp, ctx: ctx)
        if args.has("dry-run") { return try run.dryRun() }
        return try run.apply(planURL: URL(fileURLWithPath: ctx.absolutePath(args.value("plan")!)),
                             allowDrift: args.has("allow-drift"))
    }

    /// QuestBits' own databases, both flavors, whichever this binary is.
    static func isRealDatabase(_ url: URL) -> Bool {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let target = url.resolvingSymlinksInPath().standardizedFileURL.path
        return ["TodoApp", "TodoAppDev"].contains { dir in
            base.appendingPathComponent(dir).appendingPathComponent("db.sqlite")
                .resolvingSymlinksInPath().standardizedFileURL.path == target
        }
    }

    static func stamp(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss.SSS'Z'"
        return f.string(from: d)
    }

    // MARK: - One run

    private struct Run {
        let config: ImportConfig
        let configURL: URL
        let configSHA: String
        let dbURL: URL
        let outDir: URL
        let stamp: String
        let ctx: CLIContext
        var files: [String: ImportSources.File] = [:]
        var workState: ImportSources.WorkStateDB?

        init(config: ImportConfig, configURL: URL, configSHA: String, dbURL: URL, outDir: URL, stamp: String, ctx: CLIContext) {
            self.config = config; self.configURL = configURL; self.configSHA = configSHA
            self.dbURL = dbURL; self.outDir = outDir; self.stamp = stamp; self.ctx = ctx
        }

        /// The date written into imported text ("as read on …"): today for a dry run, the
        /// reviewed plan's for an apply, so the text, and so each fingerprint, is the same.
        var importedOn = Fmt.day(Date())

        mutating func readSources() throws {
            for f in config.sources {
                guard files[f.key] == nil else { throw CLIError.failure("config: source key \(f.key) is used twice") }
                files[f.key] = ImportSources.File.read(f)
            }
            if let ws = config.workState { workState = try ImportSources.WorkStateDB(path: ws.db) }
        }

        func plan(_ store: Store) throws -> [ImportItem] {
            var planner = ImportPlanner(config: config, store: store, files: files, workState: workState,
                                        ledger: try store.importLedger(), importedOn: importedOn)
            let items = try planner.plan()
            var seen = Set<String>()
            for i in items where !seen.insert(i.key).inserted {
                throw CLIError.failure("two items have the source key \(i.key): make the mapping's keys unique")
            }
            return items
        }

        mutating func dryRun() throws -> Int32 {
            try readSources()
            let copy = outDir.appendingPathComponent("rehearsal-after.sqlite")
            try ImportSources.backup(dbURL, to: copy)
            let store = try Store(url: copy)
            store.origin = ChangeOrigin(.importer, sessionLabel: config.session)
            let items = try plan(store)
            try write("plan.json", try Fmt.json(planJSON(items)))
            // Rehearsal on the copy: apply everything planned, then plan and apply again.
            let first = ImportApplier(store: store, runId: "rehearsal-\(stamp)", session: config.session, reviewed: nil)
                .apply(items)
            let replanned = try plan(store)
            let second = ImportApplier(store: store, runId: "rehearsal2-\(stamp)", session: config.session, reviewed: nil)
                .apply(replanned)
            try write("rehearsal.json", try Fmt.json([
                "first_pass": first.map(Self.resultJSON), "rerun_plan_states": Self.counts(replanned),
                "second_pass": second.map(Self.resultJSON)]))
            for code in Self.projectOrder(items) {
                try write("manifest-\(Self.fileSafe(code)).md", ImportReport.manifest(code, items.filter { $0.project == code },
                                                                                    header: header()))
            }
            let rehearsal = ImportReport.Rehearsal(first: first, replanned: replanned, second: second, copy: copy.path)
            try write("summary.md", ImportReport.summary(items, header: header(), files: files, rehearsal: rehearsal,
                                                        applyCommand: applyCommand()))
            let c = Self.counts(items)
            ctx.write("Dry run: \(items.count) items (" + c.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
                      + ").\nRehearsal: \(first.filter { $0.outcome == "applied" }.count) applied, "
                      + "\(first.filter { $0.outcome == "failed" }.count) failed; rerun wrote \(second.filter { $0.outcome == "applied" }.count).\n"
                      + "Manifests in \(outDir.path)\n")
            return 0
        }

        mutating func apply(planURL: URL, allowDrift: Bool) throws -> Int32 {
            let reviewedPlan = try JSONSerialization.jsonObject(with: Data(contentsOf: planURL)) as? [String: Any] ?? [:]
            guard reviewedPlan["config_sha256"] as? String == configSHA else {
                throw CLIError.failure("the mapping changed since that plan was made: run the dry run again and review it")
            }
            if let day = reviewedPlan["imported_on"] as? String { importedOn = day }
            var reviewed: [String: String] = [:]
            var reviewedStates: [String: String] = [:]
            for case let i as [String: Any] in reviewedPlan["items"] as? [Any] ?? [] {
                guard let k = i["key"] as? String, let s = i["state"] as? String else { continue }
                reviewedStates[k] = s
                if let fp = i["fingerprint"] as? String, ImportItem.State(rawValue: s)?.writes == true { reviewed[k] = fp }
            }
            try readSources()
            let backup = outDir.appendingPathComponent("backup-before-apply-\(stamp).sqlite")
            try ImportSources.backup(dbURL, to: backup)
            let store = try Store(url: dbURL)
            store.origin = ChangeOrigin(.importer, sessionLabel: config.session)
            let items = try plan(store)
            // Sources that changed since the mapping, or source items the reviewed plan did
            // not have as unmapped: the review no longer covers them, so nothing is written.
            let unreviewed = items.filter {
                $0.state == .drifted || ($0.state == .unresolved && reviewedStates[$0.key] != ImportItem.State.unresolved.rawValue)
            }
            if !unreviewed.isEmpty && !allowDrift {
                try write("apply-\(stamp)-stopped.json", try Fmt.json([
                    "run_id": "apply-\(stamp)", "db": dbURL.path, "plan": planURL.path, "written": 0,
                    "stopped_on": unreviewed.map(\.json)]))
                let list = unreviewed.prefix(20).map { "  \($0.state.rawValue) \($0.key)" + ($0.reason.map { ": \($0)" } ?? "") }
                throw CLIError.failure("nothing written: \(unreviewed.count) item(s) drifted or are new and unmapped since the "
                    + "reviewed plan:\n" + list.joined(separator: "\n")
                    + (unreviewed.count > 20 ? "\n  …" : "")
                    + "\nRun the dry run again and review it (or add --allow-drift to apply the rest anyway). "
                    + "List: \(outDir.appendingPathComponent("apply-\(stamp)-stopped.json").path)")
            }
            let results = ImportApplier(store: store, runId: "apply-\(stamp)", session: config.session, reviewed: reviewed)
                .apply(items)
            let after = try plan(store)
            try write("apply-\(stamp).json", try Fmt.json([
                "run_id": "apply-\(stamp)", "db": dbURL.path, "backup": backup.path, "plan": planURL.path,
                "results": results.map(Self.resultJSON), "after_states": Self.counts(after)]))
            try write("apply-\(stamp).md", ImportReport.applyReport(results, after: after, header: header(), backup: backup.path))
            let failed = results.filter { $0.outcome == "failed" }.count
            let skipped = results.filter { $0.outcome == "skipped" }.count
            ctx.write("Applied \(results.filter { $0.outcome == "applied" }.count), already done \(results.filter { $0.outcome == "done" }.count), skipped \(skipped), failed \(failed). "
                      + "Backup: \(backup.path)\nReport: \(outDir.appendingPathComponent("apply-\(stamp).md").path)\n")
            return failed > 0 ? 1 : 0
        }

        private func header() -> ImportReport.Header {
            ImportReport.Header(generated: Fmt.iso(Date()), config: configURL.path, configSHA: configSHA,
                                db: dbURL.path, namespace: config.namespace)
        }

        private func applyCommand() -> String {
            "questbits import --config '\(configURL.path)' --apply --plan '\(outDir.appendingPathComponent("plan.json").path)'"
                + " --db '<database>' --out '<dir>' [--allow-real-db]"
        }

        private func planJSON(_ items: [ImportItem]) -> [String: Any] {
            ["generated": Fmt.iso(Date()), "config": configURL.path, "config_sha256": configSHA, "db": dbURL.path,
             "namespace": config.namespace, "imported_on": importedOn, "counts": Self.counts(items),
             "items": items.map(\.json)]
        }

        private func write(_ name: String, _ text: String) throws {
            try Data(text.utf8).write(to: outDir.appendingPathComponent(name), options: .atomic)
        }

        static func counts(_ items: [ImportItem]) -> [String: Int] {
            Dictionary(grouping: items, by: { $0.state.rawValue }).mapValues(\.count)
        }

        static func resultJSON(_ r: ImportApplier.Result) -> [String: Any] {
            ["key": r.item.key, "kind": r.item.kind, "target": r.item.target, "outcome": r.outcome, "detail": r.detail]
        }

        static func projectOrder(_ items: [ImportItem]) -> [String] {
            var seen = Set<String>()
            return items.map(\.project).filter { seen.insert($0).inserted }
        }

        static func fileSafe(_ s: String) -> String {
            String(s.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" })
        }
    }
}
