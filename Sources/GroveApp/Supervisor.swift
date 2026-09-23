import Darwin
import GroveCore
import Foundation

/// Runtime state of one service in one worktree.
struct Runtime {
    var mode: Mode = .off
    var status: RunStatus = .stopped
    /// Our process-group leader, if we started it.
    var pid: pid_t?
    /// A matching server we didn't start (e.g. launched from a terminal or an agent).
    var externalPid: pid_t?
    var startedAt: Date?
    var lastHealthyAt: Date?
    var unhealthySince: Date?
    var restartTimes: [Date] = []
    var totalRestarts = 0
    var message: String?
    var stopping = false
}

/// A configured service bound to a concrete worktree.
struct Entry {
    let repo: RepoConfig
    let worktree: Worktree
    let service: ServiceConfig
    var key: String { "\(worktree.id)/\(service.name)" }
}

private struct PersistedState: Codable {
    var always: [String] = []
    var pids: [String: Int32] = [:]
    /// Services that were on (not always-on). Only restored after an upgrade; optional so older state files still decode.
    var on: [String]? = nil
    var savedAt: Date? = nil
}

@MainActor
final class Supervisor: ObservableObject {
    static let shared = Supervisor()

    @Published private(set) var config: AppConfig
    @Published private(set) var configError: String?
    @Published private(set) var worktrees: [String: [Worktree]] = [:]
    @Published private(set) var runtimes: [String: Runtime] = [:]
    @Published var apiState = "starting…"
    /// Claude Code sessions per worktree id, most recently active first.
    @Published private(set) var claudeSessions: [String: [ClaudeSession]] = [:]

    private(set) var entries: [String: Entry] = [:]
    private var exitSources: [String: DispatchSourceProcess] = [:]
    private var restartWork: [String: DispatchWorkItem] = [:]
    private var launching: Set<String> = []
    private var lastListeners: [Int: Sys.Listener] = [:]
    private var cwdCache: [pid_t: String] = [:]
    private var sessionCache: ClaudeSessionScanner.Cache = [:]
    private var healthInFlight = false
    private var scanned = false
    private var pendingAlways: Set<String> = []
    private var pendingOn: Set<String> = []
    /// Process groups left over from the previous run, being shut down at launch.
    private var leftoverGroups: [pid_t] = []
    private var shellEnvTask: Task<[String: String], Never>?
    private var timers: [Timer] = []
    private var api: APIServer?

    private init() {
        do { config = try AppConfig.loadStrict() } catch {
            config = AppConfig.load()
            configError = "config.json is invalid: \(error.localizedDescription)"
        }
        shellEnvTask = Task.detached { Sys.captureShellEnvironment() }
        restorePersistedState()
        api = APIServer(port: config.apiPort, supervisor: self)
        api?.start()
        timers.append(Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
            Task { @MainActor in Supervisor.shared.healthTick() }
        })
        timers.append(Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            Task { @MainActor in await Supervisor.shared.rescan() }
        })
        Task { await rescan() }
    }

    // MARK: - Queries

    func runtime(_ key: String) -> Runtime { runtimes[key] ?? Runtime() }

    func entries(for wt: Worktree) -> [Entry] {
        guard let repo = config.repos.first(where: { $0.name == wt.repo }) else { return [] }
        return repo.services.map { Entry(repo: repo, worktree: wt, service: $0) }
    }

    var activeCount: Int {
        runtimes.values.filter { [.running, .starting, .external].contains($0.status) }.count
    }

    var hasProblems: Bool {
        runtimes.values.contains { [.crashed, .failed, .unhealthy, .blocked].contains($0.status) && $0.mode != .off }
    }

    func isActive(_ wt: Worktree) -> Bool {
        entries(for: wt).contains { e in
            let rt = runtime(e.key)
            return rt.mode != .off || rt.status != .stopped
        }
    }

    func status(of e: Entry) -> ServiceStatus {
        let rt = runtime(e.key)
        return ServiceStatus(
            repo: e.repo.name, worktree: e.worktree.name, worktreePath: e.worktree.path, branch: e.worktree.branch,
            service: e.service.name, mode: rt.mode, status: rt.status, pid: rt.pid ?? rt.externalPid,
            port: e.service.port, url: e.service.port.map { "http://localhost:\($0)" },
            restarts: rt.totalRestarts, message: rt.message,
            logPath: Paths.logFile(repo: e.repo.name, worktree: e.worktree.name, service: e.service.name).path)
    }

    // MARK: - Config & scanning

    func reloadConfig() async {
        do {
            config = try AppConfig.loadStrict()
            configError = nil
        } catch {
            configError = "config.json is invalid: \(error.localizedDescription)"
        }
        await rescan()
    }

    func rescan() async {
        let repos = config.repos
        let scannedTrees = await Task.detached {
            Dictionary(uniqueKeysWithValues: repos.map { ($0.name, WorktreeScanner.scan($0)) })
        }.value
        worktrees = scannedTrees
        let cache = sessionCache
        let sessionTask: Task<(sessions: [ClaudeSession], cache: ClaudeSessionScanner.Cache), Never> = Task.detached {
            ClaudeSessionScanner.scan(cache: cache)
        }
        let (sessions, newCache) = await sessionTask.value
        sessionCache = newCache
        let allTrees = scannedTrees.values.flatMap { $0 }
        var bySession: [String: [ClaudeSession]] = [:]
        for session in sessions {
            let owner = allTrees
                .filter { session.cwd == $0.path || session.cwd.hasPrefix($0.path + "/") }
                .max { $0.path.count < $1.path.count }
            if let owner { bySession[owner.id, default: []].append(session) }
        }
        claudeSessions = bySession.mapValues { $0.sorted { $0.lastActivity > $1.lastActivity } }
        var newEntries: [String: Entry] = [:]
        for repo in repos {
            for wt in scannedTrees[repo.name] ?? [] {
                for svc in repo.services {
                    let e = Entry(repo: repo, worktree: wt, service: svc)
                    newEntries[e.key] = e
                }
            }
        }
        // Anything whose worktree/service disappeared gets stopped.
        for key in entries.keys where newEntries[key] == nil { stop(key) }
        entries = newEntries
        if !scanned {
            scanned = true
            for key in pendingAlways where entries[key] != nil {
                runtimes[key, default: Runtime()].mode = .always
            }
            pendingAlways = []
            let restore = pendingOn.filter { entries[$0] != nil }
            pendingOn = []
            if !restore.isEmpty {
                Task {
                    // Let the previous run's servers finish exiting first: e.g. `next dev` cleans up
                    // .next/ on shutdown, and a new one started mid-cleanup dies on missing files.
                    for _ in 0..<60 where leftoverGroups.contains(where: Sys.groupAlive) {
                        try? await Task.sleep(for: .milliseconds(250))
                    }
                    for key in restore { start(key, mode: .on, takeover: false) }
                }
            }
        }
        healthTick()
    }

    func addRepo(path: String, name: String?) async -> APIResponse {
        let expanded = (path as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded).standardizedFileURL
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            return APIResponse(ok: false, message: "No such folder: \(url.path)")
        }
        // If they pointed at a linked worktree, register the main checkout instead.
        let common = Sys.run("/usr/bin/git", ["-C", url.path, "rev-parse", "--path-format=absolute", "--git-common-dir"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let root = common.hasSuffix("/.git") ? String(common.dropLast(5)) : url.path
        if let existing = config.repos.first(where: { $0.expandedPath == root }) {
            return APIResponse(ok: false, message: "Already watching \(root) as '\(existing.name)'")
        }
        var repoName = name ?? (root as NSString).lastPathComponent.lowercased()
        var n = 2
        while config.repos.contains(where: { $0.name == repoName }) { repoName = "\(name ?? repoName)-\(n)"; n += 1 }
        let services = ServiceDetector.detect(repoPath: root)
        let home = Paths.home.path
        let display = root.hasPrefix(home) ? "~" + root.dropFirst(home.count) : root
        var cfg = config
        cfg.repos.append(RepoConfig(name: repoName, path: display, services: services))
        do { try cfg.save() } catch { return APIResponse(ok: false, message: "Couldn't save config: \(error.localizedDescription)") }
        await reloadConfig()
        let list = services.isEmpty
            ? "no dev scripts detected — add services in \(Paths.configFile.path)"
            : services.map { "\($0.name): \($0.command)\($0.port.map { " (:\($0))" } ?? "")" }.joined(separator: "\n  ")
        return APIResponse(ok: true, message: "Watching '\(repoName)' at \(display)\n  \(list)",
                           repos: config.repos)
    }

    // MARK: - Target resolution

    func resolveWorktree(_ target: Target) async -> Result<Worktree, String> {
        if case .success(let wt) = resolveNow(target) { return .success(wt) }
        await rescan() // maybe a brand-new worktree
        return resolveNow(target)
    }

    private func resolveNow(_ target: Target) -> Result<Worktree, String> {
        let all = worktrees.values.flatMap { $0 }
        if let q = target.worktree?.trimmingCharacters(in: .whitespaces), !q.isEmpty {
            if q.hasPrefix("/") || q.hasPrefix("~") || q.hasPrefix(".") {
                let base = target.cwd.map { URL(fileURLWithPath: $0) }
                let path = q.hasPrefix(".")
                    ? URL(fileURLWithPath: q, relativeTo: base).standardizedFileURL.path
                    : (q as NSString).expandingTildeInPath
                return byPath(path, all)
            }
            var matches = all.filter { $0.id == q || $0.name == q || $0.branch == q || "\($0.repo)/\($0.branch ?? "")" == q }
            if matches.isEmpty { matches = all.filter { $0.repo == q && $0.isMain } }
            if matches.count > 1, target.cwd != nil, case .success(let here) = byPath(target.cwd!, all) {
                // "main" is ambiguous across repos; prefer the repo you're standing in.
                matches = matches.filter { $0.repo == here.repo }
            }
            if matches.count == 1 { return .success(matches[0]) }
            if matches.isEmpty { return .failure("No worktree matches '\(q)'. Try `grove ls`.") }
            return .failure("'\(q)' is ambiguous: \(matches.map(\.id).joined(separator: ", "))")
        }
        if let cwd = target.cwd { return byPath(cwd, all) }
        return .failure("No worktree given. Pass -w <worktree> or run from inside a worktree.")
    }

    private func byPath(_ path: String, _ all: [Worktree]) -> Result<Worktree, String> {
        let p = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        let hit = all
            .filter { p == $0.path || p.hasPrefix($0.path + "/") }
            .max { $0.path.count < $1.path.count }
        if let hit { return .success(hit) }
        let watched = config.repos.map { "\($0.name) (\($0.path))" }.joined(separator: ", ")
        return .failure("\(path) isn't inside a watched worktree. Watched repos: \(watched). Add one with `grove repo add <path>`.")
    }

    func resolveEntries(_ wt: Worktree, _ names: [String]) -> Result<[Entry], String> {
        let available = entries(for: wt)
        if available.isEmpty { return .failure("Repo '\(wt.repo)' has no services configured.") }
        if names.isEmpty { return .success(available) }
        var out: [Entry] = []
        for n in names {
            guard let e = available.first(where: { $0.service.name == n }) else {
                return .failure("Unknown service '\(n)'. \(wt.repo) has: \(available.map(\.service.name).joined(separator: ", "))")
            }
            out.append(e)
        }
        return .success(out)
    }

    // MARK: - Control

    /// Turns a service on. Returns an error message if it can't start.
    @discardableResult
    func start(_ key: String, mode: Mode, takeover: Bool) -> String? {
        guard let e = entries[key] else { return "Unknown service \(key)" }
        var rt = runtime(key)
        restartWork.removeValue(forKey: key)?.cancel()

        if rt.pid != nil || launching.contains(key) {
            rt.mode = mode
            runtimes[key] = rt
            persist()
            return nil
        }
        if rt.status == .external, let ext = rt.externalPid {
            if mode == .on {
                rt.mode = .on
                runtimes[key] = rt
                return nil
            }
            // Always-on needs a process we own: replace the external one.
            killExternal(ext)
            rt.externalPid = nil
        }
        if let port = e.service.port, let holder = holder(of: port, excluding: key) {
            if !takeover {
                return "\(e.key): port \(port) is in use by \(holder.label). Re-run with --takeover to stop it and start this one."
            }
            switch holder {
            case .ours(let otherKey): stop(otherKey)
            case .external(let otherKey, let pid):
                killExternal(pid)
                if let otherKey { runtimes[otherKey]?.status = .stopped; runtimes[otherKey]?.externalPid = nil; runtimes[otherKey]?.mode = .off }
            case .unknown(let pid): killExternal(pid)
            }
        }
        rt.mode = mode
        rt.restartTimes = []
        rt.status = .starting
        rt.message = nil
        runtimes[key] = rt
        persist()
        Task { await launch(key) }
        return nil
    }

    func stop(_ key: String) {
        restartWork.removeValue(forKey: key)?.cancel()
        guard var rt = runtimes[key] else { return }
        rt.mode = .off
        rt.message = nil
        if let pid = rt.pid {
            rt.stopping = true
            terminateGroup(pid)
        } else {
            if rt.status == .external, let ext = rt.externalPid { killExternal(ext) }
            rt.externalPid = nil
            rt.status = .stopped
        }
        runtimes[key] = rt
        persist()
    }

    func restart(_ key: String) async {
        let rt = runtime(key)
        let mode: Mode = rt.mode == .off ? .on : rt.mode
        stop(key)
        for _ in 0..<40 where runtime(key).pid != nil || runtime(key).externalPid != nil {
            try? await Task.sleep(for: .milliseconds(250))
        }
        start(key, mode: mode, takeover: true)
    }

    func stopAll() {
        for (key, rt) in runtimes where rt.pid != nil {
            restartWork.removeValue(forKey: key)?.cancel()
            kill(-rt.pid!, SIGTERM)
        }
    }

    // MARK: - Process lifecycle

    private func shellEnvironment() async -> [String: String] {
        await shellEnvTask?.value ?? ProcessInfo.processInfo.environment
    }

    private func launch(_ key: String) async {
        guard let e = entries[key], !launching.contains(key), runtime(key).pid == nil else { return }
        launching.insert(key)
        defer { launching.remove(key) }

        var env = await shellEnvironment()
        env["BROWSER"] = "none"
        env["GROVE_SERVICE"] = key
        if let port = e.service.port { env["PORT"] = String(port) }
        for (k, v) in e.service.env ?? [:] { env[k] = v }

        // Give a previous holder of the port a moment to let go.
        if let port = e.service.port {
            var free = false
            for _ in 0..<40 {
                free = await Task.detached { !Sys.portOpen(port) }.value
                if free { break }
                try? await Task.sleep(for: .milliseconds(250))
            }
            if !free {
                runtimes[key]?.status = .blocked
                runtimes[key]?.message = "port \(port) is still in use"
                return
            }
        }
        guard runtime(key).mode != .off else { return } // stopped while we waited

        let log = Paths.logFile(repo: e.repo.name, worktree: e.worktree.name, service: e.service.name)
        try? FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        rotateIfLarge(log)
        appendLog(log, "\n=== \(Date().formatted(date: .abbreviated, time: .standard)) — starting `\(e.service.command)` in \(e.worktree.path)\n")

        do {
            let pid = try Sys.spawn(command: e.service.command, cwd: e.worktree.path, env: env, logPath: log.path)
            var rt = runtime(key)
            rt.pid = pid
            rt.status = .starting
            rt.startedAt = Date()
            rt.lastHealthyAt = nil
            rt.unhealthySince = nil
            rt.stopping = false
            rt.message = nil
            runtimes[key] = rt
            watchExit(key, pid)
            persist()
        } catch {
            runtimes[key]?.status = .failed
            runtimes[key]?.message = error.localizedDescription
        }
    }

    private func watchExit(_ key: String, _ pid: pid_t) {
        let src = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        src.setEventHandler { [weak self] in
            var status: Int32 = 0
            waitpid(pid, &status, 0)
            MainActor.assumeIsolated { self?.handleExit(key, pid, status) }
        }
        exitSources[key] = src
        src.resume()
        // It may have died before the source was armed.
        var status: Int32 = 0
        if waitpid(pid, &status, WNOHANG) == pid { handleExit(key, pid, status) }
    }

    private func handleExit(_ key: String, _ pid: pid_t, _ rawStatus: Int32) {
        exitSources.removeValue(forKey: key)?.cancel()
        guard var rt = runtimes[key], rt.pid == pid else { return }
        rt.pid = nil
        // Leader is gone; make sure nothing else in its group lingers (e.g. next-server child).
        terminateGroup(pid)

        let desc: String
        if rawStatus & 0x7f == 0 { desc = "exit code \((rawStatus >> 8) & 0xff)" }
        else { desc = "signal \(rawStatus & 0x7f)" }
        if let e = entries[key] {
            appendLog(Paths.logFile(repo: e.repo.name, worktree: e.worktree.name, service: e.service.name),
                      "=== \(Date().formatted(date: .abbreviated, time: .standard)) — exited (\(desc))\n")
        }

        if rt.stopping || rt.mode == .off {
            rt.stopping = false
            rt.status = .stopped
            rt.message = nil
            runtimes[key] = rt
            persist()
            return
        }
        runtimes[key] = rt
        if rt.mode == .always {
            scheduleRestart(key, reason: desc)
        } else {
            runtimes[key]?.status = .crashed
            runtimes[key]?.message = "exited (\(desc))"
            Sys.notify("Dev server stopped", "\(key) exited (\(desc))")
        }
        persist()
    }

    private func scheduleRestart(_ key: String, reason: String) {
        guard var rt = runtimes[key] else { return }
        let now = Date()
        rt.restartTimes = rt.restartTimes.filter { now.timeIntervalSince($0) < 180 }
        if rt.restartTimes.count >= 5 {
            rt.status = .failed
            rt.message = "crashed 5× in 3 min (\(reason)) — gave up. Check the log, then turn it back on."
            runtimes[key] = rt
            Sys.notify("Dev server keeps crashing", "\(key): gave up after 5 restarts")
            return
        }
        let delay = min(pow(2.0, Double(rt.restartTimes.count)), 30)
        rt.restartTimes.append(now)
        rt.totalRestarts += 1
        rt.status = .crashed
        rt.message = "\(reason) — restarting in \(Int(delay))s"
        runtimes[key] = rt
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.runtime(key).mode == .always, self.runtime(key).pid == nil else { return }
                self.restartWork.removeValue(forKey: key)
                self.runtimes[key]?.status = .starting
                Task { await self.launch(key) }
            }
        }
        restartWork[key] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func terminateGroup(_ pgid: pid_t) {
        kill(-pgid, SIGTERM)
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
            if Sys.groupAlive(pgid) { kill(-pgid, SIGKILL) }
        }
    }

    private func killExternal(_ pid: pid_t) {
        Task.detached {
            let chain = Sys.externalProcessChain(pid)
            for p in chain { kill(p, SIGTERM) }
            try? await Task.sleep(for: .seconds(5))
            for p in chain where Sys.isAlive(p) { kill(p, SIGKILL) }
        }
    }

    // MARK: - Port ownership

    enum Holder {
        case ours(String)
        case external(String?, pid_t)
        case unknown(pid_t)

        var label: String {
            switch self {
            case .ours(let k): return k
            case .external(let k?, let pid): return "\(k) (started outside Grove, pid \(pid))"
            case .external(nil, let pid), .unknown(let pid): return "another process (pid \(pid))"
            }
        }
    }

    private func holder(of port: Int, excluding key: String) -> Holder? {
        for (k, rt) in runtimes where k != key {
            guard entries[k]?.service.port == port else { continue }
            if rt.pid != nil || launching.contains(k) { return .ours(k) }
            if rt.status == .external, let pid = rt.externalPid { return .external(k, pid) }
        }
        if let l = lastListeners[port], !ownGroups.contains(l.pgid) {
            if runtimes[key]?.externalPid == l.pid { return nil }
            return .unknown(l.pid)
        }
        return nil
    }

    private var ownGroups: Set<pid_t> { Set(runtimes.values.compactMap(\.pid)) }

    // MARK: - Health

    func healthTick() {
        guard scanned, !healthInFlight else { return }
        healthInFlight = true
        let ports = Set(entries.values.compactMap(\.service.port))
        let own = ownGroups
        let cache = cwdCache
        Task {
            let listeners = await Task.detached { Sys.listeners(ports: ports, ownGroups: own, cwdCache: cache) }.value
            self.applyHealth(listeners)
            self.healthInFlight = false
        }
    }

    private func applyHealth(_ listeners: [Int: Sys.Listener]) {
        lastListeners = listeners
        for l in listeners.values { if let cwd = l.cwd { cwdCache[l.pid] = cwd } }
        if cwdCache.count > 200 { cwdCache = [:] }
        let now = Date()

        // 1. Processes we own.
        for (key, var rt) in runtimes {
            guard let pid = rt.pid, let e = entries[key] else { continue }
            if let port = e.service.port {
                let l = listeners[port]
                if let l, l.pgid == pid {
                    rt.status = .running
                    rt.lastHealthyAt = now
                    rt.unhealthySince = nil
                    rt.message = nil
                } else if rt.status == .starting {
                    let limit = TimeInterval(e.service.readyTimeout ?? 180)
                    if let started = rt.startedAt, now.timeIntervalSince(started) > limit {
                        rt.status = .unhealthy
                        rt.unhealthySince = now
                        rt.message = "not listening on :\(port) after \(Int(limit))s"
                    } else if let l {
                        rt.message = "waiting — :\(port) is held by pid \(l.pid)"
                    }
                } else {
                    rt.unhealthySince = rt.unhealthySince ?? now
                    if now.timeIntervalSince(rt.unhealthySince!) > 9 {
                        rt.status = .unhealthy
                        rt.message = "process is up but :\(port) isn't answering"
                    }
                }
                // Always-on: a wedged server (e.g. `tsx watch` after a crash) gets restarted.
                if rt.mode == .always, rt.status == .unhealthy, let since = rt.unhealthySince,
                   now.timeIntervalSince(since) > 45 {
                    rt.message = "unresponsive for 45s — restarting"
                    rt.unhealthySince = nil
                    kill(-pid, SIGTERM) // exit handler schedules the restart
                }
            } else if rt.status == .starting, let started = rt.startedAt, now.timeIntervalSince(started) > 3 {
                rt.status = .running
            }
            runtimes[key] = rt
        }

        // 2. Servers started outside the app: attribute to the deepest matching worktree.
        var externalKeys = Set<String>()
        for (port, l) in listeners where !ownGroups.contains(l.pgid) {
            guard let cwd = l.cwd else { continue }
            let match = entries.values
                .filter { $0.service.port == port && (cwd == $0.worktree.path || cwd.hasPrefix($0.worktree.path + "/")) }
                .max { $0.worktree.path.count < $1.worktree.path.count }
            guard let e = match, runtime(e.key).pid == nil, !launching.contains(e.key) else { continue }
            externalKeys.insert(e.key)
            var rt = runtime(e.key)
            rt.status = .external
            rt.externalPid = l.pid
            if rt.mode == .off { rt.mode = .on }
            rt.message = "started outside Grove"
            runtimes[e.key] = rt
        }
        for (key, rt) in runtimes where rt.status == .external && !externalKeys.contains(key) {
            runtimes[key]?.externalPid = nil
            runtimes[key]?.status = .stopped
            runtimes[key]?.message = nil
            if rt.mode == .on { runtimes[key]?.mode = .off }
        }

        // 3. Always-on: anything that should be up but isn't (and isn't already being handled) gets started.
        for (key, rt) in runtimes where rt.mode == .always && rt.pid == nil && !launching.contains(key)
            && restartWork[key] == nil && rt.status != .failed && rt.status != .external {
            guard let e = entries[key] else { continue }
            if rt.status == .blocked, let port = e.service.port, listeners[port] != nil { continue }
            runtimes[key]?.status = .starting
            Task { await launch(key) }
        }
    }

    // MARK: - Persistence

    private func persist() {
        var s = PersistedState()
        s.savedAt = Date()
        for (k, rt) in runtimes {
            if rt.mode == .always { s.always.append(k) }
            if rt.mode == .on && rt.status != .external { s.on = (s.on ?? []) + [k] }
            if let pid = rt.pid { s.pids[k] = pid }
        }
        s.always.append(contentsOf: pendingAlways)
        if !pendingOn.isEmpty { s.on = (s.on ?? []) + Array(pendingOn) }
        guard let data = try? JSONEncoder().encode(s) else { return }
        try? FileManager.default.createDirectory(at: Paths.configDir, withIntermediateDirectories: true)
        try? data.write(to: Paths.stateFile, options: .atomic)
    }

    private func restorePersistedState() {
        guard let data = try? Data(contentsOf: Paths.stateFile),
              let s = try? JSONDecoder().decode(PersistedState.self, from: data) else { return }
        // Clean up process groups left by the previous run (upgrade, crash, force quit). The group leader
        // may already be gone while its children linger, so check the group, and only when the state is
        // recent, so a days-old pid that's been reused by something unrelated is never touched.
        let recent = s.savedAt.map { Date().timeIntervalSince($0) < 600 } ?? false
        for pid in s.pids.values where recent && pid > 1 && Sys.groupAlive(pid) {
            terminateGroup(pid)
            leftoverGroups.append(pid)
        }
        pendingAlways = Set(s.always)
        // scripts/install.sh drops this marker before quitting the old copy, so an upgrade brings back
        // everything that was running. A normal Quit only brings back always-on services.
        let marker = Paths.configDir.appendingPathComponent(".restore-after-upgrade")
        if FileManager.default.fileExists(atPath: marker.path) {
            try? FileManager.default.removeItem(at: marker)
            pendingOn = Set(s.on ?? [])
        }
    }

    // MARK: - Logs

    private func appendLog(_ url: URL, _ text: String) {
        guard let h = try? FileHandle(forWritingTo: url) else {
            try? text.data(using: .utf8)?.write(to: url)
            return
        }
        h.seekToEndOfFile()
        h.write(text.data(using: .utf8) ?? Data())
        try? h.close()
    }

    private func rotateIfLarge(_ url: URL) {
        guard let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int, size > 5_000_000 else { return }
        let old = url.appendingPathExtension("1")
        try? FileManager.default.removeItem(at: old)
        try? FileManager.default.moveItem(at: url, to: old)
    }
}
