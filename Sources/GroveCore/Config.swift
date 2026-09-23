import Foundation

// MARK: - Config (~/.config/grove/config.json)

public struct ServiceConfig: Codable, Hashable, Sendable {
    public var name: String
    /// Shell command run from the worktree root, e.g. "pnpm dev:fe".
    public var command: String
    /// Port the service listens on. Used for health checks, URLs and conflict detection.
    public var port: Int?
    /// Extra environment variables for this service.
    public var env: [String: String]?
    /// Seconds to wait for the port to open before marking the service unhealthy (default 180).
    public var readyTimeout: Int?

    public init(name: String, command: String, port: Int? = nil, env: [String: String]? = nil, readyTimeout: Int? = nil) {
        self.name = name
        self.command = command
        self.port = port
        self.env = env
        self.readyTimeout = readyTimeout
    }
}

public struct RepoConfig: Codable, Hashable, Sendable {
    public var name: String
    public var path: String
    public var services: [ServiceConfig]

    public init(name: String, path: String, services: [ServiceConfig]) {
        self.name = name
        self.path = path
        self.services = services
    }

    public var expandedPath: String { (path as NSString).expandingTildeInPath }
}

public struct AppConfig: Codable, Sendable {
    /// Port of the local control API that grove talks to (127.0.0.1 only).
    public var apiPort: Int
    public var repos: [RepoConfig]

    public init(apiPort: Int, repos: [RepoConfig]) {
        self.apiPort = apiPort
        self.repos = repos
    }

    public static let defaultAPIPort = 7787

    public static let starter = AppConfig(apiPort: defaultAPIPort, repos: [
        RepoConfig(name: "troupe", path: "~/Dev/Troupe", services: [
            ServiceConfig(name: "be", command: "pnpm dev:be", port: 3000),
            ServiceConfig(name: "fe", command: "pnpm dev:fe", port: 3001),
            ServiceConfig(name: "worker", command: "pnpm dev:worker"),
        ]),
        RepoConfig(name: "marketing", path: "~/Dev/troupe-marketing-website", services: [
            ServiceConfig(name: "web", command: "pnpm dev -p 3100", port: 3100),
        ]),
    ])

    public static func load() -> AppConfig {
        if let data = try? Data(contentsOf: Paths.configFile),
           let cfg = try? JSONDecoder().decode(AppConfig.self, from: data) {
            return cfg
        }
        return starter
    }

    /// Loads config, throwing on a malformed file (so the app can surface the error).
    public static func loadStrict() throws -> AppConfig {
        guard FileManager.default.fileExists(atPath: Paths.configFile.path) else {
            try starter.save()
            return starter
        }
        return try JSONDecoder().decode(AppConfig.self, from: Data(contentsOf: Paths.configFile))
    }

    public func save() throws {
        try FileManager.default.createDirectory(at: Paths.configDir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try enc.encode(self).write(to: Paths.configFile, options: .atomic)
    }
}

public enum Paths {
    public static let home = FileManager.default.homeDirectoryForCurrentUser
    public static let configDir = home.appendingPathComponent(".config/grove")
    public static let configFile = configDir.appendingPathComponent("config.json")
    public static let stateFile = configDir.appendingPathComponent("state.json")
    public static let logsDir = home.appendingPathComponent("Library/Logs/Grove")

    public static func logFile(repo: String, worktree: String, service: String) -> URL {
        logsDir.appendingPathComponent(repo).appendingPathComponent(worktree).appendingPathComponent("\(service).log")
    }
}

// MARK: - Wire types shared by the app's HTTP API and grove

public enum Mode: String, Codable, Sendable, CaseIterable {
    case off, on, always
}

public enum RunStatus: String, Codable, Sendable {
    case stopped, starting, running, unhealthy, crashed, failed, external, blocked
}

public struct ServiceStatus: Codable, Sendable {
    public var repo: String
    public var worktree: String
    public var worktreePath: String
    public var branch: String?
    public var service: String
    public var mode: Mode
    public var status: RunStatus
    public var pid: Int32?
    public var port: Int?
    public var url: String?
    public var restarts: Int
    public var message: String?
    public var logPath: String

    public init(repo: String, worktree: String, worktreePath: String, branch: String?, service: String, mode: Mode,
                status: RunStatus, pid: Int32?, port: Int?, url: String?, restarts: Int, message: String?, logPath: String) {
        self.repo = repo; self.worktree = worktree; self.worktreePath = worktreePath; self.branch = branch
        self.service = service; self.mode = mode; self.status = status; self.pid = pid; self.port = port
        self.url = url; self.restarts = restarts; self.message = message; self.logPath = logPath
    }
}

public struct WorktreeInfo: Codable, Sendable {
    public var repo: String
    public var name: String
    public var path: String
    public var branch: String?
    public init(repo: String, name: String, path: String, branch: String?) {
        self.repo = repo; self.name = name; self.path = path; self.branch = branch
    }
}

/// Identifies a worktree: either explicitly ("troupe/main", "main", a branch name, a path) or by the caller's cwd.
public struct Target: Codable, Sendable {
    public var worktree: String?
    public var cwd: String?
    public init(worktree: String?, cwd: String?) { self.worktree = worktree; self.cwd = cwd }
}

public struct ActionRequest: Codable, Sendable {
    public var target: Target
    public var services: [String]
    public var always: Bool
    public var takeover: Bool
    public var wait: Bool
    public init(target: Target, services: [String], always: Bool = false, takeover: Bool = false, wait: Bool = true) {
        self.target = target; self.services = services; self.always = always; self.takeover = takeover; self.wait = wait
    }
}

public struct AddRepoRequest: Codable, Sendable {
    public var path: String
    public var name: String?
    public init(path: String, name: String?) { self.path = path; self.name = name }
}

public struct APIResponse: Codable, Sendable {
    public var ok: Bool
    public var message: String
    public var services: [ServiceStatus]
    public var worktrees: [WorktreeInfo]?
    public var repos: [RepoConfig]?
    public init(ok: Bool, message: String, services: [ServiceStatus] = [], worktrees: [WorktreeInfo]? = nil, repos: [RepoConfig]? = nil) {
        self.ok = ok; self.message = message; self.services = services; self.worktrees = worktrees; self.repos = repos
    }
}

// MARK: - Service auto-detection for `grove repo add`

public enum ServiceDetector {
    /// Reads package.json `dev` / `dev:*` scripts and turns them into services.
    public static func detect(repoPath: String) -> [ServiceConfig] {
        let pkg = URL(fileURLWithPath: repoPath).appendingPathComponent("package.json")
        guard let data = try? Data(contentsOf: pkg),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let scripts = json["scripts"] as? [String: String] else { return [] }
        let runner = packageManager(repoPath: repoPath, packageJSON: json)
        return scripts.keys.sorted().compactMap { key in
            guard key == "dev" || key.hasPrefix("dev:") else { return nil }
            let name = key == "dev" ? "dev" : String(key.dropFirst(4)).replacingOccurrences(of: ":", with: "-")
            let command = runner == "npm" ? "npm run \(key)" : "\(runner) \(key)"
            return ServiceConfig(name: name, command: command, port: parsePort(scripts[key] ?? ""))
        }
    }

    static func packageManager(repoPath: String, packageJSON: [String: Any]) -> String {
        if let pm = packageJSON["packageManager"] as? String, let name = pm.split(separator: "@").first {
            return String(name)
        }
        let fm = FileManager.default
        if fm.fileExists(atPath: repoPath + "/pnpm-lock.yaml") { return "pnpm" }
        if fm.fileExists(atPath: repoPath + "/bun.lockb") || fm.fileExists(atPath: repoPath + "/bun.lock") { return "bun" }
        if fm.fileExists(atPath: repoPath + "/yarn.lock") { return "yarn" }
        return "npm"
    }

    static func parsePort(_ script: String) -> Int? {
        let parts = script.split(separator: " ").map(String.init)
        for (i, p) in parts.enumerated() {
            if (p == "-p" || p == "--port"), i + 1 < parts.count, let n = Int(parts[i + 1]) { return n }
            if p.hasPrefix("--port="), let n = Int(p.dropFirst(7)) { return n }
            if p.hasPrefix("PORT="), let n = Int(p.dropFirst(5)) { return n }
        }
        if script.contains("next dev") || script == "next" { return 3000 }
        if script.contains("vite") { return 5173 }
        return nil
    }
}
