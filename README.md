# Grove

A macOS menu bar app that watches the git worktrees of your repos and runs their dev servers. Each service has an on/off switch and an **∞** button; with ∞ on, the service restarts automatically when it crashes or stops responding. Each worktree also links to its Claude Code session in the Claude desktop app.

Grove comes with `grove`, a CLI that agents use to start servers or check on them. That way Claude Code, Cursor, and ChatGPT don't spawn servers of their own, which die when the session ends.

## Requirements

- macOS 14 or later
- A Swift 5.10+ toolchain: Xcode, or the Command Line Tools (`xcode-select --install`)
- `~/.local/bin` on your `PATH`, for the `grove` CLI

## Install

```bash
git clone https://github.com/mrkevanlin/grove.git ~/Dev/grove
~/Dev/grove/scripts/install.sh
```

This builds `~/Applications/Grove.app`, links `grove` into `~/.local/bin`, links the agent skill for Claude Code, Cursor, and ChatGPT, and launches the app. The icon then appears in your menu bar. To have Grove start when you log in, check **⚙ → Launch at login**.

Run `scripts/install.sh` again after pulling changes.

**First run:** if `~/.config/grove/config.json` does not exist yet, Grove writes an empty config. Add a repo with `grove repo add ~/Dev/your-repo`, or via **⚙ → Add repo…**. An existing config file is left as it is.

## Config: `~/.config/grove/config.json`

```json
{
  "apiPort": 7787,
  "repos": [
    {
      "name": "my-app",
      "path": "~/Dev/my-app",
      "services": [
        { "name": "be",     "command": "pnpm dev:be",     "port": 3000 },
        { "name": "fe",     "command": "pnpm dev:fe",     "port": 3001 },
        { "name": "worker", "command": "pnpm dev:worker" }
      ]
    }
  ]
}
```

- Every worktree of a repo (`git worktree list`) gets that repo's services.
- `port` is used for health checks, URLs and port-conflict handling. Services without a port count as healthy while their process is alive.
- You can also set `env` (extra environment variables) and `readyTimeout` (seconds to wait for the port to open, default 180) per service.
- You can add a repo in three ways:
  - `grove repo add ~/Dev/other-repo`, which detects `dev`/`dev:*` scripts in `package.json`
  - **⚙ → Add repo…** in the menu
  - editing the file directly, then running `grove reload`

## grove

```text
grove status                    # this worktree (inferred from cwd), or everything active
grove up [svc...] [--always]    # start and wait until the port answers
grove up fe --takeover          # stop whichever worktree holds :3001 and serve this one
grove down [svc...]
grove restart [svc...]
grove logs fe -n 100 [-f]
grove url fe
grove ls                        # repos and worktrees
```

`-w <worktree>` targets another worktree. It accepts `repo/main`, a worktree folder name, a branch name, or a path.

## How it works

- **Processes**: each service runs as `/bin/zsh -c "<command>"` in its own process group, with the environment of your interactive login shell (so nvm, pnpm and similar tools are on PATH). Stopping a service kills the whole group.
- **Health**: a check every 3s. It watches for the process exiting and tests whether the port is answering. An always-on service whose port stops answering for 45s is restarted; this catches `tsx watch` sitting idle after a crash.
- **Crash loops**: restarts wait 1s, 2s, 4s… up to 30s. After 5 crashes in 3 minutes the app gives up and sends a notification.
- **Servers started elsewhere**: a server started from a terminal or by an agent is detected through its listening port and working directory. It shows up as **external** (blue) and can still be stopped. Stopping it does not quit Claude, Cursor, or ChatGPT.
- **Logs**: `~/Library/Logs/Grove/<repo>/<worktree>/<service>.log`. Each log rotates at 5 MB.
- **API**: HTTP on `127.0.0.1:<apiPort>`. Every request must include the header `X-Grove: 1`, and requests carrying an `Origin` header are rejected, so browser pages can't drive it.
- **Quitting the app** stops every server it manages. Always-on services start again the next time the app launches. Reinstalling with `scripts/install.sh` is different: it brings back everything that was running.
- **Claude sessions**: Grove reads the Claude desktop app's session files (`~/Library/Application Support/Claude/claude-code-sessions`) and matches each session to a worktree by its folder. Clicking the link opens `claude://code/continue?session=<id>`. Neither the files nor the link format is documented, so this can break when Claude updates. If it does, the links just stop appearing.

## Agents

`skills/grove/SKILL.md` teaches Claude Code, Cursor, and ChatGPT to use `grove` instead of running `pnpm dev` themselves. `scripts/install.sh` links that directory into the user skill folders those tools scan:

| Tool | Link |
| --- | --- |
| Claude Code | `~/.claude/skills/grove` |
| Cursor | `~/.cursor/skills/grove` |
| ChatGPT and Codex | `~/.agents/skills/grove` and `~/.codex/skills/grove` |

Because they are symlinks, `git pull` keeps them up to date. The skill only takes effect in repos Grove watches. Elsewhere, or if the app isn't running, the agent carries on as usual.
