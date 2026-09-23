import GroveCore
import Foundation

/// A Claude Code session from the Claude desktop app, matched to worktrees by its cwd.
struct ClaudeSession: Identifiable, Hashable {
    let id: String          // "local_<uuid>"
    let title: String
    let cwd: String
    let lastActivity: Date

    /// Deep link that focuses this session in the Claude desktop app.
    var url: URL { URL(string: "claude://code/continue?session=\(id)&source=desktop_action")! }
}

enum ClaudeSessionScanner {
    static let root = Paths.home.appendingPathComponent("Library/Application Support/Claude/claude-code-sessions")

    /// Parsed session per file, keyed by path and invalidated by modification date.
    typealias Cache = [String: (modified: Date, session: ClaudeSession?)]

    /// Reads the desktop app's session files (`<account>/<org>/local_*.json`), skipping archived ones.
    /// Call off the main thread.
    static func scan(cache: Cache) -> (sessions: [ClaudeSession], cache: Cache) {
        let fm = FileManager.default
        var newCache: Cache = [:]
        var sessions: [ClaudeSession] = []
        for account in (try? fm.contentsOfDirectory(atPath: root.path)) ?? [] {
            let accountDir = root.appendingPathComponent(account)
            for org in (try? fm.contentsOfDirectory(atPath: accountDir.path)) ?? [] {
                let orgDir = accountDir.appendingPathComponent(org)
                for file in (try? fm.contentsOfDirectory(atPath: orgDir.path)) ?? []
                where file.hasPrefix("local_") && file.hasSuffix(".json") {
                    let path = orgDir.appendingPathComponent(file).path
                    let modified = (try? fm.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? .distantPast
                    let session: ClaudeSession?
                    if let hit = cache[path], hit.modified == modified {
                        session = hit.session
                    } else {
                        session = parse(path)
                    }
                    newCache[path] = (modified, session)
                    if let session { sessions.append(session) }
                }
            }
        }
        return (sessions, newCache)
    }

    private static func parse(_ path: String) -> ClaudeSession? {
        guard let data = FileManager.default.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = json["sessionId"] as? String,
              let cwd = json["cwd"] as? String,
              (json["isArchived"] as? Bool) != true,
              // A removed worktree's session would otherwise be attributed to the enclosing main checkout.
              FileManager.default.fileExists(atPath: cwd) else { return nil }
        let ms = (json["lastActivityAt"] as? Double) ?? (json["createdAt"] as? Double) ?? 0
        let title = (json["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled session"
        return ClaudeSession(id: id, title: title, cwd: cwd, lastActivity: Date(timeIntervalSince1970: ms / 1000))
    }
}
