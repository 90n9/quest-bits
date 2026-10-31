import Foundation

/// `questbits`: QuestBits on the command line, for people and for Claude Code hooks. The
/// binary ships inside the app at Contents/Resources/cli/questbits; hooks call it by that
/// full path, people through the ~/.local/bin link the app's Settings can install.
///
/// It reads the same database as the app and the MCP server: the flavor's real one
/// (`Store.defaultDatabaseURL()`), or `TODO_DB_PATH` when set (tests use a scratch copy).
/// Commands that only read open the store read-only (`CLIContext.withStore`); the `hook`
/// commands record Claude Code sessions, and never create a missing database.
///
/// Adding a command: write a `CLICommand` and list it in `CLI.commands`. A command with
/// subcommands (e.g. `hook session-start`, `hook pre-tool-use`) is one entry whose `run`
/// switches on `args.positionals.first`; hook input arrives on stdin (`CLIContext.readStdin`).
/// A command that writes opens the store with `CLIContext.withWritableStore`; `import` opens
/// the database it is given itself (a backup copy for a dry run, see ImportCommand).
enum CLI {
    static let commands: [CLICommand] = [
        BriefCommand.command,
        ListCommand.command,
        ShowCommand.command,
        ExportCommand.command,
        ImportCommand.command,
        HookCommand.command
    ]

    /// The name the user typed (questbits, questbits-dev, or the bundle path), for messages.
    static var programName: String {
        (CommandLine.arguments.first.map { ($0 as NSString).lastPathComponent }) ?? "questbits"
    }

    /// Runs one command line (without the program name) and returns the exit status:
    /// 0 done, 1 failed, 2 bad usage.
    static func run(_ argv: [String]) -> Int32 {
        guard let first = argv.first else {
            printErr(usage())
            return 2
        }
        switch first {
        case "-h", "--help":
            print(usage())
            return 0
        case "help":
            if let name = argv.dropFirst().first {
                guard let cmd = commands.first(where: { $0.name == name }) else {
                    printErr("\(programName): unknown command '\(name)'\n\n" + usage())
                    return 2
                }
                print(cmd.help)
            } else {
                print(usage())
            }
            return 0
        case "--version", "version":
            print(version())
            return 0
        default:
            break
        }
        guard let cmd = commands.first(where: { $0.name == first }) else {
            printErr("\(programName): unknown command '\(first)'\n\n" + usage())
            return 2
        }
        let rest = Array(argv.dropFirst())
        if rest.contains("-h") || rest.contains("--help") {
            print(cmd.help)
            return 0
        }
        do {
            let args = try CLIArgs.parse(rest, options: cmd.options, flags: cmd.flags)
            return try cmd.run(args, CLIContext())
        } catch where cmd.neverFails {
            // A hook command: a bad command line must not fail (or block) Claude Code either.
            if ProcessInfo.processInfo.environment["QUESTBITS_HOOK_DEBUG"] == "1" {
                printErr("\(programName) \(cmd.name): \(error)")
            }
            return 0
        } catch let error as CLIError {
            switch error {
            case .usage(let message):
                printErr("\(programName) \(cmd.name): \(message)\nusage: \(programName) \(cmd.usage)")
                return 2
            case .failure(let message):
                printErr("\(programName) \(cmd.name): \(message)")
                return 1
            }
        } catch {
            printErr("\(programName) \(cmd.name): \(error)")
            return 1
        }
    }

    static func usage() -> String {
        let width = commands.map(\.name.count).max() ?? 0
        let lines = commands.map { "  \($0.name.padding(toLength: width, withPad: " ", startingAt: 0))  \($0.summary)" }
        return """
        usage: \(programName) <command> [options]

        Commands:
        \(lines.joined(separator: "\n"))

        \(programName) help <command> shows a command's options. Reads TODO_DB_PATH when set,
        else the QuestBits database (\(Store.defaultDatabaseURL().path)).
        """
    }

    /// The app's version, read from the bundle this binary sits in (Contents/Resources/cli).
    static func version() -> String {
        let exe = Bundle.main.executableURL?.resolvingSymlinksInPath()
        let contents = exe?.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let plist = contents?.appendingPathComponent("Info.plist")
        let info = plist.flatMap { NSDictionary(contentsOf: $0) }
        return "\(programName) \(info?["CFBundleShortVersionString"] as? String ?? "(version unknown)")"
    }

    static func printErr(_ text: String) {
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }
}

/// One `questbits <name>` command. `options` take a value (`--path <dir>`, `--path=<dir>`,
/// repeatable); `flags` take none.
struct CLICommand: Sendable {
    let name: String
    let usage: String
    let summary: String
    let details: String
    var options: Set<String> = []
    var flags: Set<String> = []
    /// Exit 0 on any error, silently (hook commands: see HookCommand).
    var neverFails = false
    let run: @Sendable (CLIArgs, CLIContext) throws -> Int32

    var help: String {
        "usage: \(CLI.programName) \(usage)\n\n\(summary)" + (details.isEmpty ? "" : "\n\n\(details)")
    }
}

enum CLIError: Error {
    case usage(String)     // exit 2, with the command's usage line
    case failure(String)   // exit 1
}

/// A command's arguments: positionals in order, option values (an option may repeat), flags.
struct CLIArgs: Sendable {
    var positionals: [String] = []
    var values: [String: [String]] = [:]
    var flags: Set<String> = []

    func value(_ name: String) -> String? { values[name]?.last }
    func has(_ name: String) -> Bool { flags.contains(name) }

    /// Every value of a repeatable option, comma-separated lists split, blanks dropped.
    func list(_ name: String) -> [String] {
        (values[name] ?? []).flatMap { $0.split(separator: ",") }
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    static func parse(_ argv: [String], options: Set<String>, flags: Set<String>) throws -> CLIArgs {
        var out = CLIArgs()
        var i = 0
        var onlyPositionals = false
        while i < argv.count {
            let arg = argv[i]
            i += 1
            if onlyPositionals || !arg.hasPrefix("--") || arg == "-" {
                if arg == "--" { onlyPositionals = true; continue }
                out.positionals.append(arg)
                continue
            }
            if arg == "--" { onlyPositionals = true; continue }
            let body = String(arg.dropFirst(2))
            let parts = body.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let name = String(parts[0])
            if options.contains(name) {
                let value: String
                if parts.count == 2 {
                    value = String(parts[1])
                } else {
                    guard i < argv.count else { throw CLIError.usage("--\(name) needs a value") }
                    value = argv[i]
                    i += 1
                }
                out.values[name, default: []].append(value)
            } else if flags.contains(name) {
                guard parts.count == 1 else { throw CLIError.usage("--\(name) takes no value") }
                out.flags.insert(name)
            } else {
                throw CLIError.usage("unknown option --\(name)")
            }
        }
        return out
    }
}

/// What a command runs against: the database location and stdin/stdout.
struct CLIContext: Sendable {
    let dbURL: URL
    let cwd: String

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        if let path = environment["TODO_DB_PATH"], !path.isEmpty {
            dbURL = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        } else {
            dbURL = Store.defaultDatabaseURL()
        }
        cwd = FileManager.default.currentDirectoryPath
    }

    /// Is there a database at all? Commands never create one: QuestBits does, on first launch.
    var databaseExists: Bool { FileManager.default.fileExists(atPath: dbURL.path) }

    func requireDatabase() throws {
        guard databaseExists else {
            throw CLIError.failure("no QuestBits database at \(dbURL.path) (open QuestBits once to create it)")
        }
    }

    /// Runs `body` on the database opened read-only: nothing is created or migrated, and
    /// SQLite refuses any write. A database not yet migrated to this build's schema (the
    /// app was updated but has not opened it since) fails with "no such column/table"; then
    /// it is opened once more the normal way, which applies the same additive migrations
    /// the app and the MCP server run at every launch, and `body` runs again. Commands
    /// therefore build their whole output before printing or writing any of it.
    func withStore<T>(_ body: (Store) throws -> T) throws -> T {
        do {
            return try body(try Store(url: dbURL, readOnly: true))
        } catch let error as StoreError where Self.needsMigration(error) {
            return try body(try Store(url: dbURL))
        }
    }

    /// For commands that write (the hooks): the normal open, migrations included. Call it
    /// only when `databaseExists`: it creates a missing database. What it writes is recorded
    /// as from `origin` (a hook passes `.hook` with its Claude Code session).
    func withWritableStore<T>(_ origin: ChangeOrigin = ChangeOrigin(.cli), _ body: (Store) throws -> T) throws -> T {
        let store = try Store(url: dbURL)
        store.origin = origin
        return try body(store)
    }

    static func needsMigration(_ error: StoreError) -> Bool {
        switch error {
        case .prepare(let message), .step(let message):
            return message.contains("no such column") || message.contains("no such table")
        default:
            return false
        }
    }

    /// An absolute path for `raw`: ~ expanded, a relative path taken from the working directory.
    func absolutePath(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return Store.resolvedPath(Store.isAbsolute(trimmed) ? trimmed : cwd + "/" + trimmed)
    }

    /// All of stdin (hook commands get their event JSON there).
    func readStdin() -> Data { FileHandle.standardInput.readDataToEndOfFile() }

    func write(_ text: String) {
        FileHandle.standardOutput.write(Data(text.utf8))
    }
}
