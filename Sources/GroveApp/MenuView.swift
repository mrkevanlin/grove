import AppKit
import GroveCore
import SwiftUI

struct MenuView: View {
    @EnvironmentObject var sup: Supervisor
    @State private var query = ""
    @State private var showAllRepos: Set<String> = []
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var contentHeight: CGFloat = 200

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let err = sup.configError {
                        Label(err, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange).font(.caption)
                    }
                    ForEach(sup.config.repos, id: \.name) { repo in
                        repoSection(repo)
                    }
                }
                .padding(12)
                .background(GeometryReader { geo in
                    Color.clear.preference(key: ContentHeightKey.self, value: geo.size.height)
                })
            }
            // A ScrollView has no intrinsic height, so inside a MenuBarExtra window it collapses to 0.
            // Size it to its content, capped so long lists scroll.
            .frame(height: min(contentHeight, 560))
            .onPreferenceChange(ContentHeightKey.self) { contentHeight = $0 }
            Divider()
            footer
        }
        .frame(width: 400)
        .task { await sup.rescan() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Grove").font(.headline)
            Spacer()
            TextField("Filter worktrees", text: $query)
                .textFieldStyle(.roundedBorder)
                .frame(width: 170)
            Button { Task { await sup.reloadConfig() } } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .help("Reload config & rescan worktrees")
        }
        .padding(12)
    }

    @ViewBuilder
    private func repoSection(_ repo: RepoConfig) -> some View {
        let all = sup.worktrees[repo.name] ?? []
        let filtered = query.isEmpty ? all : all.filter {
            $0.name.localizedCaseInsensitiveContains(query) || ($0.branch ?? "").localizedCaseInsensitiveContains(query)
        }
        let pinned = filtered.filter { $0.isMain || sup.isActive($0) }
        let rest = filtered.filter { !($0.isMain || sup.isActive($0)) }
        let expanded = showAllRepos.contains(repo.name) || !query.isEmpty

        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(repo.name.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text("\(all.count) worktree\(all.count == 1 ? "" : "s")").font(.caption).foregroundStyle(.tertiary)
                Spacer()
            }
            if all.isEmpty {
                Text("No worktrees found at \(repo.path)").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(pinned) { WorktreeCard(worktree: $0) }
            if !rest.isEmpty {
                if expanded {
                    ForEach(rest) { WorktreeCard(worktree: $0) }
                }
                if query.isEmpty {
                    Button(expanded ? "Hide idle worktrees" : "Show \(rest.count) idle worktree\(rest.count == 1 ? "" : "s")") {
                        if expanded { showAllRepos.remove(repo.name) } else { showAllRepos.insert(repo.name) }
                    }
                    .buttonStyle(.link).font(.caption)
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Text(sup.apiState).font(.caption2).foregroundStyle(.tertiary)
            Spacer()
            Menu {
                Button("Add repo…") { addRepo() }
                Button("Edit config…") { NSWorkspace.shared.open(Paths.configFile) }
                Button("Open logs folder") {
                    try? FileManager.default.createDirectory(at: Paths.logsDir, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(Paths.logsDir)
                }
                Divider()
                Toggle("Launch at login", isOn: $launchAtLogin) // shown as a checkmark item
                Divider()
                Button("Quit (stops all servers)") { NSApp.terminate(nil) }
            } label: { Image(systemName: "gearshape") }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .onChange(of: launchAtLogin) { _, on in
                if on != LaunchAtLogin.isEnabled { LaunchAtLogin.set(on) }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .onAppear { launchAtLogin = LaunchAtLogin.isEnabled }
    }

    private func addRepo() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Watch repo"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            let res = await sup.addRepo(path: url.path, name: nil)
            Sys.notify("Grove", res.message)
        }
    }
}

private struct ContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct WorktreeCard: View {
    @EnvironmentObject var sup: Supervisor
    let worktree: Worktree

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(worktree.name).font(.system(.body, weight: .medium)).lineLimit(1).truncationMode(.middle)
                if let b = worktree.branch, b != worktree.name {
                    Text(b).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Button { NSWorkspace.shared.open(URL(fileURLWithPath: worktree.path)) } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.borderless).help(worktree.path)
            }
            if let sessions = sup.claudeSessions[worktree.id], let latest = sessions.first {
                ClaudeSessionLink(latest: latest, others: Array(sessions.dropFirst()))
            }
            ForEach(sup.entries(for: worktree), id: \.key) { ServiceRow(entry: $0) }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
    }
}

/// Opens the worktree's Claude Code session in the Claude desktop app.
struct ClaudeSessionLink: View {
    let latest: ClaudeSession
    let others: [ClaudeSession]

    var body: some View {
        HStack(spacing: 4) {
            Button { NSWorkspace.shared.open(latest.url) } label: {
                Label {
                    Text(latest.title).lineLimit(1).truncationMode(.tail)
                } icon: {
                    Image(systemName: "bubble.left.and.text.bubble.right")
                }
                .font(.caption)
            }
            .buttonStyle(.link)
            .help("Open this session in Claude")
            if !others.isEmpty {
                Menu {
                    ForEach(others) { s in
                        Button(s.title) { NSWorkspace.shared.open(s.url) }
                    }
                } label: {
                    Text(verbatim: "+\(others.count)").font(.caption)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("Other sessions in this worktree")
            }
        }
    }
}

struct ServiceRow: View {
    @EnvironmentObject var sup: Supervisor
    let entry: Entry

    var body: some View {
        let rt = sup.runtime(entry.key)
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Circle().fill(color(rt.status)).frame(width: 8, height: 8)
                    .help(rt.status.rawValue)
                Text(entry.service.name).font(.system(.callout, design: .monospaced))
                if let port = entry.service.port {
                    Button { NSWorkspace.shared.open(URL(string: "http://localhost:\(port)")!) } label: {
                        Text(verbatim: ":\(port)") // verbatim: no locale grouping ("3,000")
                    }
                        .buttonStyle(.link).font(.caption)
                        .disabled(!(rt.status == .running || rt.status == .external))
                }
                Spacer()
                // ∞ = always on (auto-restart). Tapping it while off starts the service in always-on mode.
                Button {
                    sup.start(entry.key, mode: rt.mode == .always ? .on : .always, takeover: true)
                } label: {
                    Image(systemName: "infinity")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(rt.mode == .always ? Color.purple : Color.secondary.opacity(0.5))
                        .frame(width: 24, height: 20)
                        .background(RoundedRectangle(cornerRadius: 5)
                            .fill(rt.mode == .always ? Color.purple.opacity(0.18) : .clear))
                }
                .buttonStyle(.plain)
                .help(rt.mode == .always ? "Always on — auto-restarts. Click to stop auto-restarting." : "Keep always on (auto-restart on crash)")
                Toggle("", isOn: Binding(
                    get: { rt.mode != .off },
                    set: { on in
                        if on { sup.start(entry.key, mode: .on, takeover: true) } else { sup.stop(entry.key) }
                    }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .help(rt.mode == .off ? "Start" : "Stop")
                Menu {
                    Button("Restart") { Task { await sup.restart(entry.key) } }
                    Button("Open log") { openLog() }
                    Button("Copy grove command") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("grove up \(entry.service.name) -w \(entry.worktree.id)", forType: .string)
                    }
                } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
            if let msg = rt.message {
                Text(msg).font(.caption2).foregroundStyle(.secondary).lineLimit(2).padding(.leading, 16)
            }
        }
    }

    private func openLog() {
        let url = Paths.logFile(repo: entry.repo.name, worktree: entry.worktree.name, service: entry.service.name)
        if FileManager.default.fileExists(atPath: url.path) { NSWorkspace.shared.open(url) }
    }

    private func color(_ s: RunStatus) -> Color {
        switch s {
        case .running: return .green
        case .external: return .blue
        case .starting: return .yellow
        case .unhealthy: return .orange
        case .crashed, .failed: return .red
        case .blocked: return .purple
        case .stopped: return .gray.opacity(0.5)
        }
    }
}
