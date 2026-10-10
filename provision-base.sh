#!/usr/bin/env bash
# Runs as root inside the base builder VM (called by devbox build-base).
#   $1 user  $2 uid  $3 gid  $4 proxy url  [$5 git name  $6 git email]
# Nothing project-specific belongs here: every devbox VM is cloned from this.
set -euo pipefail
U="$1"; UID_N="$2"; GID_N="$3"; PROXY_URL="$4"
GIT_NAME="${5:-}"; GIT_EMAIL="${6:-}"
H="/home/$U"
export DEBIAN_FRONTEND=noninteractive

# ── all traffic goes through the proxy (the VM has no route and no DNS) ─────
cat >/etc/profile.d/90-devbox.sh <<EOF
export HTTP_PROXY=$PROXY_URL HTTPS_PROXY=$PROXY_URL http_proxy=$PROXY_URL https_proxy=$PROXY_URL
export NO_PROXY=localhost,127.0.0.1,::1 no_proxy=localhost,127.0.0.1,::1
# One project per VM: build output stays on the VM disk (fast, separate from host builds).
export CARGO_TARGET_DIR="\$HOME/.cache/cargo-target"
EOF
cat >/etc/apt/apt.conf.d/90devbox-proxy <<EOF
Acquire::http::Proxy "$PROXY_URL";
Acquire::https::Proxy "$PROXY_URL";
EOF
# shellcheck disable=SC1091
. /etc/profile.d/90-devbox.sh

hostport="${PROXY_URL#http://}"
for _ in $(seq 60); do
  timeout 2 bash -c "</dev/tcp/${hostport%:*}/${hostport##*:}" 2>/dev/null && break
  sleep 2
done

# snapd is a daemon and ignores proxy environment variables: configure it directly.
if command -v snap >/dev/null; then
  snap wait system seed.loaded 2>/dev/null || true
  snap set system proxy.http="$PROXY_URL" proxy.https="$PROXY_URL" || echo "note: could not set the snapd proxy"
fi

# ── user with the host's uid/gid so files in mounted projects keep their owner ─
existing="$(getent passwd "$UID_N" | cut -d: -f1 || true)"
if [[ -n $existing && $existing != "$U" ]]; then userdel -r "$existing" 2>/dev/null || userdel "$existing"; fi
existing_g="$(getent group "$GID_N" | cut -d: -f1 || true)"
if [[ -n $existing_g && $existing_g != "$U" ]]; then groupdel "$existing_g" || true; fi
getent group "$U" >/dev/null || groupadd -g "$GID_N" "$U"
id "$U" >/dev/null 2>&1 || useradd -m -u "$UID_N" -g "$GID_N" -d "$H" -s /bin/bash "$U"

# Passwordless sudo inside the VM. Network policy is enforced outside the VM,
# so root in here can't widen it.
echo "$U ALL=(ALL) NOPASSWD:ALL" >"/etc/sudoers.d/90-$U"
chmod 0440 "/etc/sudoers.d/90-$U"

# ── packages: Rust build basics (+ libsystemd-dev), a minimal Python, tools agents like ──
apt-get update -q
apt-get -yq full-upgrade
apt-get install -yq --no-install-recommends \
  build-essential pkg-config libssl-dev libsystemd-dev git curl ca-certificates \
  jq ripgrep fd-find less unzip xz-utils gh \
  python3 python3-venv

# runuser + explicit env instead of "sudo -i": sudo -i backslash-escapes its
# command line, which turns newlines into line continuations and breaks
# multi-line scripts (and sudo-rs on newer Ubuntu differs in flag details).
as_user() { runuser -u "$U" -- env HOME="$H" USER="$U" LOGNAME="$U" bash -lc "cd ~ && $1"; }

# ── Rust ────────────────────────────────────────────────────────────────────
as_user "curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal -c rustfmt -c clippy -c rust-src"
# cargo-nextest, prebuilt (upgraded by devbox update with: cargo nextest self update)
as_user 'curl --proto "=https" --tlsv1.2 -LsSf https://get.nexte.st/latest/linux | tar zxf - -C "${CARGO_HOME:-$HOME/.cargo}/bin"
cargo nextest --version'

# ── Claude Code (native installer) ──────────────────────────────────────────
as_user 'curl -fsSL https://claude.ai/install.sh | bash'
install -d -o "$U" -g "$U" -m 0700 "$H/.claude"
if [[ ! -s $H/.claude/settings.json ]]; then
  cat >"$H/.claude/settings.json" <<'JSON'
{
  "env": {
    "DISABLE_AUTOUPDATER": "1",
    "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1"
  }
}
JSON
  chown "$U:$U" "$H/.claude/settings.json"
fi

# ── opencode ────────────────────────────────────────────────────────────────
# The installer puts the binary in ~/.opencode/bin and only adds that to
# .bashrc, which login shells skip when non-interactive: link it into
# ~/.local/bin (on PATH via .profile), next to claude.
as_user 'curl -fsSL https://opencode.ai/install | bash
mkdir -p ~/.local/bin
ln -sf ~/.opencode/bin/opencode ~/.local/bin/opencode
~/.local/bin/opencode --version'
# No self-updates (devbox update does that) and no session sharing (uploads to opencode's servers).
install -d -o "$U" -g "$U" -m 0700 "$H/.config" "$H/.config/opencode"
if [[ ! -s $H/.config/opencode/opencode.json ]]; then
  cat >"$H/.config/opencode/opencode.json" <<'JSON'
{
  "$schema": "https://opencode.ai/config.json",
  "autoupdate": false,
  "share": "disabled"
}
JSON
  chown "$U:$U" "$H/.config/opencode/opencode.json"
fi

# ── git + GitHub ────────────────────────────────────────────────────────────
# SSH is blocked in the sandbox: use HTTPS for GitHub remotes, with gh as the
# credential helper. Tokens are added per VM with: devbox gh-login <vm>
if [[ -n $GIT_NAME ]]; then as_user "git config --global user.name $(printf '%q' "$GIT_NAME")"; fi
if [[ -n $GIT_EMAIL ]]; then as_user "git config --global user.email $(printf '%q' "$GIT_EMAIL")"; fi
as_user 'git config --global url."https://github.com/".insteadOf "git@github.com:"
git config --global --add url."https://github.com/".insteadOf "ssh://git@github.com/"
git config --global credential."https://github.com".helper ""
git config --global --add credential."https://github.com".helper "!/usr/bin/gh auth git-credential"
git config --global credential."https://gist.github.com".helper ""
git config --global --add credential."https://gist.github.com".helper "!/usr/bin/gh auth git-credential"'


echo "base provisioned for $U"
