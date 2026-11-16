#!/usr/bin/env bash
# agentbox generic image layer. A project Dockerfile runs it as root, on a Debian bookworm based image:
#   RUN --mount=type=bind,from=agentbox,target=/agentbox /agentbox/install.sh
# It installs: user `agent` (uid 1000) with /workspace, Node (only when the image has none), Claude Code,
# Playwright MCP with Chromium and WebKit under /opt/ms-playwright, git built from a release, gh, git-spice, lazygit, delta,
# revue, tmux, dnsmasq, socat, the net-log, gh, git-spice, pbcopy, xclip and open scripts, git and sudo settings for the bot identity. The harness
# bootstrap is not baked in: compose mounts <harness>/runtime at /agentbox and `agentbox up` runs it from there.
# Build ARGs it honours when declared before the RUN line: PLAYWRIGHT_MCP_VERSION (default latest), NODE_VERSION,
# REVUE_VERSION (default latest; it seeds a new home volume only, an existing box updates with `revue update`),
# GIT_SPICE_VERSION (default latest, the newest release at build time; a number such as 0.33.0 pins it),
# GIT_VERSION with its GIT_SHA256 (the tarball's line in kernel.org's signed sha256sums.asc).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
: "${PLAYWRIGHT_MCP_VERSION:=latest}"
: "${REVUE_VERSION:=latest}"
: "${NODE_VERSION:=24.15.0}"
: "${LAZYGIT_VERSION:=0.65.1}"
: "${DELTA_VERSION:=0.19.2}"
: "${GIT_SPICE_VERSION:=latest}"
: "${GIT_VERSION:=2.56.1}"
: "${GIT_SHA256:=f0b0bf89264b9bd2e1c640363e7529643989da76281600473c50745cd34a607f}"
: "${ZSH_SYNTAX_HIGHLIGHTING_VERSION:=0.8.0}"
export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y --no-install-recommends \
  curl ca-certificates gnupg jq less vim tmux procps sudo xz-utils \
  dnsmasq socat iproute2 zsh libcurl4 libexpat1 libpcre2-8-0 zlib1g

# git from the release tarball: Debian bookworm ships 2.39, bookworm-backports has no git, and config-based hooks
# (hook.<name>.command and hook.<name>.event) need 2.54. It goes to /usr/local, ahead of the distribution's git on
# PATH (gh depends on that package, so it stays), and reads its system config from /etc like the distribution's.
# The build packages the base image does not have are removed again in this layer.
git_build_packages="make gcc libc6-dev libcurl4-openssl-dev libexpat1-dev libpcre2-dev libssl-dev zlib1g-dev"
git_added_packages="$(for package in $git_build_packages; do
  dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -q 'ok installed' || echo "$package"
done)"
[ -z "$git_added_packages" ] || apt-get install -y --no-install-recommends $git_added_packages
curl -fsSL "https://mirrors.edge.kernel.org/pub/software/scm/git/git-${GIT_VERSION}.tar.xz" -o /tmp/git.tar.xz
echo "$GIT_SHA256  /tmp/git.tar.xz" | sha256sum -c -
tar -xJf /tmp/git.tar.xz -C /tmp
make -C "/tmp/git-${GIT_VERSION}" -j"$(nproc)" prefix=/usr/local sysconfdir=/etc \
  INSTALL_STRIP=-s USE_LIBPCRE2=1 NO_RUST=1 NO_GETTEXT=1 NO_PERL=1 NO_PYTHON=1 NO_TCLTK=1 install >/dev/null
rm -rf /tmp/git.tar.xz "/tmp/git-${GIT_VERSION}"
[ -z "$git_added_packages" ] || apt-get purge -y --auto-remove $git_added_packages
/usr/local/bin/git --version
curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /usr/share/keyrings/githubcli-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
  > /etc/apt/sources.list.d/github-cli.list
apt-get update
apt-get install -y --no-install-recommends gh

arch="$(dpkg --print-architecture)"
case "$arch" in
  amd64) lazygit_arch=x86_64; delta_arch=x86_64-unknown-linux-gnu;  git_spice_arch=x86_64 ;;
  arm64) lazygit_arch=arm64;  delta_arch=aarch64-unknown-linux-gnu; git_spice_arch=aarch64 ;;
  *) echo "unsupported arch $arch" >&2; exit 1 ;;
esac
curl -fsSL "https://github.com/jesseduffield/lazygit/releases/download/v${LAZYGIT_VERSION}/lazygit_${LAZYGIT_VERSION}_linux_${lazygit_arch}.tar.gz" \
  | tar -xz -C /usr/local/bin lazygit
curl -fsSL "https://github.com/dandavison/delta/releases/download/${DELTA_VERSION}/delta-${DELTA_VERSION}-${delta_arch}.tar.gz" \
  | tar -xz -C /tmp
install -m 755 "/tmp/delta-${DELTA_VERSION}-${delta_arch}/delta" /usr/local/bin/delta
rm -rf "/tmp/delta-${DELTA_VERSION}-${delta_arch}"

# git-spice: stacked pull requests, so a big change lands as a chain of small reviewable PRs. The real binary
# goes to libexec; /usr/local/bin/git-spice is a shim that gives it the bot token.
if [ "$GIT_SPICE_VERSION" = latest ]; then
  git_spice_url="https://github.com/abhinav/git-spice/releases/latest/download"
else
  git_spice_url="https://github.com/abhinav/git-spice/releases/download/v${GIT_SPICE_VERSION}"
fi
install -d /usr/local/libexec
curl -fsSL "$git_spice_url/git-spice.Linux-${git_spice_arch}.tar.gz" | tar -xz -C /usr/local/libexec git-spice

if ! command -v node >/dev/null; then
  arch="$(dpkg --print-architecture)"
  case "$arch" in amd64) narch=x64 ;; arm64) narch=arm64 ;; *) echo "unsupported arch $arch" >&2; exit 1 ;; esac
  curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-${narch}.tar.xz" \
    | tar -xJ -C /usr/local --strip-components=1 --no-same-owner
fi

# Playwright MCP, global. Browsers go to a shared path; compose.base.yml sets
# PLAYWRIGHT_BROWSERS_PATH to the same value so every user in the container finds them.
export PLAYWRIGHT_BROWSERS_PATH=/opt/ms-playwright
npm install -g "@playwright/mcp@${PLAYWRIGHT_MCP_VERSION}"
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

# Non-root user, uid 1000 to match the volume chown done by `agentbox up`; passwordless sudo, the container is the boundary.
if existing="$(getent passwd 1000 | cut -d: -f1)" && [ -n "$existing" ] && [ "$existing" != agent ]; then
  echo "uid 1000 is already taken by '$existing' in the base image" >&2; exit 1
fi
id agent >/dev/null 2>&1 || useradd -m -u 1000 -s /bin/bash agent
echo "agent ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/agent
chmod 0440 /etc/sudoers.d/agent
mkdir -p /workspace && chown agent:agent /workspace

git clone --quiet --depth 1 --branch "$ZSH_SYNTAX_HIGHLIGHTING_VERSION" \
  https://github.com/zsh-users/zsh-syntax-highlighting.git /usr/share/zsh-syntax-highlighting
rm -rf /usr/share/zsh-syntax-highlighting/.git

# Claude Code, installed natively as the agent rather than globally with npm. An npm -g install lands in a
# root-owned tree, which is why `claude update` fails in a box with "Insufficient permissions"; the native install
# lives in /home/agent/.local, which the agent owns and which Docker seeds into the home volume. The shim stands
# in for ~/.local/bin, which is not on PATH.
su agent -s /bin/bash -c 'export HOME=/home/agent; curl -fsSL https://claude.ai/install.sh | bash'
install -m 755 "$HERE/claude" /usr/local/bin/claude
# revue: the human reviews agent diffs in it, the agent reads the feedback with its CLI. Installed as the agent into
# /home/agent/.local/bin, like Claude Code above, so `revue update` can write to it; the shim stands in for that
# directory on PATH.
case "$REVUE_VERSION" in
  latest) revue_url="https://github.com/rphf/revue/releases/latest/download/revue_linux_${arch}.tar.gz" ;;
  *)      revue_url="https://github.com/rphf/revue/releases/download/v${REVUE_VERSION}/revue_linux_${arch}.tar.gz" ;;
esac
su agent -s /bin/bash -c "set -o pipefail; mkdir -p /home/agent/.local/bin && curl -fsSL '$revue_url' | tar -xz -C /home/agent/.local/bin revue"
install -m 755 "$HERE/revue" /usr/local/bin/revue
# ~/.local/bin on the interactive PATH too: the shim covers scripts and `docker exec`, but claude checks the PATH
# itself and warns when it is missing, and anything else the agent installs for itself lands there as well.
# The system rc file, not ~/.zshrc, which belongs to the human's home overlay.
printf '\n# agentbox: the agent installs its own tools here (Claude Code among them)\n%s\n' \
  'case ":$PATH:" in *:"$HOME/.local/bin":*) ;; *) PATH="$HOME/.local/bin:$PATH" ;; esac' >> /etc/zsh/zshrc
install -m 755 "$HERE/gh" /usr/local/bin/gh
install -m 755 "$HERE/git-spice" /usr/local/bin/git-spice
install -m 755 "$HERE/pbcopy" /usr/local/bin/pbcopy
install -m 755 "$HERE/xclip" /usr/local/bin/xclip
install -m 755 "$HERE/open" /usr/local/bin/open
ln -sf /usr/local/bin/pbcopy /usr/local/bin/clip
ln -sf /usr/local/bin/open /usr/local/bin/xdg-open
install -m 755 "$HERE/net-log" /usr/local/bin/net-log
