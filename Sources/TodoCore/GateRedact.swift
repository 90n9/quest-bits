import Foundation
import CryptoKit

// MARK: - What the gate stores about a tool call (QUE-36)

/// The gate never stores a tool call's input as it was: the question shows a redacted copy
/// (`GateRedactor`), and the approval is matched on a hash of the exact input
/// (`GateCall.inputHash`), so a call that differs by one character needs a new approval.
public enum GateCall {
    /// SHA-256 (hex) of the tool name and the input that decides what runs: a Bash call's
    /// `command` text exactly (its description, timeout and background flag do not change
    /// what runs), any other tool's whole input as canonical JSON (keys sorted).
    public static func inputHash(toolName: String, input: [String: Any]) -> String {
        var material = "questbits-gate-v1\n" + toolName + "\n"
        if toolName == "Bash" {
            material += (input["command"] as? String) ?? "\u{0}no command"
        } else {
            material += canonicalJSON(input)
        }
        return SHA256.hash(data: Data(material.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func canonicalJSON(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(["v": value]),
              let data = try? JSONSerialization.data(withJSONObject: ["v": value], options: [.sortedKeys]) else {
            return String(describing: value)
        }
        return String(decoding: data, as: UTF8.self)
    }

    static func jsonText(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed])
        else { return String(describing: value) }
        return String(decoding: data, as: UTF8.self)
    }

    /// The call as the user reads it in the question: a Bash command's text, or an MCP
    /// tool's arguments one per line, redacted and cut to `limit` characters.
    public static func display(toolName: String, input: [String: Any], limit: Int = 4_000) -> String {
        let text: String
        if toolName == "Bash" {
            text = GateRedactor.redact((input["command"] as? String) ?? "")
        } else {
            text = input.keys.sorted().map { key -> String in
                let value = input[key] ?? NSNull()
                if GateRedactor.isSecretName(key) { return "\(key): ***" }
                let shown = (value as? String) ?? jsonText(redactedJSON(value))
                return "\(key): " + cut(GateRedactor.redact(shown), 1_500)
            }.joined(separator: "\n")
        }
        return cut(text, limit)
    }

    /// One line for the question's title: the command's first line (or the tool's name).
    public static func headline(toolName: String, input: [String: Any]) -> String {
        guard toolName == "Bash" else { return toolName }
        let first = GateRedactor.redact((input["command"] as? String) ?? "")
            .split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let more = ((input["command"] as? String) ?? "").contains(where: \.isNewline) ? " …" : ""
        return cut(first.trimmingCharacters(in: .whitespaces), 160) + more
    }

    /// Secret-named keys anywhere in a JSON value, replaced by "***".
    static func redactedJSON(_ value: Any) -> Any {
        if let d = value as? [String: Any] {
            return d.reduce(into: [String: Any]()) { out, kv in
                out[kv.key] = GateRedactor.isSecretName(kv.key) ? "***" : redactedJSON(kv.value)
            }
        }
        if let a = value as? [Any] { return a.map(redactedJSON) }
        return value
    }

    static func cut(_ s: String, _ n: Int) -> String {
        s.count <= n ? s : String(s.prefix(n - 1)) + "…"
    }
}

/// Removes credentials from text before QuestBits stores it. Over-redacting is fine; a
/// secret that slips through is not. What it catches:
/// - private key blocks; known token shapes (GitHub ghp_/gho_/ghu_/ghs_/ghr_/github_pat_,
///   Slack xox?-/xapp-, OpenAI/Anthropic sk-, Stripe sk_live_/rk_live_, AWS AKIA/ASIA,
///   Google AIza, GitLab glpat-, npm_, JWTs) and Slack webhook paths;
/// - URL credentials: `https://user:secret@` → `https://user:***@`, and a long user part
///   alone (`https://<token>@`) → `https://***@`;
/// - header values: Authorization, Proxy-Authorization, Cookie, X-…-Token/Key/Secret/Auth,
///   …Api-Key (as in `-H 'Authorization: Bearer …'`); `Bearer …`, `Basic …`, `token …`;
/// - option values: `--token x`, `--password=x`, `--api-key x`, `--client-secret x`, … and
///   `-u/--user name:secret`;
/// - assignments whose name holds TOKEN, SECRET, PASSWORD, PASSWD, PWD, KEY, CREDENTIAL,
///   AUTH, COOKIE or SESSION (`GH_TOKEN=…`, `export AWS_SECRET_ACCESS_KEY=…`), and
///   `"password": "…"`-style pairs.
public enum GateRedactor {
    private static let rules: [(NSRegularExpression, String)] = {
        let specs: [(String, String, Bool)] = [
            (#"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----[\s\S]*?(?:-----END [A-Z0-9 ]*PRIVATE KEY-----|$)"#, "***private key***", false),
            (#"([a-z][a-z0-9+.-]*://)([^/\s:@'"]+):([^/\s@'"]+)@"#, "$1$2:***@", true),
            (#"([a-z][a-z0-9+.-]*://)([^/\s:@'"]{16,})@"#, "$1***@", true),
            (#"(?<![/A-Za-z0-9_-])(authorization|proxy-authorization|cookie|set-cookie|x-[a-z0-9-]*(?:token|key|secret|auth|signature)[a-z0-9-]*|[a-z0-9-]*api-?key)(\s*:\s*)([^'"\n]+)"#, "$1$2***", true),
            (#"\b(bearer|basic|token)\s+[A-Za-z0-9._~+/=-]{8,}"#, "$1 ***", true),
            (#"(--?[a-z0-9_-]*(?:token|password|passwd|secret|api[-_]?key|apikey|credential|private[-_]?key|access[-_]?key|client[-_]?secret|auth[-_]?key|session[-_]?id|cookie)[a-z0-9_-]*)(=|\s+)('[^']*'|"[^"]*"|[^\s'"]+)"#, "$1$2***", true),
            (#"((?:^|\s)(?:-u|--user)(?:=|\s+))(['"]?)([^\s:'"]+):([^\s'"]+)"#, "$1$2$3:***", true),
            (#"(?<![A-Za-z0-9_])([A-Za-z0-9_]*(?:TOKEN|SECRET|PASSWORD|PASSWD|PWD|KEY|CREDENTIAL|AUTH|COOKIE|SESSION)[A-Za-z0-9_]*)=('[^']*'|"[^"]*"|[^\s'"]+)"#, "$1=***", true),
            (#"("(?:password|passwd|secret|token|api[_-]?key|access[_-]?token|refresh[_-]?token|client[_-]?secret|private[_-]?key)"\s*:\s*)("[^"]*"|'[^']*'|[^\s,}]+)"#, "$1\"***\"", true),
            (#"((?<![A-Za-z0-9_-])(?:password|passwd|secret|token|api[_-]?key|access[_-]?token|refresh[_-]?token|client[_-]?secret|private[_-]?key)\s*:\s+)("[^"]*"|'[^']*'|[^\s,}]+)"#, "$1***", true),
            (#"\b(gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|xox[abposr]-[A-Za-z0-9-]{10,}|xapp-[A-Za-z0-9-]{10,}|sk-[A-Za-z0-9_-]{20,}|sk_live_[A-Za-z0-9]{10,}|rk_live_[A-Za-z0-9]{10,}|AKIA[0-9A-Z]{16}|ASIA[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{30,}|glpat-[A-Za-z0-9_-]{20,}|npm_[A-Za-z0-9]{30,}|eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,})"#, "***", false),
            (#"(hooks\.slack\.com/services/)[A-Za-z0-9/]+"#, "$1***", true)
        ]
        return specs.compactMap { pattern, template, caseless in
            (try? NSRegularExpression(pattern: pattern, options: caseless ? [.caseInsensitive] : []))
                .map { ($0, template) }
        }
    }()

    public static func redact(_ text: String) -> String {
        var s = text
        for (re, template) in rules {
            s = re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
        }
        return s
    }

    /// A JSON key or variable name that holds a secret.
    public static func isSecretName(_ key: String) -> Bool {
        let k = key.lowercased()
        return ["token", "secret", "password", "passwd", "api_key", "apikey", "api-key", "credential",
                "private_key", "authorization", "cookie"].contains { k.contains($0) }
    }
}
