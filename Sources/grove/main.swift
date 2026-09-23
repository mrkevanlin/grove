import GroveCore
import Foundation

let usage = """
grove — control dev servers managed by the Grove menu bar app.

The worktree defaults to the one containing the current directory.

USAGE
  grove status [-w WT] [--json]         Services in a worktree (or everything active, if outside one)
  grove up [SVC...] [-w WT] [--always] [--takeover] [--no-wait]
                                         Start services (all of the repo's if none given) and wait until ready
  grove down [SVC...] [-w WT]           Stop services
  grove restart [SVC...] [-w WT]        Restart services
  grove logs SVC [-w WT] [-n N] [-f]    Show (or follow) a service's log
  grove url SVC [-w WT]                 Print the service's URL
  grove ls [--json]                     List watched repos and worktrees
  grove repo add PATH [--name NAME]     Watch another repo (services detected from package.json dev scripts)
  grove repo list                       Show watched repos and their services
  grove reload                          Re-read ~/.config/grove/config.json

FLAGS
  -w, --worktree WT   Worktree: "troupe/main", "main", a branch name, or a path
  --always            Keep it running: auto-restart on crash or hang
  --takeover          If another worktree holds the port, stop it and start this one
  --json              Machine-readable output

EXIT CODES
  0 ok · 1 failed / not ready · 2 usage error · 3 app not reachable
  4 current directory isn't in a watched worktree (status only)
"""

// MARK: - Args

var args = Array(CommandLine.arguments.dropFirst())
func flag(_ names: String...) -> Bool {
    guard let i = args.firstIndex(where: { names.contains($0) }) else { return false }
    args.remove(at: i)
    return true
}
func option(_ names: String...) -> String? {
    guard let i = args.firstIndex(where: { names.contains($0) }), i + 1 < args.count else { return nil }
    let v = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return v
}
func fail(_ msg: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data((msg + "\n").utf8))
    exit(code)
}

if args.isEmpty || flag("-h", "--help", "help") { print(usage); exit(0) }
let command = args.removeFirst()
let json = flag("--json")
let always = flag("--always")
let takeover = flag("--takeover")
let noWait = flag("--no-wait")
let follow = flag("-f", "--follow")
let worktree = option("-w", "--worktree")
let lines = option("-n").flatMap(Int.init) ?? 60
let name = option("--name")
if let unknown = args.first(where: { $0.hasPrefix("-") }) { fail("Unknown flag \(unknown)\n\n\(usage)", code: 2) }
let cwd = FileManager.default.currentDirectoryPath
let target = Target(worktree: worktree, cwd: cwd)

// MARK: - HTTP

let config = AppConfig.load()
let base = URL(string: "http://127.0.0.1:\(config.apiPort)")!

func call(_ method: String, _ path: String, _ body: Encodable? = nil, timeout: TimeInterval = 240) -> APIResponse? {
    var req = URLRequest(url: base.appendingPathComponent(path), timeoutInterval: timeout)
    req.httpMethod = method
    req.setValue("1", forHTTPHeaderField: "X-Grove")
    if let body {
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONEncoder().encode(body)
    }
    let sem = DispatchSemaphore(value: 0)
    var result: APIResponse?
    URLSession.shared.dataTask(with: req) { data, _, _ in
        if let data { result = try? JSONDecoder().decode(APIResponse.self, from: data) }
        sem.signal()
    }.resume()
    sem.wait()
    return result
}

func request(_ method: String, _ path: String, _ body: Encodable? = nil) -> APIResponse {
    if let r = call(method, path, body) { return r }
    // App not running? Launch it and retry.
    if call("GET", "health", timeout: 2) == nil {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-g", "-b", "ai.troupe.grove"]
        try? p.run()
        p.waitUntilExit()
        for _ in 0..<40 {
            usleep(250_000)
            if call("GET", "health", timeout: 1) != nil { break }
        }
        if let r = call(method, path, body) { return r }
    }
    fail("Can't reach the Grove app on 127.0.0.1:\(config.apiPort). Is it installed? (open -a Grove)", code: 3)
}

// MARK: - Output

func printServices(_ services: [ServiceStatus]) {
    guard !services.isEmpty else { return }
    let rows = services.map { s -> [String] in
        let mode = s.mode == .always ? "always" : s.mode.rawValue
        return ["\(s.repo)/\(s.worktree)", s.service, s.status.rawValue, mode, s.url ?? "-", s.pid.map { "\($0)" } ?? "-", s.message ?? ""]
    }
    let header = ["WORKTREE", "SERVICE", "STATUS", "MODE", "URL", "PID", ""]
    let widths = (0..<header.count).map { i in ([header] + rows).map { $0[i].count }.max() ?? 0 }
    for row in [header] + rows {
        print(zip(row, widths).map { $0.padding(toLength: $1, withPad: " ", startingAt: 0) }.joined(separator: "  ")
            .trimmingCharacters(in: .whitespaces))
    }
}

func tail(_ path: String, _ n: Int) -> String {
    guard let data = FileManager.default.contents(atPath: path) else { return "" }
    let text = String(decoding: data.suffix(400_000), as: UTF8.self)
    return text.split(separator: "\n", omittingEmptySubsequences: false).suffix(n).joined(separator: "\n")
}

func emit(_ r: APIResponse, showFailureLogs: Bool = false, code: Int32? = nil) -> Never {
    if json {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        print(String(decoding: (try? enc.encode(r)) ?? Data(), as: UTF8.self))
        exit(code ?? (r.ok ? 0 : 1))
    }
    if !r.message.isEmpty && !(r.ok && r.message == "ready") {
        (r.ok ? FileHandle.standardOutput : FileHandle.standardError).write(Data((r.message + "\n").utf8))
    }
    printServices(r.services)
    if showFailureLogs && !r.ok {
        for s in r.services where s.status != .running && s.status != .external && !tail(s.logPath, 1).isEmpty {
            print("\n--- last 30 lines of \(s.service) log (\(s.logPath)) ---")
            print(tail(s.logPath, 30))
        }
    }
    exit(r.ok ? 0 : 1)
}

func action(_ path: String) -> Never {
    let req = ActionRequest(target: target, services: args, always: always, takeover: takeover, wait: !noWait)
    emit(request("POST", path, req), showFailureLogs: path != "down")
}

func singleService(_ what: String) -> ServiceStatus {
    guard args.count == 1 else { fail("usage: grove \(what) SVC [-w WT]", code: 2) }
    let r = request("POST", "status", target)
    guard r.ok else { fail(r.message) }
    guard let s = r.services.first(where: { $0.service == args[0] }) else {
        fail("Unknown service '\(args[0])'. Available: \(r.services.map(\.service).joined(separator: ", "))")
    }
    return s
}

// MARK: - Commands

switch command {
case "up", "start": action("up")
case "down", "stop": action("down")
case "restart": action("restart")

case "status", "st":
    let r = request("POST", "status", target)
    if !r.ok && worktree == nil {
        // Not inside a watched worktree: say so (exit 4, so agents can tell), then show what's active elsewhere.
        FileHandle.standardError.write(Data((r.message + "\n").utf8))
        let all = request("POST", "status", Target(worktree: nil, cwd: nil))
        if json {
            emit(APIResponse(ok: false, message: r.message, services: all.services), code: 4)
        }
        if !all.services.isEmpty {
            print("\nActive in other worktrees:")
            printServices(all.services)
        }
        exit(4)
    }
    emit(r)

case "logs", "log":
    let s = singleService("logs")
    guard FileManager.default.fileExists(atPath: s.logPath) else { fail("No log yet at \(s.logPath)") }
    if follow {
        let t = Process()
        t.executableURL = URL(fileURLWithPath: "/usr/bin/tail")
        t.arguments = ["-n", "\(lines)", "-F", s.logPath]
        try? t.run()
        t.waitUntilExit()
        exit(0)
    }
    print(tail(s.logPath, lines))

case "url":
    let s = singleService("url")
    guard let url = s.url else { fail("\(s.service) has no port configured") }
    print(url)

case "ls", "list":
    let r = request("GET", "worktrees")
    if json { emit(r) }
    for repo in r.repos ?? [] {
        print("\(repo.name)  \(repo.path)  [\(repo.services.map(\.name).joined(separator: ", "))]")
        for wt in (r.worktrees ?? []).filter({ $0.repo == repo.name }) {
            print("  \(repo.name)/\(wt.name)\(wt.branch.map { "  (\($0))" } ?? "")")
        }
    }

case "repo":
    guard !args.isEmpty else { fail("usage: grove repo add PATH [--name NAME] | grove repo list", code: 2) }
    switch args.removeFirst() {
    case "add":
        guard args.count == 1 else { fail("usage: grove repo add PATH [--name NAME]", code: 2) }
        let path = URL(fileURLWithPath: args[0], relativeTo: URL(fileURLWithPath: cwd)).standardizedFileURL.path
        emit(request("POST", "repos", AddRepoRequest(path: path, name: name)))
    case "list", "ls":
        let r = request("GET", "worktrees")
        for repo in r.repos ?? [] {
            print("\(repo.name)  \(repo.path)")
            for s in repo.services { print("  \(s.name): \(s.command)\(s.port.map { "  (:\($0))" } ?? "")") }
        }
        print("\nEdit: \(Paths.configFile.path)  (then `grove reload`)")
    default:
        fail("usage: grove repo add PATH [--name NAME] | grove repo list", code: 2)
    }

case "reload":
    emit(request("POST", "reload"))

default:
    fail("Unknown command '\(command)'\n\n\(usage)", code: 2)
}
