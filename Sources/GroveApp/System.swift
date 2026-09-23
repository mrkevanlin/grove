import Darwin
import Foundation

/// Low-level process/OS helpers. Nothing here touches app state.
enum Sys {
    // MARK: Running helper commands

    /// Runs a command synchronously and returns stdout. Call off the main thread.
    static func run(_ launchPath: String, _ args: [String], timeout: TimeInterval = 15, env: [String: String]? = nil) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        if let env { p.environment = env }
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return "" }
        let deadline = DispatchTime.now() + timeout
        DispatchQueue.global().asyncAfter(deadline: deadline) { if p.isRunning { p.terminate() } }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Login shell environment

    /// The user's interactive login-shell environment (so nvm/pnpm/volta PATHs work),
    /// captured once. Falls back to the app's own environment.
    static func captureShellEnvironment() -> [String: String] {
        let marker = "__GROVE_ENV__"
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let output = run(shell, ["-l", "-i", "-c", "echo \(marker); /usr/bin/env"], timeout: 10)
        guard let range = output.range(of: marker + "\n") else { return ProcessInfo.processInfo.environment }
        var env: [String: String] = [:]
        for line in output[range.upperBound...].split(separator: "\n") {
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq])
            guard key.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil else { continue }
            env[key] = String(line[line.index(after: eq)...])
        }
        // Don't leak shell-session specifics into dev servers.
        for k in ["SHLVL", "_", "PWD", "OLDPWD", "TERM_SESSION_ID", "ITERM_SESSION_ID"] { env.removeValue(forKey: k) }
        return env.isEmpty || env["PATH"] == nil ? ProcessInfo.processInfo.environment : env
    }

    // MARK: Spawning

    /// Spawns `command` via zsh in its own process group (pgid == returned pid),
    /// with stdout/stderr appended to `logPath`.
    static func spawn(command: String, cwd: String, env: [String: String], logPath: String) throws -> pid_t {
        var fa: posix_spawn_file_actions_t? = nil
        var attr: posix_spawnattr_t? = nil
        posix_spawn_file_actions_init(&fa)
        posix_spawnattr_init(&attr)
        defer {
            posix_spawn_file_actions_destroy(&fa)
            posix_spawnattr_destroy(&attr)
        }
        posix_spawn_file_actions_addopen(&fa, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&fa, 1, logPath, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        posix_spawn_file_actions_adddup2(&fa, 1, 2)
        posix_spawn_file_actions_addchdir_np(&fa, cwd)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attr, 0)

        let argv = ["/bin/zsh", "-c", command]
        let envp = env.map { "\($0.key)=\($0.value)" }
        var cArgv = argv.map { strdup($0) } + [nil]
        var cEnv = envp.map { strdup($0) } + [nil]
        defer {
            cArgv.forEach { free($0) }
            cEnv.forEach { free($0) }
        }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, "/bin/zsh", &fa, &attr, &cArgv, &cEnv)
        guard rc == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(rc),
                          userInfo: [NSLocalizedDescriptionKey: "spawn failed: \(String(cString: strerror(rc)))"])
        }
        return pid
    }

    static func isAlive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 || errno == EPERM }

    static func groupAlive(_ pgid: pid_t) -> Bool { kill(-pgid, 0) == 0 || errno == EPERM }

    // MARK: Ports

    /// Quick check whether something accepts TCP connections on localhost:port (IPv4 or IPv6).
    static func portOpen(_ port: Int) -> Bool {
        connect(port: port, ipv6: false) || connect(port: port, ipv6: true)
    }

    private static func connect(port: Int, ipv6: Bool) -> Bool {
        let fd = socket(ipv6 ? AF_INET6 : AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var tv = timeval(tv_sec: 0, tv_usec: 300_000)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        if ipv6 {
            var addr = sockaddr_in6()
            addr.sin6_family = sa_family_t(AF_INET6)
            addr.sin6_port = in_port_t(UInt16(port).bigEndian)
            addr.sin6_addr = in6addr_loopback
            return withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) == 0
                }
            }
        } else {
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = in_port_t(UInt16(port).bigEndian)
            addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
            return withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
                }
            }
        }
    }

    struct Listener { let pid: pid_t; let pgid: pid_t; let cwd: String? }

    /// Which process is listening on each of `ports` (only the ports asked for).
    /// cwd is looked up only for processes outside `ownGroups`, using `cwdCache` when possible.
    static func listeners(ports: Set<Int>, ownGroups: Set<pid_t>, cwdCache: [pid_t: String]) -> [Int: Listener] {
        guard !ports.isEmpty else { return [:] }
        let out = run("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-Fpn"], timeout: 5)
        var result: [Int: pid_t] = [:]
        var pid: pid_t = 0
        for line in out.split(separator: "\n") {
            if line.hasPrefix("p") { pid = pid_t(line.dropFirst()) ?? 0 }
            else if line.hasPrefix("n"), let colon = line.lastIndex(of: ":"),
                    let port = Int(line[line.index(after: colon)...]), ports.contains(port), result[port] == nil {
                result[port] = pid
            }
        }
        return result.mapValues { pid in
            let pgid = getpgid(pid)
            if ownGroups.contains(pgid) { return Listener(pid: pid, pgid: pgid, cwd: nil) }
            return Listener(pid: pid, pgid: pgid, cwd: cwdCache[pid] ?? cwd(of: pid))
        }
    }

    static func cwd(of pid: pid_t) -> String? {
        let out = run("/usr/sbin/lsof", ["-a", "-p", "\(pid)", "-d", "cwd", "-Fn"], timeout: 3)
        return out.split(separator: "\n").first(where: { $0.hasPrefix("n") }).map { String($0.dropFirst()) }
    }

    /// For a server we didn't start: the listener plus its parents up to (not including) the first shell,
    /// so killing them frees the port without taking down whoever launched it.
    static func externalProcessChain(_ pid: pid_t) -> [pid_t] {
        let stopAt: Set<String> = [
            "zsh", "bash", "sh", "fish", "login", "launchd", "tmux", "Terminal", "iTerm2",
            "claude", "Claude", "Cursor", "cursor", "Codex", "codex", "ChatGPT", "chatgpt",
        ]
        var chain: [pid_t] = [pid]
        var current = pid
        for _ in 0..<8 {
            let out = run("/bin/ps", ["-o", "ppid=,comm=", "-p", "\(current)"], timeout: 2)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let parts = out.split(separator: " ", maxSplits: 1)
            guard parts.count == 2, let ppid = pid_t(parts[0]), ppid > 1 else { break }
            let parentOut = run("/bin/ps", ["-o", "comm=", "-p", "\(ppid)"], timeout: 2)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let name = (parentOut as NSString).lastPathComponent.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            if stopAt.contains(name) || name.isEmpty { break }
            chain.append(ppid)
            current = ppid
        }
        return chain
    }

    // MARK: Notifications

    static func notify(_ title: String, _ body: String) {
        let esc = { (s: String) in s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
        DispatchQueue.global().async {
            _ = run("/usr/bin/osascript", ["-e", "display notification \"\(esc(body))\" with title \"\(esc(title))\""])
        }
    }
}
