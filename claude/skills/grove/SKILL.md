---
name: grove
description: Start, stop, check, or read logs of local dev servers (frontend, backend, worker) for the current worktree. Use whenever you need a dev server running (e.g. to test a UI change in the browser), a server seems down, or you need a localhost URL. Do NOT start dev servers yourself with `pnpm dev` in the background.
---

Dev servers are owned by the Grove menu bar app, which keeps them alive across sessions. Control them with `grove`. It infers the worktree from your current directory.

- `grove status`: what's running here, with URLs.
- `grove up [svc...]`: start services and **block until they're listening**. If you give no service, all of the repo's services start. Exit code 0 means ready. On failure it prints the tail of the log.
- `grove up fe --takeover`: needed when another worktree already holds the port (Troupe's be/fe use fixed ports 3000/3001). Only use it when the user wants *this* worktree served, because it stops the other one.
- `grove logs <svc> -n 100`: read server output. Use this instead of tailing processes.
- `grove restart <svc>`, `grove down <svc>`.
- `grove url <svc>`: print the service's URL.
- Add `--json` for machine-readable output.

Rules:
- Never run `pnpm dev*` / `next dev` directly or as a background task. Use `grove up` so the server outlives your session.
- Don't pass `--always` unless the user asks for a server to stay up permanently.
- If `grove` reports the worktree isn't watched, tell the user. Offer `grove repo add <repo-root>`.
