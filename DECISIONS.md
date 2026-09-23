# Why agentbox looks like this

The README is the contract. This file explains the parts whose reason is not obvious from the code, so nobody
"simplifies" them back into bugs. Built 2026-09-11 to 2026-09-18, extracted from a prototype that lived inside
the first project's repository.

## Shape

- **A container per agent, not a worktree.** Agents run with `--dangerously-skip-permissions`. The isolation has
  to be the container, not a Unix user.
- **Three layers, glued by stock Docker.** Compose overlay files and a named build context, no templating and no
  config parser. A project that needs more than the contract's files should get one generic hook, not a plugin API.
- **The CLI owns no volume, no database, no seed.** Those are project concerns and live in the project's
  `compose.yml` and its own `setup` script. The CLI does what only it can: per-agent names and ports, the
  `/etc/hosts` entry, `net-log`, the bootstrap.
- **The harness bootstrap is mounted, not baked.** A bootstrap change shipped in the image is invisible until the
  next build; that bit us once, silently, when the home overlay moved.

## Runtime details with a reason

- **One hostname per agent** (`agentN.localhost`): browsers scope cookies by host, not port, so two agents on
  `localhost` would share a session cookie with each other and with your own app on `:3000`. Browsers resolve
  `*.localhost` to 127.0.0.1 themselves; `up` adds the same entry to the container's `/etc/hosts` because
  `extra_hosts` is refused together with `network_mode: service:*`.
- **Ports identical inside and outside**, so URLs the frontend embeds work from the browser, from the agent and
  from its Playwright alike.
- **Home overlay links files, merges directories.** Merging keeps per-agent state (`.claude/projects`, the login
  credentials) next to your config; linking means the agent cannot edit your config and picks changes up live.
- **Empty volumes inherit the image's ownership.** Docker copies a mount point's content and ownership into a new
  volume on first mount, so the project Dockerfile chowning its mount points removes every `chown` step elsewhere.
- **Shared volumes are `external: true`.** A Compose-managed shared volume gets the label of whichever agent
  created it, and every other agent then warns about it. External volumes are exempt.
- **Redis gets `tmpfs: [/data]`.** Its image declares `VOLUME /data`; without this, each container recreate leaves
  an anonymous volume behind.
- **The container serves, the host pulls.** An agent hands files over by writing to `~/out`, which is served over
  HTTP and pulled with `agentbox get`. A writable host mount would have been simpler and would have handed the
  sandbox the one thing it exists to prevent.
- **Every agent is told where it is.** `~/AGENTBOX.md` is generated per agent and chains to the project's
  `.agentbox/AGENT.md`, so no session spends its first tool calls working out which ports the app uses.
- **The terminal comes to the sandbox, not the reverse.** `sh` forwards `TERM`, `COLORTERM` and `TERM_PROGRAM`
  (Claude Code enables Shift+Enter and the rest of its keyboard protocol only for a terminal it recognises), and
  `pbcopy` and `open` are escape sequences the terminal interprets. Every one of them keeps working through ssh to a remote
  host, and none of them gives the container a channel to the machine you are sitting at.
- **The clipboard only crosses when you push it.** `xclip` in the box keeps its own clipboard, and text copied
  into it goes out as OSC 52, which a terminal can only write. Nothing reads yours: an image comes in when your
  terminal's Ctrl+V binding runs `agentbox clip N` for the pane you are typing in, and never text. Reading the host
  clipboard on demand, by OSC 52 or a daemon, would hand the agent whatever you copied last, passwords included.
  The binding lives in the terminal, not in a pty relay inside `agentbox sh`, so nothing sits between you and the
  box; the price is one binding per terminal, and the harness ships WezTerm's (`host/wezterm.lua`).
- **No interactive gates inside the box.** First-run trust and permission dialogs are pre-answered and the
  permission mode is `bypassPermissions`. A prompt an unattended agent cannot answer is a hang, and the container
  already is the boundary those prompts exist to protect.
- **Agents reach the whole internet.** No firewall, like local agents today. Every resolved hostname is logged
  instead (`NET_LOG`, `net-log hosts`). Hostnames only: HTTPS hides paths, and a connection straight to an IP is
  not seen.
- **Claude Code is the only agent CLI in the image.** Playwright ships Chromium and WebKit.

- **One directory for anything personal**, at fixed paths. `~/.config/agentbox/` holds the settings, the home
  overlay and the tokens. Making the paths configurable bought nothing and cost a settings key each.
- **Secrets are per project.** A GitHub App belongs to one repository, so its token lives in
  `secrets/<project>/` rather than in a single shared directory that the second project would fight over.

## Not doing

No templating, no YAML config parser, no published base image, no plugin API, no multi-user features.

## Alternatives considered

- **Devcontainers.** The spec targets one editor attached to one container whose workspace is a bind mount of the
  opened folder, which fights N sandboxes with their own clone, database and app. If you ever want to open an
  agent's checkout in an IDE, `.agentbox/` can carry a `devcontainer.json` that attaches to the running compose
  service (`dockerComposeFile` + `service`), which is a ten-line addition, not a foundation.
- **Coder** (self-hosted): a control plane plus Terraform templates would replace the CLI and the compose files,
  not the hard parts inside the container, and brings its own Postgres and control plane. Worth revisiting when
  several people share one box. Its "Coder Tasks" is deprecated since v2.37 in favour of "Coder Agents".
- **Hosted agent platforms** (Cursor Cloud Agents, Claude Code on the web, Codex cloud, Copilot coding agent):
  each locks you to one vendor's agent and rebuilds or short-caches the environment, so none of them can host a
  sandbox that keeps a restored database and a warm checkout between sessions.
- **Vibe Kanban**: company shut down April 2026, local edition community-maintained. Not a pillar.

## Not exercised yet

More than one project. A Linux host. System specs inside a sandbox.
