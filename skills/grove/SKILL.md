---
name: grove
description: Start, stop, check, or read logs of local dev servers (frontend, backend, worker) for the current worktree via the Grove menu bar app. Use whenever you need a dev server running (e.g. to test a UI change in the browser), a server seems down, or you need a localhost URL. Applies in Claude Code, Cursor, and ChatGPT.
---

Grove is a menu bar app that owns dev servers so they outlive agent sessions. Control it with the `grove` CLI. It works out the worktree from your current directory.

## First, check that Grove applies here

Run `grove status` from the worktree.

- **`command not found`, or exit code 3 (app not reachable):** Grove isn't installed or isn't running on this machine. Ignore this skill and start servers however you normally would.
- **Exit code 4 ("isn't inside a watched worktree"):** this repo isn't managed by Grove. Ignore this skill and use the repo's normal dev commands. Don't nag the user about it. At most, mention once that `grove repo add <repo-root>` would bring it under Grove.
- **Exit code 0 with a table of services:** Grove manages this repo. Use the commands below and **don't** run `pnpm dev*` / `npm run dev` / `next dev` yourself, in the foreground or as a background task.

## Commands

- `grove status`: what's running here, with URLs.
- `grove up [svc...]`: start services and **block until they're listening**. If you give no service, all of the repo's services start. Exit code 0 means ready. On failure it prints the tail of the log.
- `grove up fe --takeover`: needed when another worktree already holds the port. Only use it when the user wants *this* worktree served, because it stops the other one.
- `grove logs <svc> -n 100`: read server output. Use this instead of tailing processes.
- `grove restart <svc>`, `grove down <svc>`.
- `grove url <svc>`: print the service's URL.
- Add `--json` for machine-readable output.

## Rules

- Don't pass `--always` unless the user asks for a server to stay up permanently.
- Don't `grove down` servers you didn't start unless the user asks. Another session may be using them.
- A service shown as `external` is running but was started outside Grove. It still works; don't restart it just to bring it under Grove.
