# agentbox

One Docker Compose sandbox per coding agent, for any project.

Agents run with permissions skipped, so the blast radius has to be a throwaway container rather than your user
account. Each agent gets its own checkout, home, database and running copy of the app, on its own hostname and
ports, with a bot identity for `git` and `gh` and a log of every hostname it reached.

The harness knows about agents. The project knows about itself: its image, services, volumes and databases, and
how to install, migrate and run. Your settings stay in your home directory. Nothing here names a language, a
framework, a database or a company.

## Quick start

```bash
ln -s <this repo>/bin/agentbox ~/.local/bin/agentbox
agentbox init                 # writes ~/.config/agentbox/env
cd <a project with an .agentbox/ folder>
agentbox build                # 10-20 min the first time
agentbox setup                # only if the project ships a setup script
agentbox up 1
agentbox sh 1
```

The CLI finds the project by walking up to the first `.agentbox/project.env`, or takes `-C <repo>`.

## Commands

```
agentbox init                   write ~/.config/agentbox/env from env.example
agentbox build [docker args]    build agentbox-<project> from <repo>/.agentbox/Dockerfile
agentbox setup [args]           run the project's own .agentbox/setup, when it ships one
agentbox up N                   start agent N: compose up, hosts entry, net-log, bootstrap. Idempotent.
agentbox sh N                   shell into agent N, with your TERM and COLORTERM
agentbox down N                 stop, keep volumes
agentbox destroy N              stop and remove every volume named <project>-agent-N-*
agentbox ps                     list this project's agents
agentbox url N                  print this agent's URLs
agentbox open N [PORT_NAME]     open one in your browser
agentbox get N [file]           copy agent N's outbox to ./tmp/agentbox/agent-N/
agentbox review N [diff args]   review agent N's uncommitted changes in your browser (revue open --reuse)
agentbox reviews N [ID]         list agent N's reviews, or open review ID in your browser
agentbox compose N [args]       docker compose for agent N: `compose 1 logs db`, `compose 1 config`
```

`up` recreates changed containers, reuses every volume, re-runs the bootstraps, and removes the containers of
one-shot services that ran to completion. Names: compose project `<project>-agent-N`, volumes
`<project>-agent-N-*`, image `agentbox-<project>`.

## Three layers

| Layer | Lives in | Contains |
| --- | --- | --- |
| Harness | this repo | `bin/agentbox`, `compose.base.yml`, `image/`, `runtime/bootstrap`, `env.example` |
| Project | `<repo>/.agentbox/` | `project.env`, `Dockerfile`, `compose.yml`, `bootstrap`, `app`, `AGENT.md`, optional `setup` and `.env` |
| Personal | `~/.config/agentbox/` | `env`, `home/`, `secrets/<project>/` |

Three stock Docker features glue them together, no templating:

- **Compose overlay files.** `up` runs `docker compose --project-directory <repo>/.agentbox -f <harness>/compose.base.yml -f <repo>/.agentbox/compose.yml`.
  Single values in the overlay replace the base, `ports` concatenate, `environment` and `volumes` merge by key.
- **Named build context.** `build` passes `--build-context agentbox=<harness>/image`, and the project Dockerfile
  pulls the generic layer in with one `RUN --mount=type=bind,from=agentbox` line.
- **Runtime mount.** `<harness>/runtime` is mounted at `/agentbox`, so editing the harness bootstrap needs no
  rebuild. The project's `bootstrap` and `app` are baked into the image, so editing those needs `agentbox build`.

## Project contract

### `project.env`

```sh
PROJECT=myapp                                    # image agentbox-myapp, volumes myapp-agent-N-*
REPO_URL=https://github.com/me/myapp.git
# REPO_BRANCH=main
PORTS="APP_PORT=3N00 DEV_PORT=3N36 DB_PORT=3N32 OUT_PORT=3N90"
```

Each entry in `PORTS` becomes a variable for compose interpolation with `N` replaced by the agent number, so
agent 2 gets `APP_PORT=3200`. Two names are recognised by the harness. `OUT_PORT`: publish it and the agent's
outbox is served there. `REVUE_PORT`: publish it and the agent's revue code-review server binds it, with
`http://agentN.localhost:<port>` as the URL your browser uses. `agentbox review N` reviews the box's uncommitted
changes there, idempotently; `agentbox reviews N` lists what the agent opened.

### `Dockerfile`

Any Debian bookworm based image. The tail is fixed:

```dockerfile
FROM <any debian bookworm based image>
RUN <the project's language runtime, toolchain and system packages>
RUN --mount=type=bind,from=agentbox,target=/agentbox /agentbox/install.sh
COPY --chmod=755 app /usr/local/bin/app
COPY --chmod=755 bootstrap /usr/local/bin/agentbox-project-bootstrap
USER agent
WORKDIR /workspace
CMD ["sleep", "infinity"]
```

`install.sh` adds user `agent` (uid 1000), Claude Code, Playwright MCP with Chromium and WebKit, `gh`, zsh, tmux,
lazygit, delta, revue (latest release), dnsmasq, socat, the `net-log`, `gh`, `pbcopy` and `open` shims, and the git credential helper for
`/run/secrets/gh-token`. Any directory the project mounts a volume on must exist in the image and belong to
`agent`: Docker copies a mount point's ownership into an empty volume on first mount, which is all the ownership
handling there is.

### `compose.yml`

An overlay. The base defines the `agent` service and its `src` and `home` volumes; the overlay adds services,
wires networking, publishes ports and declares every other volume.

```yaml
services:
  db-init:
    image: alpine:3.21
    volumes: [seed:/from:ro, data:/to]
    command: sh -c '[ -n "$$(ls -A /to)" ] || cp -a /from/. /to/'
  db:
    image: <a database image>
    depends_on: { db-init: { condition: service_completed_successfully } }
    volumes: [data:<the image's data directory>]
    ports: ["${APP_PORT}:${APP_PORT}", "${DEV_PORT}:${DEV_PORT}", "${DB_PORT}:5432"]
  agent:
    network_mode: "service:db"
    environment:
      PORT: ${APP_PORT}
      APP_DOMAIN: ${AGENT_HOST}:${APP_PORT}
volumes:
  data: { name: "${PROJECT}-agent-${AGENT}-data" }
  seed: { name: "${PROJECT}-seed", external: true }
```

Four things there are worth copying:

- **`network_mode: "service:db"`** puts a service in another's network namespace, which makes a hardcoded
  `127.0.0.1` valid for everything and gives each agent its own ports. A service that joins a namespace cannot
  publish ports, so one service publishes the whole block. It also rules out `extra_hosts`, which is why `up`
  writes the agent's hostname into `/etc/hosts`.
- **The one-shot `db-init`** clones a prepared volume into this agent's empty one in seconds, and does nothing on
  later runs. Compose keeps such a container stopped because its exit status is what the dependency reads; `up`
  removes it once everything is running.
- **Per-agent volumes** carry the `${PROJECT}-agent-${AGENT}-` prefix, which is what `destroy` matches. Anything
  shared is `external: true`, created outside Compose, so no agent claims or removes it.
- **An image's own `VOLUME`** needs a `tmpfs` when you do not mount it, or every recreate leaves an anonymous
  volume behind.

### `bootstrap`, `app`, `setup`, `AGENT.md`, `.env`

`bootstrap` is idempotent and runs as `agent` in `/workspace` on every `up`, after the clone; the host checkout is
at `/host-repo` read-only for copying untracked env files. `app` is copied to `/usr/local/bin/app` with the
convention `start | stop | status | logs [name] | url`. `setup` runs on the host to prepare shared volumes once.
`AGENT.md` is the brief agents read, imported automatically. `.env` holds gitignored secrets the overlay needs and
is passed with `--env-file`.

## Personal settings

```
~/.config/agentbox/
  env                    BOT_NAME, BOT_EMAIL, AGENT_SHELL, NET_LOG, all optional
  home/                  overlaid onto every agent's home
  secrets/<project>/     mounted read-only at /run/secrets, falling back to secrets/
```

`home/` is mounted read-only at `/agent-home` and overlaid onto `/home/agent` on every `up`: directories are
merged so per-agent state such as `.claude/projects` stays local, files are linked so they follow your edits live
and the agent cannot alter them. Secrets are per project because the identity they carry is: a GitHub App belongs
to one repo.

## What an agent gets

- `/workspace` cloned from the host checkout, a persistent `$HOME`, and the project's services
- hostname `agentN.localhost` and the ports from `PORTS`, identical inside and outside
- `~/AGENTBOX.md`, written per agent, saying where it is and how to hand work back, importing the project's
  `AGENT.md`
- `~/out`, its outbox, served at `http://agentN.localhost:<OUT_PORT>/` and pulled with `agentbox get`
- `revue`, when the project publishes `REVUE_PORT`: the agent opens a review of its diff and hands you the link,
  you comment at `http://agentN.localhost:<REVUE_PORT>/`, and it reads your feedback with the CLI. The protocol is
  in `~/AGENTBOX.md`. From here, `agentbox review N` reviews the box's uncommitted changes and `agentbox reviews N`
  lists or opens existing reviews
- Claude Code with your config, no permission prompts, the workspace pre-trusted
- `pbcopy` and `open`, which reach your clipboard and your browser through terminal escape sequences, over ssh too
- `net-log hosts`, every hostname it reached

## Troubleshooting

| Symptom | Cause |
| --- | --- |
| `no .agentbox/project.env found above …` | Not inside a project checkout. Use `-C <repo>`. |
| `external volume "…" not found` | The project's `setup` has not run. |
| A change to the project `bootstrap` or `app` has no effect | They are baked in: `agentbox build`, then `up`. |
| Want to see what Compose actually runs | `agentbox compose N config` |
