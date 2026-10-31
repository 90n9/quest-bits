import Foundation

/// Links the bundled `questbits` CLI (Contents/Resources/cli/questbits) into ~/.local/bin so
/// people can type it; Settings installs and removes the link. Hooks never rely on it: they
/// call the binary by its full path in the bundle. Only a link this app made is ever
/// replaced or removed silently. Anything else at that path is reported, never touched: a
/// file or folder always, another link unless the user confirms replacing it.
enum CLIInstaller {
    #if DEV_BUILD
    static let linkName = "questbits-dev"
    #else
    static let linkName = "questbits"
    #endif

    enum State: Equatable {
        case notInstalled
        case installed                    // a link to this app's CLI
        case linkedElsewhere(String)      // a link to something else (its destination)
        case notALink                     // a file or folder the user put there
    }

    enum InstallError: Error, CustomStringConvertible {
        case noBundledCLI
        case occupied(String)             // path holds a file or folder
        case linkedElsewhere(String)      // a link to another target: needs `replace: true`
        case notOurs(String)              // remove: the path is not a link to this CLI
        case io(String)

        var description: String {
            switch self {
            case .noBundledCLI: return "This build has no questbits CLI in its bundle."
            case .occupied(let p): return "\(p) already exists and is not a link. Move it away first."
            case .linkedElsewhere(let d): return "The link already points to \(d)."
            case .notOurs(let p): return "\(p) is not a link to this app's CLI, so it was left alone."
            case .io(let m): return m
            }
        }
    }

    /// The CLI inside this app's bundle, when it is there and executable.
    static func bundledCLIPath(bundle: Bundle = .main) -> String? {
        guard let resources = bundle.resourceURL else { return nil }
        let path = resources.appendingPathComponent("cli/questbits").path
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    static func linkURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent(".local/bin", isDirectory: true).appendingPathComponent(linkName)
    }

    /// What sits at `link` now, compared with `target` (the bundled CLI). Read with lstat
    /// semantics: a link is seen as a link even when its destination is gone.
    static func state(link: URL, target: String) -> State {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: link.path) else { return .notInstalled }
        guard attrs[.type] as? FileAttributeType == .typeSymbolicLink else { return .notALink }
        guard let dest = try? fm.destinationOfSymbolicLink(atPath: link.path) else { return .linkedElsewhere("?") }
        let absolute = dest.hasPrefix("/") ? dest
            : link.deletingLastPathComponent().appendingPathComponent(dest).standardizedFileURL.path
        return absolute == target ? .installed : .linkedElsewhere(absolute)
    }

    /// Make `link` point at `target`, creating ~/.local/bin when needed. A link to anything
    /// else is replaced only with `replace: true` (after the user agreed); a file or folder
    /// never is. Installing again over our own link is a no-op.
    static func install(link: URL, target: String, replace: Bool = false) throws {
        let fm = FileManager.default
        switch state(link: link, target: target) {
        case .installed: return
        case .notALink: throw InstallError.occupied(link.path)
        case .linkedElsewhere(let dest):
            guard replace else { throw InstallError.linkedElsewhere(dest) }
            do { try fm.removeItem(at: link) } catch { throw InstallError.io("Could not replace the link: \(error.localizedDescription)") }
        case .notInstalled: break
        }
        do {
            try fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.createSymbolicLink(atPath: link.path, withDestinationPath: target)
        } catch {
            throw InstallError.io("Could not create the link: \(error.localizedDescription)")
        }
    }

    /// Remove `link`, only when it is our link to `target`. Nothing there is not an error.
    static func remove(link: URL, target: String) throws {
        switch state(link: link, target: target) {
        case .notInstalled: return
        case .installed:
            do { try FileManager.default.removeItem(at: link) }
            catch { throw InstallError.io("Could not remove the link: \(error.localizedDescription)") }
        case .linkedElsewhere, .notALink:
            throw InstallError.notOurs(link.path)
        }
    }
}
