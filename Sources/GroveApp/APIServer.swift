import GroveCore
import Foundation
import Network

/// Tiny HTTP/1.1 JSON API on 127.0.0.1 for grove (and agents via curl).
///
/// Every request must carry `X-Grove: 1` and no `Origin`, so web pages can't drive it
/// (a custom header forces a CORS preflight, which we never answer).
@MainActor
final class APIServer {
    private let port: Int
    private unowned let supervisor: Supervisor
    private var listener: NWListener?

    init(port: Int, supervisor: Supervisor) {
        self.port = port
        self.supervisor = supervisor
    }

    func start() {
        do {
            let params = NWParameters.tcp
            params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(integerLiteral: UInt16(port)))
            params.allowLocalEndpointReuse = true
            let l = try NWListener(using: params)
            l.newConnectionHandler = { [weak self] conn in
                MainActor.assumeIsolated { self?.accept(conn) }
            }
            l.stateUpdateHandler = { [weak self] state in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    switch state {
                    case .ready: self.supervisor.apiState = "grove API on 127.0.0.1:\(self.port)"
                    case .failed(let err): self.supervisor.apiState = "API failed on :\(self.port): \(err)"
                    default: break
                    }
                }
            }
            l.start(queue: .main)
            listener = l
        } catch {
            supervisor.apiState = "API failed: \(error.localizedDescription)"
        }
    }

    private func accept(_ conn: NWConnection) {
        conn.start(queue: .main)
        receive(conn, buffer: Data())
    }

    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
            MainActor.assumeIsolated {
                guard let self else { return }
                var buf = buffer
                if let data { buf.append(data) }
                if let req = HTTPRequest(buf) {
                    Task { await self.respond(conn, req) }
                } else if done || error != nil || buf.count > 1_000_000 {
                    conn.cancel()
                } else {
                    self.receive(conn, buffer: buf)
                }
            }
        }
    }

    private func respond(_ conn: NWConnection, _ req: HTTPRequest) async {
        let (code, body): (Int, APIResponse)
        if req.headers["x-grove"] != "1" || req.headers["origin"] != nil {
            (code, body) = (403, APIResponse(ok: false, message: "forbidden"))
        } else {
            body = await route(req)
            code = body.ok ? 200 : 400
        }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let json = (try? enc.encode(body)) ?? Data()
        var head = "HTTP/1.1 \(code) \(code == 200 ? "OK" : "Error")\r\n"
        head += "Content-Type: application/json\r\nContent-Length: \(json.count)\r\nConnection: close\r\n\r\n"
        conn.send(content: Data(head.utf8) + json, completion: .contentProcessed { _ in conn.cancel() })
    }

    private func route(_ req: HTTPRequest) async -> APIResponse {
        let sup = supervisor
        let dec = JSONDecoder()
        switch (req.method, req.path) {
        case ("GET", "/health"):
            return APIResponse(ok: true, message: "ok")

        case ("POST", "/status"):
            let target = (try? dec.decode(Target.self, from: req.body)) ?? Target(worktree: nil, cwd: nil)
            if target.worktree == nil && target.cwd == nil {
                let all = sup.entries.values
                    .filter { sup.isActive($0.worktree) }
                    .sorted { $0.key < $1.key }
                    .map { sup.status(of: $0) }
                return APIResponse(ok: true, message: all.isEmpty ? "Nothing running." : "", services: all)
            }
            switch await sup.resolveWorktree(target) {
            case .failure(let msg): return APIResponse(ok: false, message: msg)
            case .success(let wt): return APIResponse(ok: true, message: "", services: sup.entries(for: wt).map { sup.status(of: $0) })
            }

        case ("GET", "/worktrees"):
            await sup.rescan()
            let wts = sup.config.repos.flatMap { sup.worktrees[$0.name] ?? [] }.map(\.info)
            return APIResponse(ok: true, message: "", worktrees: wts, repos: sup.config.repos)

        case ("POST", "/up"), ("POST", "/down"), ("POST", "/restart"):
            guard let r = try? dec.decode(ActionRequest.self, from: req.body) else {
                return APIResponse(ok: false, message: "bad request body")
            }
            return await act(String(req.path.dropFirst()), r)

        case ("POST", "/repos"):
            guard let r = try? dec.decode(AddRepoRequest.self, from: req.body) else {
                return APIResponse(ok: false, message: "bad request body")
            }
            return await sup.addRepo(path: r.path, name: r.name)

        case ("POST", "/reload"):
            await sup.reloadConfig()
            if let err = sup.configError { return APIResponse(ok: false, message: err) }
            return APIResponse(ok: true, message: "Reloaded \(Paths.configFile.path)", repos: sup.config.repos)

        default:
            return APIResponse(ok: false, message: "no route \(req.method) \(req.path)")
        }
    }

    private func act(_ action: String, _ r: ActionRequest) async -> APIResponse {
        let sup = supervisor
        let wt: Worktree
        switch await sup.resolveWorktree(r.target) {
        case .failure(let msg): return APIResponse(ok: false, message: msg)
        case .success(let w): wt = w
        }
        let entries: [Entry]
        switch sup.resolveEntries(wt, r.services) {
        case .failure(let msg): return APIResponse(ok: false, message: msg)
        case .success(let e): entries = e
        }

        var errors: [String] = []
        switch action {
        case "up":
            for e in entries {
                if let err = sup.start(e.key, mode: r.always ? .always : .on, takeover: r.takeover) { errors.append(err) }
            }
        case "down":
            for e in entries { sup.stop(e.key) }
        default:
            for e in entries { await sup.restart(e.key) }
        }

        if !errors.isEmpty {
            return APIResponse(ok: false, message: errors.joined(separator: "\n"), services: entries.map { sup.status(of: $0) })
        }
        if action != "down" && r.wait {
            return await waitForReady(entries)
        }
        if action == "down" {
            for _ in 0..<40 where entries.contains(where: { sup.runtime($0.key).pid != nil }) {
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        return APIResponse(ok: true, message: "\(action) \(wt.id)", services: entries.map { sup.status(of: $0) })
    }

    private func waitForReady(_ entries: [Entry]) async -> APIResponse {
        let sup = supervisor
        let limit = Double(entries.compactMap(\.service.readyTimeout).max() ?? 180) + 5
        let deadline = Date().addingTimeInterval(limit)
        try? await Task.sleep(for: .milliseconds(500))
        while Date() < deadline {
            let states = entries.map { sup.runtime($0.key).status }
            let ready = states.allSatisfy { $0 == .running || $0 == .external }
            let broken = states.contains { [.failed, .blocked, .unhealthy].contains($0) }
                || zip(entries, states).contains { $1 == .crashed && sup.runtime($0.key).mode != .always }
            if ready || broken { break }
            try? await Task.sleep(for: .milliseconds(500))
        }
        let statuses = entries.map { sup.status(of: $0) }
        let ok = statuses.allSatisfy { $0.status == .running || $0.status == .external }
        return APIResponse(ok: ok, message: ok ? "ready" : "not all services became ready", services: statuses)
    }
}

/// Minimal HTTP request parser; returns nil until the full request has arrived.
struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data

    init?(_ data: Data) {
        guard let sep = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: data[..<sep.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = sep.upperBound
        guard data.count - bodyStart >= length else { return nil }
        method = String(requestLine[0])
        path = String(requestLine[1].split(separator: "?").first ?? "")
        self.headers = headers
        body = data.subdata(in: bodyStart..<(bodyStart + length))
    }
}
