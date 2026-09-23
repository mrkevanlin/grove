import GroveCore
import Foundation

struct Worktree: Identifiable, Hashable {
    let repo: String
    /// Short, stable name: "main" for the primary checkout, otherwise the directory name.
    let name: String
    let path: String
    let branch: String?
    let isMain: Bool

    var id: String { "\(repo)/\(name)" }
    var info: WorktreeInfo { WorktreeInfo(repo: repo, name: name, path: path, branch: branch) }
}

enum WorktreeScanner {
    /// Runs `git worktree list --porcelain` for a repo. Call off the main thread.
    static func scan(_ repo: RepoConfig) -> [Worktree] {
        let root = repo.expandedPath
        let out = Sys.run("/usr/bin/git", ["-C", root, "worktree", "list", "--porcelain"], timeout: 10)
        var result: [Worktree] = []
        var usedNames = Set<String>()
        for block in out.components(separatedBy: "\n\n") {
            var path: String?
            var branch: String?
            var skip = false
            for line in block.split(separator: "\n") {
                if line.hasPrefix("worktree ") { path = String(line.dropFirst(9)) }
                else if line.hasPrefix("branch ") { branch = String(line.dropFirst(7)).replacingOccurrences(of: "refs/heads/", with: "") }
                else if line == "bare" || line.hasPrefix("prunable") { skip = true }
            }
            guard let path, !skip, FileManager.default.fileExists(atPath: path) else { continue }
            let isMain = result.isEmpty // git always lists the main worktree first
            var name = isMain ? "main" : (path as NSString).lastPathComponent
            if usedNames.contains(name) { name += "-\(usedNames.count)" }
            usedNames.insert(name)
            result.append(Worktree(repo: repo.name, name: name, path: path, branch: branch, isMain: isMain))
        }
        if result.isEmpty, FileManager.default.fileExists(atPath: root) {
            // Not a git repo (or git failed): treat the folder itself as the only "worktree".
            result.append(Worktree(repo: repo.name, name: "main", path: root, branch: nil, isMain: true))
        }
        return result
    }
}

/// Lets resolution helpers return `Result<_, String>` with a user-facing message.
extension String: @retroactive Error {}
