#!/usr/bin/env bash
# agentbox generic image layer. A project Dockerfile runs it as root, on a Debian bookworm based image:
#   RUN --mount=type=bind,from=agentbox,target=/agentbox /agentbox/install.sh
# It installs: user `agent` (uid 1000) with /workspace, Node (only when the image has none), Claude Code,
# Playwright MCP with Chromium and WebKit under /opt/ms-playwright, gh, lazygit, delta, revue, tmux, dnsmasq, socat,
# the net-log and gh scripts, git and sudo settings for the bot identity. The harness bootstrap is not baked in:
# compose mounts <harness>/runtime at /agentbox and `agentbox up` runs it from there.
# Build ARGs it honours when declared before the RUN line: PLAYWRIGHT_MCP_VERSION (default latest), NODE_VERSION,
# REVUE_VERSION (default latest; a pin also rebuilds this layer, which is how a newer latest gets picked up).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
: "${PLAYWRIGHT_MCP_VERSION:=latest}"
: "${REVUE_VERSION:=latest}"
: "${NODE_VERSION:=24.15.0}"
: "${LAZYGIT_VERSION:=0.65.1}"
: "${DELTA_VERSION:=0.19.2}"
: "${ZSH_SYNTAX_HIGHLIGHTING_VERSION:=0.8.0}"
export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y --no-install-recommends \
  curl ca-certificates gnupg git jq less vim tmux procps sudo xz-utils \
  dnsmasq socat iproute2 zsh
curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /usr/share/keyrings/githubcli-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
  > /etc/apt/sources.list.d/github-cli.list
apt-get update
apt-get install -y --no-install-recommends gh

arch="$(dpkg --print-architecture)"
case "$arch" in
  amd64) lazygit_arch=x86_64; delta_arch=x86_64-unknown-linux-gnu ;;
  arm64) lazygit_arch=arm64;  delta_arch=aarch64-unknown-linux-gnu ;;
  *) echo "unsupported arch $arch" >&2; exit 1 ;;
esac
curl -fsSL "https://github.com/jesseduffield/lazygit/releases/download/v${LAZYGIT_VERSION}/lazygit_${LAZYGIT_VERSION}_linux_${lazygit_arch}.tar.gz" \
  | tar -xz -C /usr/local/bin lazygit
curl -fsSL "https://github.com/dandavison/delta/releases/download/${DELTA_VERSION}/delta-${DELTA_VERSION}-${delta_arch}.tar.gz" \
  | tar -xz -C /tmp
install -m 755 "/tmp/delta-${DELTA_VERSION}-${delta_arch}/delta" /usr/local/bin/delta
rm -rf "/tmp/delta-${DELTA_VERSION}-${delta_arch}"
# revue: the human reviews agent diffs in it, the agent reads the feedback with its CLI.
case "$REVUE_VERSION" in
  latest) revue_url="https://github.com/rphf/revue/releases/latest/download/revue_linux_${arch}.tar.gz" ;;
  *)      revue_url="https://github.com/rphf/revue/releases/download/v${REVUE_VERSION}/revue_linux_${arch}.tar.gz" ;;
esac
curl -fsSL "$revue_url" | tar -xz -C /usr/local/bin revue

if ! command -v node >/dev/null; then
  arch="$(dpkg --print-architecture)"
  case "$arch" in amd64) narch=x64 ;; arm64) narch=arm64 ;; *) echo "unsupported arch $arch" >&2; exit 1 ;; esac
  curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-${narch}.tar.xz" \
    | tar -xJ -C /usr/local --strip-components=1 --no-same-owner
fi

# Claude Code + Playwright MCP, global. Browsers go to a shared path; compose.base.yml sets
# PLAYWRIGHT_BROWSERS_PATH to the same value so every user in the container finds them.
export PLAYWRIGHT_BROWSERS_PATH=/opt/ms-playwright
npm install -g @anthropic-ai/claude-code "@playwright/mcp@${PLAYWRIGHT_MCP_VERSION}"
npm cache clean --force
pw_dir="$(find "$(npm root -g)" -type d \( -path '*/node_modules/playwright' -o -path '*/node_modules/playwright-core' \) | head -1)"
test -n "$pw_dir"
node "$pw_dir/cli.js" install --with-deps chromium webkit
chmod -R a+rX /opt/ms-playwright
rm -rf /var/lib/apt/lists/*

# git: bot token from the mounted secret (agentbox mounts it at /run/secrets), any checkout owner, main by default.
git config --system credential.https://github.com.helper \
  '!f(){ [ "$1" = get ] || return 0; [ -r /run/secrets/gh-token ] || return 0; printf "username=x-access-token\npassword=%s\n" "$(cat /run/secrets/gh-token)"; }; f'
git config --system --add safe.directory '*'
git config --system init.defaultBranch main

# Non-root user, uid 1000 to match the volume chown done by `agentbox up`; may only sudo net-log.
if existing="$(getent passwd 1000 | cut -d: -f1)" && [ -n "$existing" ] && [ "$existing" != agent ]; then
  echo "uid 1000 is already taken by '$existing' in the base image" >&2; exit 1
fi
id agent >/dev/null 2>&1 || useradd -m -u 1000 -s /bin/bash agent
echo "agent ALL=(root) NOPASSWD: /usr/local/bin/net-log" > /etc/sudoers.d/agent
chmod 0440 /etc/sudoers.d/agent
mkdir -p /workspace && chown agent:agent /workspace

git clone --quiet --depth 1 --branch "$ZSH_SYNTAX_HIGHLIGHTING_VERSION" \
  https://github.com/zsh-users/zsh-syntax-highlighting.git /usr/share/zsh-syntax-highlighting
rm -rf /usr/share/zsh-syntax-highlighting/.git

install -m 755 "$HERE/gh" /usr/local/bin/gh
install -m 755 "$HERE/pbcopy" /usr/local/bin/pbcopy
install -m 755 "$HERE/open" /usr/local/bin/open
ln -sf /usr/local/bin/pbcopy /usr/local/bin/clip
ln -sf /usr/local/bin/open /usr/local/bin/xdg-open
install -m 755 "$HERE/net-log" /usr/local/bin/net-log
