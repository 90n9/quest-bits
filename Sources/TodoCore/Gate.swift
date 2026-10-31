import Foundation

// MARK: - Gate rules (QUE-36)

/// One rule of the gate: a tool call that needs the user's approval in QuestBits.
///
/// Written as one line of text (what projects store and the app and MCP show):
/// - `git push`, `gh pr merge`, `terraform apply`, `git push --force`: a shell command. The
///   first word is the program (matched by file name, any case, any path); the other
///   words are its subcommand words, in order; words starting with `-` are options that
///   must be there too. `git` and `gh` know their global options (`git -C dir push`).
/// - `tool:mcp__*__create_issue`: an MCP tool, by its full name; `*` matches anything,
///   any case.
/// Three default rules have no text form: `rm -r` outside the project's repo folder, a
/// command that runs sqlite or names the QuestBits database (an agent must not answer its
/// own request), and a QuestBits MCP call that changes which project a folder maps to
/// (archive, unarchive, delete, or a new repo folder): it could switch the gate off.
public struct GateRule: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case command(program: String, words: [String], options: [String])
        case tool(glob: String)
        case rmOutsideRepo
        case questBitsDatabase
        case questBitsMapping
    }

    public let text: String
    public let kind: Kind
    public let isDefault: Bool

    init(text: String, kind: Kind, isDefault: Bool) {
        self.text = text; self.kind = kind; self.isDefault = isDefault
    }

    public static let maxLength = 200

    /// A project rule as typed. Throws `StoreError.invalid` with what is wrong.
    public static func parse(_ raw: String) throws -> GateRule {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { throw StoreError.invalid("a gate rule is empty") }
        guard s.count <= maxLength else { throw StoreError.invalid("a gate rule is longer than \(maxLength) characters") }
        guard !s.contains(where: \.isNewline) else { throw StoreError.invalid("a gate rule is one line") }
        if s.lowercased().hasPrefix("tool:") {
            let glob = String(s.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            guard glob.lowercased().hasPrefix("mcp__") else {
                throw StoreError.invalid("a tool rule names an MCP tool: tool:mcp__<server>__<tool> (* matches anything)")
            }
            guard glob.allSatisfy({ $0.isLetter || $0.isNumber || "_-*.".contains($0) }) else {
                throw StoreError.invalid("a tool rule has only letters, digits, _ - . and *: \(glob)")
            }
            return GateRule(text: "tool:" + glob, kind: .tool(glob: glob.lowercased()), isDefault: false)
        }
        let parts = s.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard let program = parts.first, !program.hasPrefix("-"),
              program.allSatisfy({ $0.isLetter || $0.isNumber || "._+-".contains($0) }) else {
            throw StoreError.invalid("a command rule starts with the program name as a plain word, e.g. \"git push\" or \"terraform apply\"")
        }
        let rest = parts.dropFirst()
        if let bad = rest.first(where: { $0.contains(where: { "'\"`$;&|<>()\\".contains($0) }) }) {
            throw StoreError.invalid("write a command rule as plain words, without quotes or shell symbols: \(bad)")
        }
        return GateRule(text: parts.joined(separator: " "),
                        kind: .command(program: program.lowercased(),
                                       words: rest.filter { !$0.hasPrefix("-") }.map { $0.lowercased() },
                                       options: rest.filter { $0.hasPrefix("-") }),
                        isDefault: false)
    }

    private static func command(_ text: String) -> GateRule {
        let parts = text.split(separator: " ").map(String.init)
        return GateRule(text: text, kind: .command(program: parts[0], words: Array(parts.dropFirst()), options: []),
                        isDefault: true)
    }

    private static func tool(_ glob: String) -> GateRule {
        GateRule(text: "tool:" + glob, kind: .tool(glob: glob.lowercased()), isDefault: true)
    }

    /// Always on, in every project mapped to a repo folder; a project can add to them,
    /// never remove one.
    public static let defaults: [GateRule] = [
        command("git push"),
        command("gh release"),
        command("gh pr merge"),
        command("gh pr create"),
        GateRule(text: "rm -r outside the repo folder", kind: .rmOutsideRepo, isDefault: true),
        GateRule(text: "commands that run sqlite or name the QuestBits database", kind: .questBitsDatabase, isDefault: true),
        GateRule(text: "QuestBits calls that change which project a folder maps to", kind: .questBitsMapping, isDefault: true),
        tool("mcp__*__slack_send_message"),
        tool("mcp__*__slack_schedule_message"),
        tool("mcp__*slack*__send_message"),
        tool("mcp__*slack*__schedule_message"),
        tool("mcp__*slack*__*post_message"),
        tool("mcp__*gmail*__send_message"),
        tool("mcp__*gmail*__reply"),
        tool("mcp__*gmail*__forward"),
        tool("mcp__*gmail*__*send_email")
    ]

    /// Stored project rules, parsed; a line that no longer parses is skipped.
    public static func parseAll(_ texts: [String]) -> [GateRule] {
        texts.compactMap { try? parse($0) }
    }

    /// Case-insensitive glob with `*` only, over the whole name.
    static func globMatches(_ glob: String, _ name: String) -> Bool {
        let g = Array(glob.lowercased()), n = Array(name.lowercased())
        var gi = 0, ni = 0, star = -1, mark = 0
        while ni < n.count {
            if gi < g.count && g[gi] == "*" { star = gi; mark = ni; gi += 1 }
            else if gi < g.count && g[gi] == n[ni] { gi += 1; ni += 1 }
            else if star >= 0 { gi = star + 1; mark += 1; ni = mark }
            else { return false }
        }
        while gi < g.count && g[gi] == "*" { gi += 1 }
        return gi == g.count
    }
}

/// One rule a tool call falls under, and why (`detail`, short, for the question and the agent).
public struct GateFinding: Equatable, Sendable {
    public let rule: String
    public let detail: String

    public init(rule: String, detail: String) { self.rule = rule; self.detail = detail }
}

/// What the gate decided about one tool call: nothing to ask, or the rule it falls under
/// and why (`detail`, short, for the question and the agent).
public enum GateVerdict: Equatable, Sendable {
    case safe
    case risky(rule: String, detail: String)

    public var isRisky: Bool { if case .risky = self { return true } else { return false } }
}

// MARK: - Classifier

/// Decides whether a tool call falls under a gate rule. Pure apart from reading files the
/// command would read anyway (a script it runs, git and gh alias config) — no database.
///
/// Bash commands are parsed (`ShellParser`) and every simple command they could run is
/// checked: commands joined by `&&` `;` `|` `||` or newlines, subshells, `$(…)` and
/// backticks, `bash -c`/`sh -c`/`zsh -c` strings, `eval`, heredocs fed to a shell, and
/// commands behind wrappers (`env`, `sudo`, `command`, `exec`, `nohup`, `timeout`, `xargs`,
/// `find -exec`, …: every suffix of a command's words is checked as a command of its own).
/// Env-var prefixes, quoting, `$'…'`, absolute paths (`/usr/bin/git`), `git-push`, zsh's
/// `=git`, git's global options (`-C`, `--git-dir`) and git/gh aliases are seen through.
/// Where a command cannot be known before it runs — its name comes from a variable, a
/// script is piped into a shell, a quote never closes, a zsh glob qualifier runs code — the
/// call is risky; so is git or gh told to run something else (`git -c`, `rebase --exec`,
/// `bisect run`, HOME or GIT_CONFIG… set for it, `gh api` that writes, `gh workflow run`),
/// and any sqlite command (approvals live in the QuestBits database).
/// Not covered: what `make`, `npm run` and the like run, git hooks, and scripts the agent
/// writes that reach the database in ways the text does not show.
public struct GateClassifier {
    public var rules: [GateRule]
    /// The project's repo folder, `Store.resolvedPath`; nil when unknown: then every `rm -r`
    /// with a path is risky.
    public var repoRoot: String?
    public var cwd: String
    public var home: String
    public var environment: [String: String]

    public init(rules: [GateRule], repoRoot: String?, cwd: String,
                home: String = NSHomeDirectory(),
                environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.rules = rules
        self.repoRoot = repoRoot.map(Store.resolvedPath)
        self.cwd = cwd
        self.home = home
        self.environment = environment
    }

    /// Longer commands are not parsed: risky.
    public static let maxCommandLength = 100_000

    public func classify(toolName: String, input: [String: Any]) -> GateVerdict {
        Self.verdict(findings(toolName: toolName, input: input))
    }

    public func classify(command: String) -> GateVerdict {
        Self.verdict(findings(command: command))
    }

    static func verdict(_ findings: [GateFinding]) -> GateVerdict {
        findings.first.map { .risky(rule: $0.rule, detail: $0.detail) } ?? .safe
    }

    /// Every rule the call falls under (each rule and reason once, in the order found).
    /// Shell tools (Bash, Monitor, PowerShell: `GateCall.shellTools`) are read as a shell
    /// command; a Bash or PowerShell call without command text is risky, a Monitor call
    /// without one (a WebSocket watch) runs no shell and is checked as a tool.
    public func findings(toolName: String, input: [String: Any]) -> [GateFinding] {
        if GateCall.isShellTool(toolName) {
            if let command = input["command"] as? String { return findings(command: command) }
            if toolName != "Monitor" {
                return [GateFinding(rule: toolName, detail: "the \(toolName) call has no command text")]
            }
        }
        var out: [GateFinding] = []
        for rule in rules {
            if case .tool(let glob) = rule.kind, GateRule.globMatches(glob, toolName) {
                out.append(GateFinding(rule: rule.text, detail: "\(toolName) sends or publishes on your behalf"))
            }
        }
        if let rule = has(.questBitsMapping), let why = Self.changesQuestBitsMapping(toolName: toolName, input: input) {
            out.append(GateFinding(rule: rule.text, detail: why))
        }
        return out
    }

    public func findings(command: String) -> [GateFinding] {
        guard command.count <= Self.maxCommandLength else {
            return [GateFinding(rule: "Bash", detail: "the command is too long to check")]
        }
        var a = ShellAnalysis(c: self, raw: command)
        a.analyze(command, depth: 0)
        a.finish()
        var seen = Set<String>()
        return a.findings.filter { seen.insert($0.rule + "\u{0}" + $0.detail).inserted }
            .map { GateFinding(rule: $0.rule, detail: $0.detail) }
    }

    /// The tool's name on a QuestBits MCP server (`mcp__quest-bits__x`, `mcp__quest-bits-dev__x`,
    /// any `mcp__*quest*bits*__x` alias, and the legacy `todo` / `todo-dev`), lowercased; nil
    /// for any other tool.
    static func questBitsTool(_ toolName: String) -> String? {
        let n = toolName.lowercased()
        guard n.hasPrefix("mcp__"), let sep = n.range(of: "__", options: .backwards),
              sep.lowerBound > n.index(n.startIndex, offsetBy: 5) else { return nil }
        let server = String(n[n.index(n.startIndex, offsetBy: 5)..<sep.lowerBound])
        guard GateRule.globMatches("*quest*bits*", server) || server == "todo" || server == "todo-dev" else { return nil }
        return String(n[sep.upperBound...])
    }

    /// Why a QuestBits MCP call may change which project (and so which gate rules) a folder
    /// maps to, or nil: archive, unarchive and delete always; create and update when they
    /// set `repo_path`.
    static func changesQuestBitsMapping(toolName: String, input: [String: Any]) -> String? {
        guard let tool = questBitsTool(toolName) else { return nil }
        switch tool {
        case "archive_project", "unarchive_project", "delete_project":
            return "\(tool) changes which project a folder belongs to, and so which gate rules apply there"
        case "create_project", "update_project":
            return input.keys.contains("repo_path")
                ? "\(tool) with repo_path changes which project a folder belongs to, and so which gate rules apply there"
                : nil
        default:
            return nil
        }
    }

    var commandRules: [(rule: GateRule, program: String, words: [String], options: [String])] {
        rules.compactMap {
            if case let .command(p, w, o) = $0.kind { return ($0, p, w, o) }
            return nil
        }
    }

    func has(_ kind: GateRule.Kind) -> GateRule? { rules.first { $0.kind == kind } }
}

/// One pass over a Bash command (and what it nests), collecting the rules it falls under.
struct ShellAnalysis {
    let c: GateClassifier
    let raw: String
    var findings: [(rule: String, detail: String)] = []
    /// It runs code the parser cannot see into (a script file, an interpreter, stdin to a
    /// shell, an alias, ssh): then the raw text is scanned for the rules as well.
    var indirect = false
    /// A cd/pushd/popd ran earlier: relative paths are no longer relative to `cwd`.
    var dirChanged = false
    /// HOME, XDG_CONFIG_HOME, GIT_CONFIG*, GIT_SSH*, GIT_EXEC_PATH or GH_CONFIG_DIR was set
    /// earlier (`X=…;`, `export X=…`): git and gh may read other config than QuestBits sees.
    var gitEnvChanged = false
    /// A cd/pushd went into an Application Support folder.
    var cdAppSupport = false
    var budget = 5000

    init(c: GateClassifier, raw: String) { self.c = c; self.raw = raw }

    static let maxDepth = 6

    mutating func flag(_ rule: String, _ detail: String) {
        findings.append((rule, detail))
    }

    /// Inside a guess (`analyze(strict: false)`) what cannot be checked is not counted.
    var speculative = 0

    mutating func unclear(_ why: String) {
        guard speculative == 0 else { return }
        flag("unclear command", "QuestBits could not check it: \(why)")
    }

    /// `strict` false: a guess (an argument that may be a command line) — what does not
    /// parse is not counted as unclear.
    mutating func analyze(_ script: String, depth: Int, strict: Bool = true) {
        if !strict { speculative += 1 }
        defer { if !strict { speculative -= 1 } }
        guard depth <= Self.maxDepth else { unclear("commands nested too deeply"); return }
        budget -= 1
        guard budget > 0 else { if budget == 0 { unclear("too many commands") }; return }
        let p = ShellParser.parse(script)
        for problem in p.problems { unclear(problem) }
        for inner in p.nested { analyze(inner, depth: depth + 1) }
        for cmd in p.commands { command(cmd.words, stdin: cmd.stdin, depth: depth, openEnded: false, suffix: false) }
    }

    mutating func finish() {
        if let db = c.has(.questBitsDatabase) {
            let lower = raw.lowercased()
            if Self.namesQuestBitsDatabase(raw) || (cdAppSupport && lower.contains("todo")) {
                flag(db.text, "the command touches the QuestBits database, where approvals are kept")
            } else if indirect, lower.range(of: #"(?<![.\w])sqlite"#, options: .regularExpression) != nil {
                flag(db.text, "it runs code that uses sqlite, which can write the QuestBits database")
            }
        }
        guard findings.isEmpty, indirect, let hit = mentions(raw) else { return }
        flag(hit, "it runs code QuestBits cannot fully check, and that code mentions \(hit)")
    }

    // MARK: Simple commands

    static let reserved: Set<String> = ["!", "{", "}", "then", "do", "else", "elif", "if", "while", "until",
                                        "time", "coproc", "-", "nocorrect", "noglob", "done", "fi", "esac"]
    static let dataWords: Set<String> = ["for", "case", "select", "[[", "]]"]
    static let shells: Set<String> = ["sh", "bash", "zsh", "dash", "ksh", "mksh", "ash", "fish", "csh", "tcsh", "yash"]
    static let interpreters: Set<String> = ["python", "python2", "python3", "node", "nodejs", "perl", "ruby", "php",
                                            "osascript", "deno", "bun", "tsx", "ts-node", "lua", "rscript", "pwsh",
                                            "powershell", "swift", "groovy", "jshell", "irb", "expect", "tclsh", "awk", "gawk"]
    /// Programs whose arguments are data, never a command they run: no suffix scan.
    static let dataPrograms: Set<String> = [
        "echo", "printf", "grep", "egrep", "fgrep", "rg", "ag", "ack", "man", "which", "whereis", "type", "help",
        "info", "apropos", "whatis", "tldr", "sed", "jq", "yq", "cat", "bat", "head", "tail", "less",
        "more", "wc", "sort", "uniq", "tr", "cut", "test", "[", "true", "false", "cd", "pushd", "popd", "ls",
        "mkdir", "touch", "cp", "mv", "ln", "chmod", "chown", "diff", "cmp", "file", "stat", "du", "df", "ps",
        "kill", "pkill", "date", "sleep", "basename", "dirname", "realpath", "readlink", "read", "export", "set",
        "unset", "shift", "return", "exit", "local", "declare", "typeset", "readonly", "tee", "pbcopy", "open",
        "curl", "wget", "base64", "shasum", "md5", "comm", "paste", "column", "fold", "fmt", "nl", "od", "xxd",
        "hexdump", "strings", "git", "gh", "rm"]

    static func isAssignment(_ w: ShellWord) -> Bool {
        guard let eq = w.text.firstIndex(of: "="), eq != w.text.startIndex else { return false }
        var name = w.text[..<eq]
        if name.hasSuffix("+") { name = name.dropLast() }
        if let br = name.firstIndex(of: "[") { name = name[..<br] }
        guard let first = name.first, first == "_" || first.isLetter else { return false }
        return name.allSatisfy { $0 == "_" || $0.isLetter || $0.isNumber }
    }

    static func basename(_ s: String) -> String {
        (s.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? s).lowercased()
    }

    mutating func command(_ words: [ShellWord], stdin: ShellStdin, depth: Int, openEnded: Bool, suffix: Bool) {
        budget -= 1
        guard budget > 0 else { if budget == 0 { unclear("too many commands") }; return }
        var ws = words[...]
        var assigned: [String] = []
        while let w = ws.first, Self.isAssignment(w) { assigned.append(Self.assignedName(w)); ws = ws.dropFirst() }
        guard let first = ws.first else {
            // `HOME=/x; git …`: the variable is set for the rest of the line.
            if assigned.contains(where: Self.changesGitConfig) { gitEnvChanged = true }
            return
        }
        if !first.quoted && Self.reserved.contains(first.text) {
            command(Array(ws.dropFirst()), stdin: stdin, depth: depth, openEnded: openEnded, suffix: suffix)
            return
        }
        if !first.quoted && Self.dataWords.contains(first.text) { return }
        if !first.quoted && first.text == "function" {
            command(Array(ws.dropFirst(2)), stdin: stdin, depth: depth, openEnded: openEnded, suffix: suffix)
            return
        }
        guard !first.dynamic else {
            if !suffix { unclear("the command name comes from a variable or a substitution") }
            return
        }
        var name = first.text
        if name.hasPrefix("=") && !first.quoted { name.removeFirst() }      // zsh: =git is git's path
        if name.isEmpty { return }
        let prog = Self.basename(name)
        let args = Array(ws.dropFirst())

        matchCommandRules(prog: prog, args: args, openEnded: openEnded, depth: depth)
        if prog == "hub" { matchCommandRules(prog: "git", args: args, openEnded: openEnded, depth: depth) }

        if let db = c.has(.questBitsDatabase), prog.hasPrefix("sqlite") || prog == "litecli" {
            flag(db.text, "it runs \(prog), which can write the QuestBits database, where approvals are kept")
        }
        if ["git", "gh", "hub"].contains(prog) || prog.hasPrefix("git-"),
           gitEnvChanged || assigned.contains(where: Self.changesGitConfig) {
            flag("git or gh config from the environment",
                 "it changes where \(prog) reads its config (HOME, GIT_CONFIG…, GH_CONFIG_DIR, …), which can make it run other commands")
        }

        switch prog {
        case "rm":
            rm(args, openEnded: openEnded)
        case "cd", "pushd", "popd":
            dirChanged = true
            if args.contains(where: { Self.isAppSupport($0.text) }) { cdAppSupport = true }
        case "export", "declare", "typeset":
            if args.contains(where: { Self.isAssignment($0) && Self.changesGitConfig(Self.assignedName($0)) }) {
                gitEnvChanged = true
            }
        case "eval":
            if args.contains(where: \.dynamic) { unclear("eval of text that comes from a variable or a substitution") }
            else { analyze(args.map(\.text).joined(separator: " "), depth: depth + 1) }
        case "source", ".":
            indirect = true
            if let f = args.first { scanFile(f) }
        case "alias":
            for a in args { if let eq = a.text.firstIndex(of: "=") { analyze(String(a.text[a.text.index(after: eq)...]), depth: depth + 1) } }
        case "find":
            findExec(args, depth: depth)
        case "ssh", "su":
            indirect = true
        case "env":
            if args.contains(where: { $0.text == "-C" || $0.text.hasPrefix("--chdir") }) { dirChanged = true }
            // env -S / --split-string: one argument that is a whole command line.
            for (k, a) in args.enumerated() {
                if a.text.hasPrefix("--split-string=") { analyze(String(a.text.dropFirst("--split-string=".count)), depth: depth + 1) }
                else if (a.text == "-S" || a.text == "--split-string"), k + 1 < args.count { analyze(args[k + 1].text, depth: depth + 1) }
            }
        default:
            break
        }

        let isInterpreter = Self.interpreters.contains(prog) || prog.hasPrefix("python")
        if Self.shells.contains(prog) {
            shell(args, stdin: stdin, depth: depth)
        } else if isInterpreter {
            interpreter(args, stdin: stdin)
        } else if name.contains("/") && !["git", "gh", "rm"].contains(prog) {
            indirect = true
            scanFile(first)
        }

        // Wrappers and unknown programs: any run of the words may be a command it runs, and an
        // argument with spaces or ; & | may be a command line it hands to a shell (ssh, watch,
        // su -c, tmux); those are checked without counting what fails to parse as unclear.
        if !suffix && !Self.dataPrograms.contains(prog) && !Self.shells.contains(prog) && !isInterpreter {
            for k in 1..<max(1, ws.count) {
                command(Array(ws[(ws.startIndex + k)...]), stdin: .inherit, depth: depth,
                        openEnded: openEnded || prog == "xargs" || prog == "parallel", suffix: true)
            }
            for a in args where a.text.contains(where: { " ;&|\n".contains($0) }) {
                analyze(a.text, depth: depth + 1, strict: false)
            }
        }
        if prog == "git" { gitExtras(args, depth: depth) }
        if prog.hasPrefix("git-") && prog.count > 4 { gitExtras([ShellWord(String(prog.dropFirst(4)))] + args, depth: depth) }
        if prog == "hub" { hubExtras(args) }
        if prog == "gh" {
            ghExtras(args)
            ghAlias(args, depth: depth)
        }
    }

    /// The variable an assignment word sets (`X` of `X=1`, `X+=1`, `X[0]=1`).
    static func assignedName(_ w: ShellWord) -> String {
        guard let eq = w.text.firstIndex(of: "=") else { return w.text }
        var name = w.text[..<eq]
        if name.hasSuffix("+") { name = name.dropLast() }
        if let br = name.firstIndex(of: "[") { name = name[..<br] }
        return String(name)
    }

    /// A variable that makes git or gh read other config (and so other aliases, hooks and
    /// commands) than the files QuestBits checks.
    static func changesGitConfig(_ name: String) -> Bool {
        let n = name.uppercased()
        return n.hasPrefix("GIT_CONFIG") || n.hasPrefix("GIT_SSH") || n == "GIT_EXEC_PATH"
            || n == "HOME" || n == "XDG_CONFIG_HOME" || n == "GH_CONFIG_DIR"
    }

    /// A path whose last folder is (or is a pattern for) Application Support.
    static func isAppSupport(_ path: String) -> Bool {
        let last = path.lowercased().split(separator: "/").last.map(String.init) ?? ""
        return last.hasPrefix("appl") && pathGlob(last, "application support")
    }

    /// `pattern` (a path component that may hold * ? [..]) can name `name`.
    static func pathGlob(_ pattern: String, _ name: String) -> Bool {
        var g = ""
        var inClass = false
        for ch in pattern.lowercased() {
            if inClass { if ch == "]" { inClass = false }; continue }
            if ch == "[" { inClass = true; g.append("*") } else if ch == "?" { g.append("*") } else { g.append(ch) }
        }
        return GateRule.globMatches(g, name)
    }

    // MARK: Command rules

    /// Value-taking global options to skip before git's subcommand, and gh's repo option.
    static let gitValueOptions: Set<String> = ["-C", "-c", "--git-dir", "--work-tree", "--namespace",
                                               "--super-prefix", "--config-env", "--list-cmds"]
    static let ghValueOptions: Set<String> = ["-R", "--repo", "--hostname"]

    mutating func matchCommandRules(prog: String, args: [ShellWord], openEnded: Bool, depth: Int) {
        for r in c.commandRules {
            var args = args
            if prog != r.program {
                // git-push: git's dashed form of a subcommand.
                guard let w0 = r.words.first, prog == r.program + "-" + w0 else { continue }
                args.insert(ShellWord(w0), at: 0)
            }
            if Self.matches(program: r.program, words: r.words, options: r.options, args: args, openEnded: openEnded) {
                flag(r.rule.text, "it runs \(r.rule.text)")
            }
        }
    }

    /// The command's non-option words, in order; `git` and `gh` value options skipped with
    /// their values. `subcommandAt` is where git's subcommand is (its first such word).
    static func positional(program: String, _ args: [ShellWord]) -> [ShellWord] {
        let valueOptions = program == "git" ? gitValueOptions : (program == "gh" ? ghValueOptions : [])
        var out: [ShellWord] = []
        var k = 0
        var afterDashes = false
        while k < args.count {
            let a = args[k]
            k += 1
            if afterDashes || a.dynamic || !a.text.hasPrefix("-") || a.text == "-" { out.append(a); continue }
            if a.text == "--" { afterDashes = true; continue }
            if valueOptions.contains(a.text) { k += 1 }
        }
        return out
    }

    static func wordMatches(_ w: ShellWord, _ pattern: String) -> Bool {
        w.dynamic || w.glob || w.text.lowercased() == pattern
    }

    static func matches(program: String, words: [String], options: [String], args: [ShellWord], openEnded: Bool) -> Bool {
        let pos = positional(program: program, args)
        let matched: Bool
        if program == "git", let w0 = words.first {
            // git's subcommand is its first non-option word.
            guard let sub = pos.first else { return openEnded }
            guard wordMatches(sub, w0) else { return false }
            matched = subsequence(Array(words.dropFirst()), in: Array(pos.dropFirst()))
        } else {
            matched = subsequence(words, in: pos)
        }
        // xargs and find -exec add words QuestBits cannot see: the program is enough.
        if openEnded { return true }
        guard matched else { return false }
        return options.allSatisfy { o in args.contains { optionMatches($0, o) } }
    }

    static func subsequence(_ pattern: [String], in words: [ShellWord]) -> Bool {
        var p = 0
        for w in words where p < pattern.count {
            if wordMatches(w, pattern[p]) { p += 1 }
        }
        return p == pattern.count
    }

    static func optionMatches(_ w: ShellWord, _ option: String) -> Bool {
        if w.dynamic { return true }
        let t = w.text
        if t == option || t.hasPrefix(option + "=") { return true }
        // -f inside a cluster such as -fd
        if option.count == 2, option.hasPrefix("-"), t.hasPrefix("-"), !t.hasPrefix("--"),
           let letter = option.last { return t.dropFirst().contains(letter) }
        return false
    }

    // MARK: git and gh

    /// git beyond its rules: options and subcommands that make git run a command it is
    /// given (`-c core.fsmonitor=…`, `rebase --exec`, `bisect run`, …) or push without the
    /// word push; then its aliases.
    mutating func gitExtras(_ args: [ShellWord], depth: Int) {
        // Global options, before the subcommand.
        var k = 0
        while k < args.count {
            let a = args[k], t = a.text
            if a.dynamic || !t.hasPrefix("-") || t == "-" || t == "--" { break }
            if t == "-c" || t == "--config-env" || t.hasPrefix("--config-env=") {
                flag("git -c", "git \(t.split(separator: "=")[0]) sets config for this call, which can make git run any command")
            } else if t.hasPrefix("--exec-path=") {
                flag("git -c", "git --exec-path makes git run its commands from another folder")
            }
            k += Self.gitValueOptions.contains(t) ? 2 : 1
        }
        let pos = Self.positional(program: "git", args)
        guard let subWord = pos.first, !subWord.dynamic else { return }
        let sub = subWord.text.lowercased()
        let words = pos.dropFirst().map { $0.text.lowercased() }
        let after = args.firstIndex(of: subWord).map { Array(args[($0 + 1)...]) } ?? []
        switch sub {
        case "rebase":
            if after.contains(where: { w in
                w.dynamic || w.text == "-x" || w.text.hasPrefix("--exec")
                    || (w.text.hasPrefix("-") && !w.text.hasPrefix("--") && w.text.dropFirst().contains("x"))
            }) {
                flag("git rebase --exec", "git rebase --exec runs a command after each commit it replays")
            }
        case "bisect" where words.first == "run":
            flag("git bisect run", "git bisect run runs a command at each step")
        case "submodule" where words.contains("foreach"):
            flag("git submodule foreach", "it runs a command in every submodule")
        case "filter-branch":
            flag("git filter-branch", "its filters run commands")
        case "send-pack", "http-push":
            flag("git push", "git \(sub) pushes to a remote, like git push")
        case "subtree" where words.contains("push"):
            flag("git push", "git subtree push pushes to a remote, like git push")
        case "config":
            let reads = after.contains { ["--get", "--get-all", "--get-regexp", "--list", "-l", "--unset", "--unset-all"].contains($0.text) }
            if !reads, let key = words.dropLast().first(where: Self.gitConfigRunsCommand) {
                flag("git config", "it sets \(key), which makes git run a command later")
            }
        default:
            break
        }
        if sub == "config" && args.contains(where: { $0.text.lowercased().hasPrefix("alias.") }) { indirect = true }
        guard depth < ShellAnalysis.maxDepth, let value = gitAlias(subWord.text) else { return }
        indirect = true
        if value.hasPrefix("!") { analyze(String(value.dropFirst()), depth: depth + 1) }
        else { analyze("git " + value, depth: depth + 1) }
    }

    /// A git config key whose value is a command git runs (or a file of more config).
    static func gitConfigRunsCommand(_ key: String) -> Bool {
        let k = key.lowercased()
        guard k.contains(".") else { return false }
        if k.hasPrefix("filter.") || k.hasPrefix("include.") || k.hasPrefix("includeif.") { return true }
        return ["command", "fsmonitor", "pager", "editor", "hookspath", "external", "textconv", "helper",
                "program", ".cmd", "askpass", "proxy"].contains { k.contains($0) }
    }

    /// hub (a git wrapper) can publish on GitHub like gh.
    mutating func hubExtras(_ args: [ShellWord]) {
        guard let sub = Self.positional(program: "git", args).first?.text.lowercased(),
              ["release", "pull-request", "merge", "api"].contains(sub) else { return }
        flag("hub \(sub)", "hub \(sub) publishes or changes things on GitHub, like gh")
    }

    /// gh beyond its rules: `gh api` calls that write (a method other than GET, or fields,
    /// which make it a POST) and starting GitHub Actions runs.
    mutating func ghExtras(_ args: [ShellWord]) {
        let pos = Self.positional(program: "gh", args)
        guard let sub = pos.first?.text.lowercased() else { return }
        let second = pos.count > 1 ? pos[1].text.lowercased() : ""
        if (sub == "workflow" && second == "run") || (sub == "run" && second == "rerun") {
            flag("gh \(sub) \(second)", "it starts a GitHub Actions run, which can release or deploy")
        }
        guard sub == "api" else { return }
        var method: String?            // "?" when it comes from a variable
        var fields = false
        var k = 0
        while k < args.count {
            let a = args[k], t = a.text
            k += 1
            if t == "-X" || t == "--method" {
                method = k < args.count && !args[k].dynamic ? args[k].text.uppercased() : "?"
                k += 1
            } else if t.hasPrefix("--method=") {
                method = a.dynamic ? "?" : String(t.dropFirst("--method=".count)).uppercased()
            } else if t.hasPrefix("-X") && t.count > 2 {
                method = a.dynamic ? "?" : String(t.dropFirst(2)).uppercased()
            } else if ["-f", "-F", "--field", "--raw-field", "--input"].contains(t)
                        || ["--field=", "--raw-field=", "--input="].contains(where: { t.hasPrefix($0) })
                        || (t.count > 2 && (t.hasPrefix("-f") || t.hasPrefix("-F"))) {
                fields = true
            }
        }
        let writes = method.map { $0 != "GET" && $0 != "HEAD" } ?? fields
        if writes {
            flag("gh api", "gh api with \(method ?? "fields (a POST)") can merge, release or change anything on GitHub")
        }
    }

    func gitAlias(_ name: String) -> String? {
        let xdg = c.environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? c.home + "/.config"
        var files = [c.home + "/.gitconfig", xdg + "/git/config"]
        if let root = c.repoRoot { files.append(root + "/.git/config") }
        files.append(c.cwd + "/.git/config")
        let key = name.lowercased()
        for f in files {
            guard let text = Self.readSmall(f) else { continue }
            var inAlias = false
            for line in text.split(whereSeparator: \.isNewline) {
                let l = line.trimmingCharacters(in: .whitespaces)
                if l.hasPrefix("[") { inAlias = l.lowercased().hasPrefix("[alias]"); continue }
                guard inAlias, let eq = l.firstIndex(of: "=") else { continue }
                guard l[..<eq].trimmingCharacters(in: .whitespaces).lowercased() == key else { continue }
                var v = l[l.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                if v.hasPrefix("\""), v.hasSuffix("\""), v.count >= 2 { v = String(v.dropFirst().dropLast()) }
                return v
            }
        }
        return nil
    }

    mutating func ghAlias(_ args: [ShellWord], depth: Int) {
        let pos = Self.positional(program: "gh", args)
        guard let sub = pos.first, !sub.dynamic, depth < ShellAnalysis.maxDepth else { return }
        let dir = c.environment["GH_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : $0 }
            ?? (c.environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? c.home + "/.config") + "/gh"
        guard let text = Self.readSmall(dir + "/config.yml") else { return }
        var inAliases = false
        for line in text.split(whereSeparator: \.isNewline) {
            let l = String(line)
            if !l.hasPrefix(" ") && !l.hasPrefix("\t") { inAliases = l.hasPrefix("aliases:"); continue }
            guard inAliases else { continue }
            let t = l.trimmingCharacters(in: .whitespaces)
            guard let colon = t.firstIndex(of: ":"), t[..<colon].trimmingCharacters(in: .whitespaces) == sub.text else { continue }
            var v = t[t.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if (v.hasPrefix("\"") && v.hasSuffix("\"")) || (v.hasPrefix("'") && v.hasSuffix("'")), v.count >= 2 {
                v = String(v.dropFirst().dropLast())
            }
            indirect = true
            if v.hasPrefix("!") { analyze(String(v.dropFirst()), depth: depth + 1) }
            else { analyze("gh " + v, depth: depth + 1) }
            return
        }
    }

    // MARK: Shells, interpreters, scripts

    mutating func shell(_ args: [ShellWord], stdin: ShellStdin, depth: Int) {
        var k = 0
        var hasC = false
        while k < args.count {
            let t = args[k].text
            guard t.hasPrefix("-") || t.hasPrefix("+"), t != "-", t != "--" else { break }
            k += 1
            if t == "--command" || t == "-c" { hasC = true; continue }
            if t.hasPrefix("--command=") {
                analyze(String(t.dropFirst("--command=".count)), depth: depth + 1)
                return
            }
            if t.hasPrefix("--") {
                if ["--rcfile", "--init-file", "--init-command", "-C"].contains(t) { k += 1 }
                continue
            }
            if ["-o", "+o", "-O", "+O"].contains(t) { k += 1; continue }
            if t.hasPrefix("-") && t.dropFirst().contains("c") { hasC = true }
        }
        if k < args.count && args[k].text == "--" { k += 1 }
        if hasC {
            guard k < args.count else { return }
            if args[k].dynamic { unclear("a shell runs text that comes from a variable or a substitution"); return }
            analyze(args[k].text, depth: depth + 1)
            return
        }
        if k < args.count {
            indirect = true
            scanFile(args[k])
            return
        }
        switch stdin {
        case .pipe, .file: unclear("a script is piped into a shell")
        case .text(let body): analyze(body, depth: depth + 1)
        case .inherit: break
        }
    }

    mutating func interpreter(_ args: [ShellWord], stdin: ShellStdin) {
        indirect = true
        let inline: Set<String> = ["-c", "-e", "-E", "--eval", "-r", "-p", "--print", "-m"]
        if args.contains(where: { inline.contains($0.text) || $0.text.hasPrefix("--eval=") }) { return }
        if let file = args.first(where: { !$0.text.hasPrefix("-") }) {
            scanFile(file)
            return
        }
        if stdin == .pipe || stdin == .file { unclear("a script is piped into an interpreter") }
    }

    /// A script the command runs: its text is checked for the rules (not parsed).
    mutating func scanFile(_ w: ShellWord) {
        guard !w.dynamic else { unclear("a script path comes from a variable"); return }
        var path = w.text
        if w.tilde && (path == "~" || path.hasPrefix("~/")) { path = c.home + path.dropFirst() }
        if !path.hasPrefix("/") { path = c.cwd + "/" + path }
        guard let text = Self.readSmall(path) else { return }
        if let db = c.has(.questBitsDatabase), Self.scriptNamesQuestBitsDatabase(text) {
            flag(db.text, "it runs \(w.text), a script that names the QuestBits database, where approvals are kept")
        }
        guard let hit = mentions(text, rm: false) else { return }
        flag(hit, "it runs \(w.text), a script that mentions \(hit)")
    }

    static func readSmall(_ path: String) -> String? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              attrs[.type] as? FileAttributeType == .typeRegular,
              let size = attrs[.size] as? NSNumber, size.intValue <= 512 * 1024,
              let data = FileManager.default.contents(atPath: path) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    mutating func findExec(_ args: [ShellWord], depth: Int) {
        var k = 0
        while k < args.count {
            if ["-exec", "-execdir", "-ok", "-okdir"].contains(args[k].text) {
                var seg: [ShellWord] = []
                k += 1
                while k < args.count && args[k].text != ";" && args[k].text != "+" { seg.append(args[k]); k += 1 }
                command(seg, stdin: .inherit, depth: depth, openEnded: true, suffix: false)
            }
            k += 1
        }
    }

    // MARK: rm -r outside the repo

    mutating func rm(_ args: [ShellWord], openEnded: Bool) {
        guard let rule = c.has(.rmOutsideRepo) else { return }
        var recursive = false
        var operands: [ShellWord] = []
        var afterDashes = false
        for a in args {
            if !afterDashes && a.text == "--" { afterDashes = true; continue }
            if !afterDashes && a.text.hasPrefix("-") && a.text.count > 1 {
                if a.dynamic { recursive = true }
                else if a.text.hasPrefix("--") {
                    if a.text.count >= 5 && "--recursive".hasPrefix(a.text) { recursive = true }
                } else if a.text.dropFirst().contains(where: { $0 == "r" || $0 == "R" }) {
                    recursive = true
                }
                continue
            }
            if !afterDashes && a.dynamic && !a.quoted && a.text.isEmpty { recursive = true }   // rm $FLAGS x
            operands.append(a)
        }
        guard recursive else { return }
        if operands.isEmpty {
            if openEnded { flag(rule.text, "rm -r with paths QuestBits cannot see") }
            return
        }
        for w in operands {
            if let why = rmOutside(w) { flag(rule.text, "rm -r \(w.text.isEmpty ? "…" : w.text): \(why)"); return }
        }
    }

    /// Why removing `w` may reach outside the repo folder, or nil when it stays inside it.
    func rmOutside(_ w: ShellWord) -> String? {
        guard let root = c.repoRoot else { return "this folder is not a project's repo folder" }
        if w.dynamic { return "the path comes from a variable or a substitution" }
        var path = w.text
        if path.isEmpty { return nil }
        if w.tilde {
            if path == "~" || path.hasPrefix("~/") { path = c.home + path.dropFirst() }
            else { return "another user's home folder" }
        }
        if !path.hasPrefix("/") {
            if dirChanged { return "a relative path after cd" }
            path = c.cwd + "/" + path
        }
        if w.glob {
            var comps = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            guard let g = comps.firstIndex(where: { $0.contains(where: { "*?[".contains($0) }) }) else { return nil }
            if comps[g].hasPrefix(".") || comps[g].hasPrefix("[") || comps[g].hasPrefix("?") { return "a pattern that can match .." }
            if comps[(g + 1)...].contains("..") { return "a pattern followed by .." }
            comps = Array(comps[..<g])
            let base = Self.physicalPath("/" + comps.joined(separator: "/"))
            return Store.pathIsInside(base, root: root) ? nil : "outside the repo folder (\(root))"
        }
        let resolved = Self.physicalPath(path)
        if resolved == root { return "it is the repo folder itself" }
        return Store.pathIsInside(resolved, root: root) ? nil : "outside the repo folder (\(root))"
    }

    /// The path the file system reaches: each `..` taken after the symlinks before it are
    /// resolved (a lexical `..` would undo a symlink to elsewhere), then `Store.resolvedPath`.
    static func physicalPath(_ abs: String) -> String {
        var cur = "/"
        for comp in abs.split(separator: "/", omittingEmptySubsequences: true) {
            if comp == "." { continue }
            if comp == ".." {
                cur = (Store.resolvedPath(cur) as NSString).deletingLastPathComponent
                if cur.isEmpty { cur = "/" }
            } else {
                cur = cur == "/" ? "/" + comp : cur + "/" + comp
            }
        }
        return Store.resolvedPath(cur)
    }

    // MARK: Text scan (for code the parser cannot see into)

    /// The first rule `text` mentions: a rule's program followed (within a few words) by
    /// its words in order, quotes and backslashes ignored; `rm` with an -r option (not for
    /// script files, which often clean a build folder: their rm paths are not checked).
    func mentions(_ text: String, rm: Bool = true) -> String? {
        let cleaned = text.lowercased().filter { !"'\"`\\".contains($0) }
        let seps: Set<Character> = [" ", "\t", "\n", "\r", ";", "&", "|", "(", ")", "<", ">", "{", "}", "[", "]",
                                    ",", "$", "=", ":", "+", "!", "*", "?", "@", "#", "%", "^"]
        let tokens = cleaned.split(whereSeparator: { seps.contains($0) }).map { Self.basename(String($0)) }
        for (i, t) in tokens.enumerated() {
            for r in c.commandRules {
                var want = r.words[...]
                if t == r.program {
                    // fine
                } else if let w0 = want.first, t == r.program + "-" + w0 {
                    want = want.dropFirst()
                } else { continue }
                var p = want.startIndex
                for u in tokens[(i + 1)..<min(tokens.count, i + 10)] where p < want.endIndex {
                    if u == want[p] { p += 1 }
                }
                if p == want.endIndex { return r.rule.text }
            }
            if rm, t == "rm", let rule = c.has(.rmOutsideRepo) {
                for u in tokens[(i + 1)..<min(tokens.count, i + 5)] {
                    if u == "--recursive" || (u.hasPrefix("-") && !u.hasPrefix("--") && u.dropFirst().contains("r")) {
                        return rule.text
                    }
                }
            }
        }
        return nil
    }

    /// Command text that names the QuestBits database or its folder (any case, quotes and
    /// backslashes ignored): Application Support/Todo… (also as a pattern, `Appl*/Todo*`),
    /// TodoApp/db…, a db.sqlite file (also -wal, -shm), or ~/Library/<pattern>/<pattern>
    /// that can reach Application Support/TodoApp.
    static func namesQuestBitsDatabase(_ text: String) -> Bool {
        let t = text.lowercased().filter { !"'\"\\".contains($0) }
        if scriptNamesQuestBitsDatabase(t) { return true }
        if t.range(of: #"appl[^/\n]*/todo"#, options: .regularExpression) != nil { return true }
        if t.range(of: #"todoapp(dev)?/[*?\[]"#, options: .regularExpression) != nil { return true }
        if t.range(of: #"db\.sqlite(?![0-9a-z])"#, options: .regularExpression) != nil { return true }
        guard let re = try? NSRegularExpression(pattern: #"library/([^/\n]+)/([^/\s]+)"#) else { return false }
        for m in re.matches(in: t, range: NSRange(t.startIndex..., in: t)) {
            guard let r1 = Range(m.range(at: 1), in: t), let r2 = Range(m.range(at: 2), in: t) else { continue }
            let a = String(t[r1]), b = String(t[r2])
            guard a.contains(where: { "*?[".contains($0) }) || b.contains(where: { "*?[".contains($0) }) else { continue }
            if pathGlob(a, "application support") && (pathGlob(b, "todoapp") || pathGlob(b, "todoappdev")) { return true }
        }
        return false
    }

    /// Script text that names the QuestBits database: TodoApp/db… (narrower than for a
    /// command: a build script may mention the TodoApp sources or its data folder).
    static func scriptNamesQuestBitsDatabase(_ text: String) -> Bool {
        let t = text.lowercased().filter { !"'\"\\".contains($0) }
        return t.range(of: #"todoapp(dev)?/db"#, options: .regularExpression) != nil
    }
}
