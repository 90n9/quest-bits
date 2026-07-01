import Foundation

/// Registers the bundled MCP server with Claude Code by adding an entry to ~/.claude.json.
/// Merges into the existing file (never clobbers other config) and only rewrites when the
/// command path is missing or has changed (e.g. app moved to /Applications).
enum MCPRegistration {
    private static var configURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
    }

    @discardableResult
    static func registerIfNeeded(force: Bool = false) -> Bool {
        guard let mcpPath = bundledMCPPath() else { return false }

        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: configURL),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            root = obj
        }

        var servers = root["mcpServers"] as? [String: Any] ?? [:]
        let existing = (servers["todo"] as? [String: Any])?["command"] as? String
        if !force, existing == mcpPath { return true } // already up to date

        servers["todo"] = [
            "command": mcpPath,
            "args": [String](),
            "env": [String: String]()
        ]
        root["mcpServers"] = servers

        guard let out = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]) else { return false }
        try? out.write(to: configURL, options: .atomic)
        NSLog("todo: registered MCP server at \(mcpPath)")
        return true
    }

    /// The command path currently registered in ~/.claude.json (nil if absent).
    static func registeredPath() -> String? {
        guard let data = try? Data(contentsOf: configURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = obj["mcpServers"] as? [String: Any],
              let todo = servers["todo"] as? [String: Any] else { return nil }
        return todo["command"] as? String
    }

    /// True when the registered path matches the current bundle's binary.
    static func isUpToDate() -> Bool {
        guard let p = bundledMCPPath() else { return false }
        return registeredPath() == p
    }

    /// Path to the MCP binary inside the app bundle: Contents/Resources/mcp-server/todo-mcp
    static func bundledMCPPath() -> String? {
        guard let resources = Bundle.main.resourceURL else { return nil }
        let path = resources.appendingPathComponent("mcp-server/todo-mcp").path
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }
}
