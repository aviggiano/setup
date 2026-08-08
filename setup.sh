#!/usr/bin/env bash
#
# setup.sh — provision a Debian/Ubuntu box with:
#   * system packages brought up to date (apt update && apt full-upgrade)
#   * Git author identity       configured globally
#   * GitHub CLI (gh)          via GitHub's official apt repository
#   * OpenAI Codex CLI         via https://chatgpt.com/codex/install.sh
#   * codex-lb                 via `uv tool install` + a systemd --user service
#   * ~/.codex/config.toml     pointed at the local codex-lb endpoint
#   * Codex app-server daemon  bootstrapped with remote control enabled
#   * Claude Code              via https://claude.ai/install.sh
#   * sign-in                  gh, then Claude Code — interactive, last, in series
#
# Idempotent: safe to re-run to upgrade an existing install.
#
# Usage:
#   ./setup.sh
#
# Runs unattended wherever sudo does not prompt (NOPASSWD in sudoers), so all of
# these work as well:
#   curl -fsSL .../setup.sh | bash
#   ssh host 'bash -s' <setup.sh
#   ssh host './setup.sh'
# Where sudo does want a password, a terminal is still required.
#
# Environment overrides:
#   CODEX_MODEL       model written to config.toml        (default: gpt-5.6-sol)
#   CODEX_EFFORT      model_reasoning_effort              (default: xhigh)
#   CODEX_LB_HOST     interface codex-lb binds to         (default: 0.0.0.0)
#   CODEX_LB_PORT     port codex-lb listens on            (default: 2455)
#   SKIP_APT_UPGRADE  set to 1 to skip the apt upgrade step
#   CLAUDE_AUTH       login (browser OAuth, default) | token (setup-token) | skip
#
# Steps 1-9 are unattended. Step 10 signs you in and needs a terminal; with no
# TTY it is skipped and the commands are printed instead, so the provisioning
# still completes. Run it under tmux — an apt upgrade can restart the service
# carrying your SSH session.
#
set -euo pipefail

CODEX_MODEL="${CODEX_MODEL:-gpt-5.6-sol}"
CODEX_EFFORT="${CODEX_EFFORT:-xhigh}"
# NOTE: 0.0.0.0 exposes the codex-lb dashboard (which holds your ChatGPT
# account tokens) to every host that can reach this machine. Set a dashboard
# password + TOTP in the UI, or override with CODEX_LB_HOST=127.0.0.1.
CODEX_LB_HOST="${CODEX_LB_HOST:-0.0.0.0}"
CODEX_LB_PORT="${CODEX_LB_PORT:-2455}"
SKIP_APT_UPGRADE="${SKIP_APT_UPGRADE:-0}"
# login = browser OAuth, full credentials (needed for Remote Control)
# token = `claude setup-token`, model requests only
# skip  = leave sign-in to you
CLAUDE_AUTH="${CLAUDE_AUTH:-login}"
case "$CLAUDE_AUTH" in
  login | token | skip) ;;
  *) printf 'CLAUDE_AUTH must be login, token or skip (got: %s)\n' "$CLAUDE_AUTH" >&2; exit 1 ;;
esac

# Non-login shells (cron, `ssh host 'cmd'`, `docker exec`) often do not export
# USER, and `set -u` turns that into a hard failure. HOME is set by PAM/sshd in
# every context this script supports, so only USER needs a fallback.
USER="${USER:-$(id -un)}"

LOCAL_BIN="$HOME/.local/bin"
CODEX_HOME="$HOME/.codex"
UNIT_DIR="$HOME/.config/systemd/user"
UNIT="$UNIT_DIR/codex-lb.service"

log()  { printf '\n\033[1;34m==>\033[0m \033[1m%s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[1;33m    warning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m==> error:\033[0m %s\n' "$*" >&2; exit 1; }

TMPWORK="$(mktemp -d "${TMPDIR:-/tmp}/setup.XXXXXX")"
trap 'rm -rf "$TMPWORK"' EXIT

# Run a third-party install script safely.
#
# `curl URL | sh` gives the installer *our* stdin. Under `curl setup.sh | bash`
# that stdin is this script's own source, so an installer that stops to ask
# "Start Codex now? [y/N]" reads a line of shell text as the answer, and
# whatever it does next has eaten part of the script bash has yet to parse.
#
# So: download to a file, run the file, and hand it /dev/null as stdin — a
# prompt then gets EOF and takes its default. setsid additionally drops the
# controlling terminal, so an installer that opens /dev/tty explicitly cannot
# find one either. --wait keeps the exit status, which --fork alone would lose.
run_installer() {
  local sh_bin="$1" url="$2" dst
  shift 2
  dst="$TMPWORK/$(basename "${url%%\?*}")"
  curl -fsSL "$url" -o "$dst" || die "could not download $url"
  [[ -s "$dst" ]] || die "$url returned an empty file"
  if setsid --wait true >/dev/null 2>&1; then
    setsid --wait "$sh_bin" "$dst" "$@" </dev/null
  else
    "$sh_bin" "$dst" "$@" </dev/null
  fi
}

# ---------------------------------------------------------------------------
# 0. Preflight
# ---------------------------------------------------------------------------
log "Preflight"

[[ "$(uname -s)" == "Linux" ]] || die "this script targets Linux (found $(uname -s))"
[[ $EUID -ne 0 ]] || die "run as a normal user, not root — codex-lb runs as a systemd --user service"
command -v apt-get >/dev/null || die "apt-get not found; this script targets Debian/Ubuntu"
command -v sudo >/dev/null    || die "sudo not found; it is required for the apt steps"

info "user      : $USER"
info "home      : $HOME"
info "codex-lb  : ${CODEX_LB_HOST}:${CODEX_LB_PORT}"
info "model     : ${CODEX_MODEL} (reasoning effort: ${CODEX_EFFORT})"

# Non-interactive sudo. `sudo -v` prompts, which means it fails under
# `curl | bash`, in CI, and over `ssh host <script`. `sudo -n` never prompts, so
# every privileged call below goes through "${SUDO[@]}" instead of bare sudo.
#
# A command-scoped rule (NOPASSWD: /usr/bin/apt-get) makes `sudo -n true` fail
# even though every apt call here would succeed, so probe apt-get separately
# before giving up.
SUDO=(sudo -n)
# needrestart's apt hook restarts every service holding an upgraded library.
# On this kind of box that includes the one carrying your SSH session (sshd,
# tailscaled, ...), which kills the script mid-run. NEEDRESTART_SUSPEND=1 turns
# the hook off for these invocations.
#
# It has to be set *through* sudo: with the default env_reset, sudo strips the
# caller's environment, and `sudo VAR=x` / `sudo -E` both need a SETENV tag that
# a plain NOPASSWD:ALL rule does not grant. `sudo env VAR=x cmd` always works.
APT_ENV=(env NEEDRESTART_SUSPEND=1 DEBIAN_FRONTEND=noninteractive)
if sudo -n true 2>/dev/null; then
  info "sudo      : passwordless"
  APT=("${SUDO[@]}" "${APT_ENV[@]}" apt-get)
elif sudo -n apt-get --version >/dev/null 2>&1; then
  info "sudo      : passwordless for apt-get only"
  # A rule scoped to apt-get will not authorise /usr/bin/env, so drop the
  # wrapper and rely on the needrestart config file instead.
  APT=("${SUDO[@]}" apt-get)
  warn "cannot pass NEEDRESTART_SUSPEND through a command-scoped sudo rule."
  warn "if apt restarts your network service the session dies; make it permanent:"
  warn "  echo \"\\\$nrconf{restart} = 'l';\" | sudo tee /etc/needrestart/conf.d/50-list-only.conf"
elif [[ -t 0 ]]; then
  SUDO=(sudo)
  APT=("${SUDO[@]}" "${APT_ENV[@]}" apt-get)
  warn "sudo will prompt for a password"
  sudo -v || die "could not acquire sudo credentials"
else
  die "no passwordless sudo, and no terminal to prompt on. As root, run:
      echo '$USER ALL=(ALL) NOPASSWD:ALL' >/etc/sudoers.d/90-$USER
      chmod 0440 /etc/sudoers.d/90-$USER
      visudo -cf /etc/sudoers.d/90-$USER"
fi

# A dropped SSH session takes the script with it (SIGHUP), and step 1 alone can
# run for half an hour. tmux makes that survivable.
if [[ -n "${SSH_CONNECTION:-}" && -z "${TMUX:-}" && -z "${STY:-}" ]]; then
  warn "running over SSH outside tmux/screen — a disconnect will kill this run."
  warn "consider: tmux new -As setup, then re-run."
  [[ -t 1 ]] && sleep 5
fi

# Piped into bash, this script *is* stdin, so step 10 cannot read a pasted code
# and is skipped. Say so now rather than at the end of a 20-minute run.
if [[ ! -t 0 ]] && [[ ! -f "${BASH_SOURCE[0]:-}" ]]; then
  warn "this script is being read from stdin (curl | bash)."
  warn "provisioning works, but sign-in needs a terminal and will be skipped."
  warn "to sign in during the run: save it to a file and execute that instead."
fi

# systemctl --user needs a running user manager, which exists in a normal login
# or `machinectl shell` session but not under bare `su -`, and not in a
# container without systemd as PID 1. Checked here so it fails in the preflight
# rather than after apt has already spent five minutes upgrading.
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
systemctl --user show-environment >/dev/null 2>&1 || die \
  "no systemd --user manager for $USER (XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR).
      Log in as $USER directly, or from root: machinectl shell $USER@"

export DEBIAN_FRONTEND=noninteractive
export PATH="$LOCAL_BIN:$PATH"
mkdir -p "$LOCAL_BIN" "$CODEX_HOME" "$UNIT_DIR"

# ---------------------------------------------------------------------------
# 1. System packages
# ---------------------------------------------------------------------------
log "Updating system packages"

"${APT[@]}" update -y

if [[ "$SKIP_APT_UPGRADE" != "1" ]]; then
  "${APT[@]}" full-upgrade -y
else
  info "SKIP_APT_UPGRADE=1 — skipping full-upgrade"
fi

# bubblewrap is the sandbox backend Codex expects on PATH; without it the
# app-server falls back to its bundled copy and logs an error on every start.
"${APT[@]}" install -y --no-install-recommends \
  ca-certificates curl wget git gnupg jq python3 unzip bubblewrap

"${APT[@]}" autoremove -y

log "Configuring Git identity"

git config --global user.name "Antonio Viggiano"
git config --global user.email "agfviggiano@gmail.com"
info "$(git config --global user.name) <$(git config --global user.email)>"

# ---------------------------------------------------------------------------
# 2. Make ~/.local/bin permanently available on PATH
# ---------------------------------------------------------------------------
log "Ensuring ~/.local/bin is on PATH"

if ! grep -qs '\.local/bin' "$HOME/.bashrc" 2>/dev/null; then
  {
    echo ''
    echo '# added by aviggiano/setup'
    echo 'case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) PATH="$HOME/.local/bin:$PATH" ;; esac'
  } >>"$HOME/.bashrc"
  info "appended PATH entry to ~/.bashrc"
else
  info "already present in ~/.bashrc"
fi

# ---------------------------------------------------------------------------
# 3. GitHub CLI — official apt repository, so `apt upgrade` keeps it current
# ---------------------------------------------------------------------------
log "Installing GitHub CLI (gh)"

GH_KEYRING=/usr/share/keyrings/githubcli-archive-keyring.gpg
GH_LIST=/etc/apt/sources.list.d/github-cli.list

if [[ ! -s "$GH_KEYRING" ]]; then
  wget -qO- https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    | "${SUDO[@]}" tee "$GH_KEYRING" >/dev/null
  "${SUDO[@]}" chmod go+r "$GH_KEYRING"
  info "installed apt keyring"
fi

GH_REPO="deb [arch=$(dpkg --print-architecture) signed-by=$GH_KEYRING] https://cli.github.com/packages stable main"
if [[ ! -f "$GH_LIST" ]] || ! grep -qF "$GH_REPO" "$GH_LIST"; then
  echo "$GH_REPO" | "${SUDO[@]}" tee "$GH_LIST" >/dev/null
  "${APT[@]}" update -y
  info "added cli.github.com apt repository"
fi

"${APT[@]}" install -y gh
info "$(gh --version | head -1)"

# A pre-existing ~/.local/bin/gh binary would shadow the apt-managed one.
if [[ -f "$LOCAL_BIN/gh" && ! -L "$LOCAL_BIN/gh" ]]; then
  mv -f "$LOCAL_BIN/gh" "$LOCAL_BIN/gh.pre-apt.bak"
  warn "moved standalone $LOCAL_BIN/gh aside (now apt-managed at $(command -v gh || echo /usr/bin/gh))"
fi

# ---------------------------------------------------------------------------
# 4. Codex CLI
# ---------------------------------------------------------------------------
log "Installing Codex CLI"

if command -v codex >/dev/null 2>&1; then
  info "found $(codex --version 2>&1 | head -1) — upgrading in place"
  codex update </dev/null || warn "codex update failed; falling back to the install script"
fi

if ! command -v codex >/dev/null 2>&1; then
  # Codex's installer added CODEX_NON_INTERACTIVE for headless installs in
  # 0.136.0; belt and braces alongside the /dev/null stdin above.
  export CODEX_NON_INTERACTIVE=1
  run_installer sh https://chatgpt.com/codex/install.sh \
    || die "the Codex installer failed"
fi

hash -r
command -v codex >/dev/null || die "codex not on PATH after install; open a new shell and re-run"
info "$(codex --version 2>&1 | head -1)"

# ---------------------------------------------------------------------------
# 4b. Claude Code
# ---------------------------------------------------------------------------
# The native installer is Anthropic's recommended install; it drops a launcher
# at ~/.local/bin/claude and self-updates in the background, so there is no
# apt/npm package to keep current here.
#   https://code.claude.com/docs/en/setup
log "Installing Claude Code"

if command -v claude >/dev/null 2>&1; then
  info "found $(claude --version 2>&1 | head -1) — native installs self-update"
else
  run_installer bash https://claude.ai/install.sh || die "the Claude Code installer failed"
  hash -r
fi
command -v claude >/dev/null || die "claude not on PATH after install; open a new shell and re-run"
info "$(claude --version 2>&1 | head -1)"

# An API key outranks subscription credentials, so a stray one silently moves
# usage onto API billing. Warn rather than unset — it may be deliberate.
if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
  warn "ANTHROPIC_API_KEY is set; it takes precedence over subscription login."
  warn "unset it if you want this box to bill against Pro/Max instead."
fi

# ---------------------------------------------------------------------------
# 5. uv + codex-lb
# ---------------------------------------------------------------------------
log "Installing uv"

if command -v uv >/dev/null 2>&1; then
  info "$(uv --version)"
  uv self update </dev/null 2>/dev/null || info "uv is externally managed; skipping self-update"
else
  run_installer sh https://astral.sh/uv/install.sh || die "the uv installer failed"
  hash -r
fi
command -v uv >/dev/null || die "uv not on PATH after install"

log "Installing codex-lb (https://github.com/Soju06/codex-lb)"

if uv tool list 2>/dev/null | grep -q '^codex-lb '; then
  uv tool upgrade codex-lb
else
  uv tool install codex-lb
fi

hash -r
command -v codex-lb >/dev/null || die "codex-lb not on PATH after install"
info "installed: $(uv tool list | grep '^codex-lb ')"

# ---------------------------------------------------------------------------
# 6. codex-lb as a systemd --user service
# ---------------------------------------------------------------------------
log "Configuring the codex-lb service"

cat >"$UNIT" <<UNIT_EOF
[Unit]
Description=codex-lb (ChatGPT account pool / load balancer)
Documentation=https://soju06.github.io/codex-lb/
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=%h/.local/bin/codex-lb --host ${CODEX_LB_HOST} --port ${CODEX_LB_PORT}
WorkingDirectory=%h
Environment=PATH=%h/.local/bin:/usr/local/bin:/usr/bin:/bin
Restart=always
RestartSec=5
# SQLite + alembic migrations need room to finish on first boot
TimeoutStartSec=120
# codex-lb opens an aiosqlite connection (2 fds: store.db + store.db-wal) per
# pooled session and does not always release them. Under the default 1024 soft
# limit the process wedges after a few days: every query fails with
# "sqlite3.OperationalError: unable to open database file" and the port stops
# accepting connections, while systemd still reports the unit as active.
# Headroom turns a hard wedge into something the restart below can outrun.
LimitNOFILE=65536
StandardOutput=journal
StandardError=journal
SyslogIdentifier=codex-lb

[Install]
WantedBy=default.target
UNIT_EOF
info "wrote $UNIT"

# Lingering keeps the user manager (and therefore codex-lb) alive across
# logout and starts it at boot without an interactive session.
if ! loginctl show-user "$USER" --property=Linger 2>/dev/null | grep -q 'Linger=yes'; then
  "${SUDO[@]}" loginctl enable-linger "$USER"
  info "enabled systemd lingering for $USER"
else
  info "systemd lingering already enabled"
fi

systemctl --user daemon-reload
systemctl --user enable codex-lb.service >/dev/null
systemctl --user restart codex-lb.service
info "service enabled and (re)started"

# ---------------------------------------------------------------------------
# 7. Wait for codex-lb to answer
# ---------------------------------------------------------------------------
log "Waiting for codex-lb to become healthy"

# Startup blocks on an alembic revision check against store.db, which grows with
# request history — a ~325MB store took ~120s to reach "Application startup
# complete", right at the edge of the old 60x2s budget. Allow ~5min.
LB_READY=0
for _ in $(seq 1 150); do
  if curl -fsS -o /dev/null --max-time 3 "http://127.0.0.1:${CODEX_LB_PORT}/"; then
    LB_READY=1
    break
  fi
  sleep 2
done

if [[ "$LB_READY" == "1" ]]; then
  info "responding on http://127.0.0.1:${CODEX_LB_PORT}/"
else
  warn "no response after ~5min. Check: journalctl --user -u codex-lb -n 50 --no-pager"
fi

# ---------------------------------------------------------------------------
# 8. Point Codex at codex-lb
# ---------------------------------------------------------------------------
log "Configuring Codex to use codex-lb"

# requires_openai_auth = true makes Codex insist on ~/.codex/auth.json even
# though codex-lb supplies the real credentials, so seed a placeholder key.
# Only write it when absent — never clobber a real login.
if [[ ! -s "$CODEX_HOME/auth.json" ]]; then
  umask 077
  printf '{\n  "auth_mode": "apikey",\n  "OPENAI_API_KEY": "codex-lb"\n}\n' >"$CODEX_HOME/auth.json"
  info "seeded placeholder $CODEX_HOME/auth.json"
else
  info "$CODEX_HOME/auth.json already exists — left untouched"
fi

# Patch config.toml in place: replace the three top-level keys and the
# [model_providers.codex-lb] table, leaving every other section (plugins,
# marketplaces, projects, MCP servers, ...) exactly as-is.
CODEX_MODEL="$CODEX_MODEL" CODEX_EFFORT="$CODEX_EFFORT" CODEX_LB_PORT="$CODEX_LB_PORT" \
CODEX_CONFIG="$CODEX_HOME/config.toml" python3 - <<'PY'
import os, re, shutil

path   = os.environ["CODEX_CONFIG"]
model  = os.environ["CODEX_MODEL"]
effort = os.environ["CODEX_EFFORT"]
port   = os.environ["CODEX_LB_PORT"]

provider = f"""[model_providers.codex-lb]
name = "openai"  # required -- enables remote /responses/compact
base_url = "http://127.0.0.1:{port}/backend-api/codex"
wire_api = "responses"
supports_websockets = true
requires_openai_auth = true  # required for the Codex app-server
"""

top = [
    ("model", f'model = "{model}"'),
    ("model_reasoning_effort", f'model_reasoning_effort = "{effort}"'),
    ("model_provider", 'model_provider = "codex-lb"'),
]

if os.path.exists(path):
    with open(path) as fh:
        lines = fh.read().splitlines()
    shutil.copyfile(path, path + ".bak")
    backed_up = True
else:
    lines, backed_up = [], False

is_table = lambda s: s.lstrip().startswith("[")

# Drop any existing [model_providers.codex-lb] table.
out, skipping = [], False
for line in lines:
    if skipping:
        if is_table(line):
            skipping = False
        else:
            continue
    if re.match(r'\s*\[model_providers\.(codex-lb|"codex-lb")\]\s*$', line):
        skipping = True
        continue
    out.append(line)
lines = out

# Split into the top-level preamble and the remaining tables.
first_table = next((i for i, l in enumerate(lines) if is_table(l)), len(lines))
pre, rest = lines[:first_table], lines[first_table:]

# Upsert each top-level key into the preamble.
for key, rendered in top:
    pat = re.compile(rf"\s*{re.escape(key)}\s*=")
    for i, line in enumerate(pre):
        if pat.match(line):
            pre[i] = rendered
            break
    else:
        pre.append(rendered)

pre = [l for l in pre if l.strip()]          # tidy stray blank lines
body = "\n".join(pre + [""] + rest).rstrip() + "\n"
if not body.endswith(provider):
    body = body.rstrip() + "\n\n" + provider

with open(path, "w") as fh:
    fh.write(body)

print(f"    wrote {path}" + ("  (previous version saved as config.toml.bak)" if backed_up else ""))
PY

# ---------------------------------------------------------------------------
# 9. Codex app-server daemon (remote control)
# ---------------------------------------------------------------------------
# The app-server is the long-lived process the Codex app / IDE extensions drive
# over a unix socket at ~/.codex/app-server-control/. `daemon bootstrap`
# installs durable management for it (survives SSH disconnects); with
# --remote-control it also accepts sessions from the Codex app after pairing.
# Bootstrapped last so the daemon starts with the codex-lb provider in place.
log "Setting up the Codex app-server daemon"

if codex app-server daemon bootstrap --remote-control </dev/null; then
  info "app-server bootstrapped with remote control enabled"
else
  warn "bootstrap failed — retrying as a plain restart"
  codex app-server daemon restart </dev/null || warn "could not start the app-server daemon"
  codex app-server daemon enable-remote-control </dev/null || warn "could not enable remote control"
fi

APP_SERVER_STATE="$(codex app-server daemon version 2>/dev/null || echo '{}')"
if command -v jq >/dev/null 2>&1; then
  info "status: $(jq -r '.status // "unknown"' <<<"$APP_SERVER_STATE")" \
       "(app-server $(jq -r '.appServerVersion // "?"' <<<"$APP_SERVER_STATE"))"
  info "socket: $(jq -r '.socketPath // "?"' <<<"$APP_SERVER_STATE")"
else
  info "$APP_SERVER_STATE"
fi

# ---------------------------------------------------------------------------
# 10. Interactive sign-in (gh, then Claude Code) — in series, last
# ---------------------------------------------------------------------------
# Everything above is unattended. These two are not: each prints a code or URL,
# waits for you to finish in a browser elsewhere, and must not overlap with the
# other or you end up pasting the wrong code into the wrong page. So they run
# one at a time, at the very end, and a failure stops the script rather than
# falling through to a summary that claims success.
log "Interactive sign-in"

CLAUDE_CREDS="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.credentials.json"

if [[ "$CLAUDE_AUTH" == "skip" ]] || [[ ! -t 0 ]] || [[ ! -t 1 ]]; then
  if [[ "$CLAUDE_AUTH" == "skip" ]]; then
    info "CLAUDE_AUTH=skip — not signing in"
  else
    info "no terminal — skipping sign-in (provisioning above is complete)"
  fi
  info "run these yourself, one at a time:"
  info "    GH_BROWSER=true gh auth login --hostname github.com --git-protocol https --web"
  info "    claude          # complete /login, then /exit"
else

  # --- 10a. GitHub -------------------------------------------------------
  if gh auth status --hostname github.com >/dev/null 2>&1; then
    info "gh: already signed in as $(gh api user --jq .login 2>/dev/null || echo '?')"
  else
    cat <<'GH_EOF'

    gh will print a one-time code. On your laptop, open

        https://github.com/login/device

    paste the code, approve, and gh finishes on its own. Nothing is typed back
    into this terminal.

GH_EOF
    # GH_BROWSER=true makes the browser-open step a no-op. Without it gh tries
    # to launch a browser on this headless box — sometimes a terminal browser,
    # which makes the device flow look hung while it is really just polling.
    GH_BROWSER=true gh auth login \
      --hostname github.com --git-protocol https --web \
      || die "gh auth login did not complete. Re-run the script when ready; it is idempotent."
    gh auth status --hostname github.com >/dev/null 2>&1 \
      || die "gh reports no credentials after login"
    info "gh: signed in as $(gh api user --jq .login 2>/dev/null || echo '?')"
  fi

  # --- 10b. Claude Code --------------------------------------------------
  # Note: Claude Code has no device-code flow. `claude` runs a browser OAuth
  # round trip against a localhost callback; over SSH that callback is usually
  # unreachable, so the browser shows a code you paste back at the CLI's
  # "Paste code here if prompted" prompt. That is the paste step here.
  #   https://code.claude.com/docs/en/authentication
  if [[ -s "$CLAUDE_CREDS" ]]; then
    info "claude: credentials already present ($CLAUDE_CREDS)"
  elif [[ "$CLAUDE_AUTH" == "token" ]]; then
    cat <<'TOKEN_EOF'

    `claude setup-token` will print a URL. Approve it in a browser on your
    laptop and it prints a one-year OAuth token. It saves that token nowhere,
    so paste it back here and this script will store it for you.

    Caveat: a setup-token credential can only make model requests. It cannot
    open Remote Control sessions or pull claude.ai connectors. Use
    CLAUDE_AUTH=login if you need either.

TOKEN_EOF
    claude setup-token || die "claude setup-token failed"
    printf '\n    Paste the token (input hidden), or Enter to skip: '
    IFS= read -rs CC_TOKEN || true
    printf '\n'
    if [[ -n "${CC_TOKEN:-}" ]]; then
      mkdir -p "$HOME/.config"
      ( umask 077; printf 'export CLAUDE_CODE_OAUTH_TOKEN=%q\n' "$CC_TOKEN" \
          >"$HOME/.config/claude-code.env" )
      if ! grep -qs 'claude-code.env' "$HOME/.bashrc"; then
        {
          echo ''
          echo '# added by aviggiano/setup'
          echo '[ -r "$HOME/.config/claude-code.env" ] && . "$HOME/.config/claude-code.env"'
        } >>"$HOME/.bashrc"
      fi
      unset CC_TOKEN
      info "token written to ~/.config/claude-code.env (mode 600) and sourced from ~/.bashrc"
      warn "that file is a year-long credential in plaintext — treat the box accordingly"
    else
      warn "no token stored; export CLAUDE_CODE_OAUTH_TOKEN yourself before using claude"
    fi
  else
    cat <<'CLAUDE_EOF'

    Claude Code will start and open its login flow. On your laptop, press `c`
    to copy the login URL if no browser opens, sign in, and if the browser
    shows a code rather than returning to the terminal, paste that code at the
    "Paste code here if prompted" prompt.

    When it says "Login successful", type /exit to hand this terminal back.

CLAUDE_EOF
    claude || warn "claude exited non-zero"
    [[ -s "$CLAUDE_CREDS" ]] \
      || die "no credentials at $CLAUDE_CREDS — login did not complete. Re-run the script."
    info "claude: signed in (credentials at $CLAUDE_CREDS)"
  fi
fi

# ---------------------------------------------------------------------------
# 11. Summary
# ---------------------------------------------------------------------------
log "Done"

cat <<SUMMARY
    gh          $(gh --version | head -1)  ($(gh auth status --hostname github.com >/dev/null 2>&1 && echo 'signed in' || echo 'NOT signed in'))
    codex       $(codex --version 2>&1 | head -1)
    claude      $(claude --version 2>&1 | head -1)  ($([[ -s "$CLAUDE_CREDS" ]] && echo 'signed in' || echo 'NOT signed in'))
    codex-lb    $(uv tool list | grep '^codex-lb ' | awk '{print $2}')  ($(systemctl --user is-active codex-lb.service))
    app-server  $(codex app-server daemon version 2>/dev/null | (jq -r '.status // "unknown"' 2>/dev/null || cat))

    Next steps
    ----------
    1. Open the codex-lb dashboard and add your ChatGPT account(s):
           http://127.0.0.1:${CODEX_LB_PORT}
       Set a dashboard password (and TOTP) there before exposing the port.

    2. Pair the Codex app with this machine (prints a short-lived code):
           codex remote-control pair

    3. Verify Codex is routing through codex-lb:
           codex doctor
           codex exec 'say hi'

    Managing the services
    ---------------------
       systemctl --user status codex-lb        # load balancer
       systemctl --user restart codex-lb
       journalctl --user -u codex-lb -f

       codex app-server daemon version         # app-server
       codex app-server daemon restart
       tail -f ~/.codex/app-server-control/app-server.log

    Note: 'codex', 'claude' and 'uv' live in ~/.local/bin — run 'exec \$SHELL -l'
    or open a new shell if this was a first-time install.
SUMMARY

# A kernel or libc upgrade needs a reboot to take effect. Say so plainly rather
# than letting it surface later as a surprise disconnect.
if [[ -f /var/run/reboot-required ]]; then
  warn "reboot required to finish applying upgrades"
  if [[ -s /var/run/reboot-required.pkgs ]]; then
    info "triggered by: $(sort -u /var/run/reboot-required.pkgs | tr '\n' ' ')"
  fi
  info "running kernel: $(uname -r)"
  info "reboot when convenient; codex-lb comes back on its own (lingering is enabled)"
fi
