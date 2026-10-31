import Foundation

// MARK: - Shell parsing for the gate (QUE-36)

/// One word of a shell command after quote removal. `text` is the literal value as far as
/// it can be known without running anything: quotes and backslashes are removed and
/// ANSI-C `$'…'` strings decoded. A word whose value depends on the run (a `$var`,
/// `${…}`, `$(…)`, backticks, brace expansion, a process substitution) is `dynamic`;
/// unquoted `* ? [` make it a `glob`; an unquoted leading `~` is `tilde`.
struct ShellWord: Equatable {
    var text = ""
    var dynamic = false
    var glob = false
    var tilde = false
    var quoted = false
    var started = false

    init() {}
    init(_ text: String) { self.text = text; started = true }
}

/// Where a simple command's stdin comes from: a pipe, a file (`<`), or text the command
/// line holds itself (a heredoc or `<<<` here-string).
enum ShellStdin: Equatable {
    case inherit, pipe, file, text(String)
}

struct ShellCommand {
    var words: [ShellWord] = []
    var stdin: ShellStdin = .inherit
    var hasRedirect = false
}

/// A command line split into simple commands (in order; `;`, `&&`, `||`, `|`, `&`,
/// newlines, `(`, `)` all separate), plus the scripts nested in it that also run
/// (`$(…)`, backticks, `<(…)`, `>(…)`, and command substitutions inside `${…}` or an
/// unquoted heredoc), and what could not be parsed (`problems`: an unterminated quote,
/// an unbalanced substitution). The gate treats any problem as risky.
struct ShellParse {
    var commands: [ShellCommand] = []
    var nested: [String] = []
    var problems: [String] = []
}

/// A small POSIX-shell (bash/zsh) tokenizer. It does not run or expand anything; it only
/// needs to see every command a line could run. Where it cannot be sure, it says so.
struct ShellParser {
    private let c: [Character]
    private var i = 0
    private var out = ShellParse()
    private var cmd = ShellCommand()
    private var word = ShellWord()
    private enum Redirect { case stdinFile, hereString, heredoc(dash: Bool), other }
    private var pendingRedirect: Redirect?
    private var pendingHeredocs: [(delim: String, quoted: Bool, dash: Bool, command: Int)] = []

    static func parse(_ script: String) -> ShellParse {
        var p = ShellParser(Array(script))
        p.run()
        return p.out
    }

    private init(_ chars: [Character]) { c = chars }

    private func peek(_ k: Int = 1) -> Character? { i + k < c.count ? c[i + k] : nil }

    private mutating func run() {
        while i < c.count {
            let ch = c[i]
            switch ch {
            case " ", "\t", "\r":
                endWord(); i += 1
            case "\n":
                endCommand(pipe: false); i += 1
                readHeredocBodies()
            case "#" where !word.started:
                while i < c.count && c[i] != "\n" { i += 1 }
            case ";":
                endCommand(pipe: false); i += 1
            case "&":
                if peek() == "&" { endCommand(pipe: false); i += 2 }
                else if peek() == ">" { redirectOp() }
                else { endCommand(pipe: false); i += 1 }
            case "|":
                if peek() == "|" { endCommand(pipe: false); i += 2 }
                else if peek() == "&" { endCommand(pipe: true); i += 2 }
                else { endCommand(pipe: true); i += 1 }
            case "(", ")":
                if ch == "(" && word.started && peek() != ")" && !word.text.hasSuffix("=") && globQualifierRunsCode() {
                    out.problems.append("a zsh glob qualifier that runs code (e: or +)")
                }
                endCommand(pipe: false); i += 1
            case "<", ">":
                if peek() == "(" {
                    // Process substitution <(…) / >(…): a command that runs.
                    i += 1
                    if let inner = balancedParens() { out.nested.append(inner) }
                    word.started = true; word.dynamic = true
                } else {
                    redirectOp()
                }
            case "\\":
                if peek() == "\n" { i += 2; continue }     // line continuation
                word.started = true; word.quoted = true
                if let n = peek() { word.text.append(n) }
                i += 2
            case "'":
                word.started = true; word.quoted = true
                i += 1
                guard let end = c[i...].firstIndex(of: "'") else {
                    out.problems.append("an unterminated ' quote"); i = c.count; break
                }
                word.text += String(c[i..<end]); i = end + 1
            case "\"":
                word.started = true; word.quoted = true
                i += 1
                doubleQuoted()
            case "$":
                dollar(inDoubleQuotes: false)
            case "`":
                backtick()
            case "*", "?", "[":
                word.started = true; word.glob = true; word.text.append(ch); i += 1
            case "{", "}":
                // A lone { or } is a reserved word; inside a word it may be brace expansion.
                if word.started || (peek().map { !" \t\n;&|".contains($0) } ?? false) { word.dynamic = true }
                word.started = true; word.text.append(ch); i += 1
            case "~":
                if !word.started { word.tilde = true }
                word.started = true; word.text.append(ch); i += 1
            default:
                word.started = true; word.text.append(ch); i += 1
            }
        }
        endCommand(pipe: false)
        if !pendingHeredocs.isEmpty { readHeredocBodies() }
        if pendingRedirect != nil { out.problems.append("a redirection with no target") }
    }

    // MARK: Words and commands

    private mutating func endWord() {
        guard word.started else { return }
        if let r = pendingRedirect {
            pendingRedirect = nil
            switch r {
            case .stdinFile: cmd.stdin = .file
            case .hereString: cmd.stdin = .text(word.text)
            case .heredoc(let dash):
                pendingHeredocs.append((word.text, word.quoted, dash, out.commands.count))
            case .other: break
            }
            if word.dynamic && !word.quoted { /* a redirect target from a variable: harmless here */ }
        } else {
            cmd.words.append(word)
        }
        word = ShellWord()
    }

    private mutating func endCommand(pipe: Bool) {
        endWord()
        if pendingRedirect != nil {
            // `>` with no file before the end of the command: a syntax error to the shell.
            out.problems.append("a redirection with no target")
            pendingRedirect = nil
        }
        if !cmd.words.isEmpty || cmd.hasRedirect { out.commands.append(cmd) }
        cmd = ShellCommand()
        if pipe { cmd.stdin = .pipe }
    }

    /// `<`, `<<`, `<<-`, `<<<`, `<>`, `<&`, `>`, `>>`, `>|`, `>&`, `&>`, `&>>`; a word of
    /// digits right before it is a file descriptor, not an argument.
    private mutating func redirectOp() {
        if word.started && !word.quoted && !word.text.isEmpty && word.text.allSatisfy(\.isNumber) {
            word = ShellWord()
        } else {
            endWord()
        }
        cmd.hasRedirect = true
        let ch = c[i]
        if ch == "&" {                              // &> or &>>
            i += 2
            if i < c.count && c[i] == ">" { i += 1 }
            pendingRedirect = .other
            return
        }
        if ch == "<" {
            if peek() == "<" && peek(2) == "<" { i += 3; pendingRedirect = .hereString; return }
            if peek() == "<" {
                i += 2
                var dash = false
                if i < c.count && c[i] == "-" { dash = true; i += 1 }
                pendingRedirect = .heredoc(dash: dash)
                return
            }
            if peek() == ">" || peek() == "&" { i += 2; pendingRedirect = .other; return }
            i += 1; pendingRedirect = .stdinFile
            return
        }
        // >
        if peek() == ">" || peek() == "|" || peek() == "&" { i += 2 } else { i += 1 }
        pendingRedirect = .other
    }

    /// At a `(` inside a word (`*(e:'…':)`, `x(+f)`; not `f()` or `a=(…)`): zsh reads it as
    /// glob qualifiers, where `e` with a delimiter and `+name` run code. Looks ahead only.
    private func globQualifierRunsCode() -> Bool {
        var probe = self
        let inner = probe.balancedParens() ?? String(c[(i + 1)...])
        let cs = Array(inner)
        for (k, ch) in cs.enumerated() where k + 1 < cs.count {
            let n = cs[k + 1]
            if ch == "+" && (n.isLetter || n == "_") { return true }
            if ch == "e" && !(n.isLetter || n.isNumber || n == " " || n == ")") { return true }
        }
        return false
    }

    // MARK: Quotes and expansions

    private mutating func doubleQuoted() {
        while i < c.count {
            let ch = c[i]
            switch ch {
            case "\"":
                i += 1; return
            case "\\":
                if let n = peek() {
                    if n == "\n" { i += 2; continue }
                    if "$`\"\\".contains(n) { word.text.append(n) } else { word.text.append("\\"); word.text.append(n) }
                }
                i += 2
            case "$":
                dollar(inDoubleQuotes: true)
            case "`":
                backtick()
            default:
                word.text.append(ch); i += 1
            }
        }
        out.problems.append("an unterminated \" quote")
    }

    private mutating func dollar(inDoubleQuotes: Bool) {
        word.started = true
        guard let n = peek() else { word.text.append("$"); i += 1; return }
        switch n {
        case "(":
            i += 1
            if let inner = balancedParens() {
                // $((…)) is arithmetic, but may hold a $(…) itself: parse it all the same.
                out.nested.append(inner)
            }
            word.dynamic = true
        case "{":
            i += 2
            var depth = 1
            let start = i
            while i < c.count && depth > 0 {
                switch c[i] {
                case "\\": i += 1
                case "{": depth += 1
                case "}": depth -= 1
                case "'": if let e = c[(i + 1)...].firstIndex(of: "'") { i = e }
                default: break
                }
                i += 1
            }
            if depth > 0 { out.problems.append("an unterminated ${"); return }
            let inner = String(c[start..<(i - 1)])
            if inner.contains("$(") || inner.contains("`") { out.nested.append(inner) }
            word.dynamic = true
        case "'" where !inDoubleQuotes:
            i += 2
            word.quoted = true
            ansiC()
        case "\"" where !inDoubleQuotes:
            i += 2
            word.quoted = true
            doubleQuoted()
        default:
            if n == "_" || n.isLetter || n.isNumber || "@*#?$!-".contains(n) {
                i += 2
                if n == "_" || n.isLetter {
                    while i < c.count && (c[i] == "_" || c[i].isLetter || c[i].isNumber) { i += 1 }
                }
                word.dynamic = true
            } else {
                word.text.append("$"); i += 1
            }
        }
    }

    /// `$'…'`: backslash escapes decoded (\n \t \xHH \NNN \uHHHH \' \\ …).
    private mutating func ansiC() {
        while i < c.count {
            let ch = c[i]
            if ch == "'" { i += 1; return }
            guard ch == "\\", let n = peek() else { word.text.append(ch); i += 1; continue }
            i += 2
            switch n {
            case "n": word.text.append("\n")
            case "t": word.text.append("\t")
            case "r": word.text.append("\r")
            case "a", "b", "e", "E", "f", "v": word.text.append(" ")
            case "x", "u", "U":
                let maxLen = n == "x" ? 2 : (n == "u" ? 4 : 8)
                var hex = ""
                while hex.count < maxLen, i < c.count, c[i].isHexDigit { hex.append(c[i]); i += 1 }
                if let v = UInt32(hex, radix: 16), let s = Unicode.Scalar(v) { word.text.unicodeScalars.append(s) }
            case "0"..."7":
                var oct = String(n)
                while oct.count < 3, i < c.count, ("0"..."7").contains(c[i]) { oct.append(c[i]); i += 1 }
                if let v = UInt32(oct, radix: 8), let s = Unicode.Scalar(v) { word.text.unicodeScalars.append(s) }
            case "c":
                word.dynamic = true
                if i < c.count { i += 1 }
            default:
                word.text.append(n)
            }
        }
        out.problems.append("an unterminated $' quote")
    }

    private mutating func backtick() {
        word.started = true; word.dynamic = true
        i += 1
        var inner = ""
        while i < c.count && c[i] != "`" {
            if c[i] == "\\", let n = peek(), "`$\\".contains(n) { inner.append(n); i += 2; continue }
            inner.append(c[i]); i += 1
        }
        if i >= c.count { out.problems.append("an unterminated ` substitution"); return }
        i += 1
        out.nested.append(inner)
    }

    /// At an opening `(`: the text up to its matching `)`, quotes respected; nil (and a
    /// problem) when it never closes. Leaves `i` after the `)`.
    private mutating func balancedParens() -> String? {
        guard i < c.count, c[i] == "(" else { return nil }
        i += 1
        let start = i
        var depth = 1
        while i < c.count {
            switch c[i] {
            case "\\": i += 1
            case "'":
                guard let e = c[(i + 1)...].firstIndex(of: "'") else { i = c.count; continue }
                i = e
            case "\"":
                i += 1
                while i < c.count && c[i] != "\"" { if c[i] == "\\" { i += 1 }; i += 1 }
            case "(": depth += 1
            case ")":
                depth -= 1
                if depth == 0 {
                    let inner = String(c[start..<i])
                    i += 1
                    return inner
                }
            default: break
            }
            i += 1
        }
        out.problems.append("an unbalanced $( or ( substitution")
        return nil
    }

    // MARK: Heredocs

    /// After a newline: the bodies of the heredocs opened on the line just ended, in order.
    /// An unquoted delimiter means the body is expanded, so its substitutions run.
    private mutating func readHeredocBodies() {
        let docs = pendingHeredocs
        pendingHeredocs = []
        for doc in docs {
            var lines: [String] = []
            var found = false
            while i < c.count {
                var line = ""
                while i < c.count && c[i] != "\n" { line.append(c[i]); i += 1 }
                if i < c.count { i += 1 }
                let cmp = doc.dash ? String(line.drop(while: { $0 == "\t" })) : line
                if cmp == doc.delim { found = true; break }
                lines.append(line)
            }
            let body = lines.joined(separator: "\n")
            if !found && i >= c.count { /* bash runs it anyway, up to the end */ }
            if doc.command < out.commands.count { out.commands[doc.command].stdin = .text(body) }
            if !doc.quoted { out.nested.append(contentsOf: Self.substitutions(in: body)) }
        }
    }

    /// The `$(…)` and backtick substitutions in text that is expanded but not word-split
    /// (an unquoted heredoc body).
    static func substitutions(in text: String) -> [String] {
        var p = ShellParser(Array(text))
        var found: [String] = []
        while p.i < p.c.count {
            if p.c[p.i] == "\\" { p.i += 2; continue }
            if p.c[p.i] == "$", p.peek() == "(" {
                p.i += 1
                if let inner = p.balancedParens() { found.append(inner) } else { found.append(String(p.c[p.i...])) }
                continue
            }
            if p.c[p.i] == "$", p.peek() == "{" {
                let before = p.out.nested.count
                p.dollar(inDoubleQuotes: true)
                found.append(contentsOf: p.out.nested[before...])
                continue
            }
            if p.c[p.i] == "`" {
                let before = p.out.nested.count
                p.backtick()
                found.append(contentsOf: p.out.nested[before...])
                continue
            }
            p.i += 1
        }
        return found
    }
}
