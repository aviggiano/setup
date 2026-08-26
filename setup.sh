#!/usr/bin/env bash
#
# setup.sh — provision a Debian/Ubuntu box with:
#   * system packages brought up to date (apt update && apt full-upgrade)
#   * Git author identity       configured globally
#   * GitHub CLI (gh)          via GitHub's official apt repository
#   * OpenAI Codex CLI         via https://chatgpt.com/codex/install.sh
#   * codex-lb (opt-in)        via `uv tool install` + a systemd --user service
#   * ~/.codex/config.toml     model + reasoning effort, and the codex-lb
#                              provider when codex-lb is enabled
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
#   CODEX_LB          1 to install codex-lb and route Codex through it
#                                                         (default: 0)
#   CODEX_LB_HOST     interface codex-lb binds to         (default: 0.0.0.0)
#   CODEX_LB_PORT     port codex-lb listens on            (default: 2455)
#   SKIP_APT_UPGRADE  set to 1 to skip the apt upgrade step
#   CLAUDE_AUTH       login (browser OAuth, default) | token (setup-token) | skip
#   OP_AUTH           auto (default) | prompt | skip
#   OP_SERVICE_ACCOUNT_TOKEN
#                     1Password service account token; when set it is stored
#                     without prompting, which is how an automated provisioner
#                     should pass it.
#
# Steps 1-9 are unattended. Step 10 signs you in and needs a *terminal* — but
# not a terminal on stdin. `curl | bash` makes this script stdin, so sign-in
# reads from /dev/tty instead and still works. With no controlling terminal at
# all (cron, `ssh host 'cmd'`) it is skipped and the commands are printed, so
# provisioning still completes. Run it under tmux — an apt upgrade can restart
# the service carrying your SSH session.
#
set -euo pipefail

CODEX_MODEL="${CODEX_MODEL:-gpt-5.6-sol}"
CODEX_EFFORT="${CODEX_EFFORT:-xhigh}"
# codex-lb pools several ChatGPT accounts behind a local endpoint. That is a
# minority setup, and it costs a systemd service, an open port holding account
# tokens, and a config.toml that no longer works if the service is down — so it
# is opt-in. With CODEX_LB=0 Codex talks to OpenAI directly under your own
# login, and nothing below writes a provider or an auth.json.
CODEX_LB="${CODEX_LB:-0}"
case "$CODEX_LB" in
  1 | true | yes) CODEX_LB=1 ;;
  0 | false | no) CODEX_LB=0 ;;
  *) printf 'CODEX_LB must be 0 or 1 (got: %s)\n' "$CODEX_LB" >&2; exit 1 ;;
esac
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
# auto   = use OP_SERVICE_ACCOUNT_TOKEN if set, else prompt when a terminal exists
# prompt = always ask, even if the variable is already set
# skip   = leave 1Password alone
OP_AUTH="${OP_AUTH:-auto}"
case "$OP_AUTH" in
  auto | prompt | skip) ;;
  *) printf 'OP_AUTH must be auto, prompt or skip (got: %s)\n' "$OP_AUTH" >&2; exit 1 ;;
esac

# Non-login shells (cron, `ssh host 'cmd'`, `docker exec`) often do not export
# USER, and `set -u` turns that into a hard failure. HOME is set by PAM/sshd in
# every context this script supports, so only USER needs a fallback.
USER="${USER:-$(id -un)}"

LOCAL_BIN="$HOME/.local/bin"
CODEX_HOME="$HOME/.codex"
UNIT_DIR="$HOME/.config/systemd/user"
UNIT="$UNIT_DIR/codex-lb.service"
OP_ENV="$HOME/.config/op.env"

log()  { printf '\n\033[1;34m==>\033[0m \033[1m%s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[1;33m    warning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m==> error:\033[0m %s\n' "$*" >&2; exit 1; }

TMPWORK="$(mktemp -d "${TMPDIR:-/tmp}/setup.XXXXXX")"
trap 'rm -rf "$TMPWORK"' EXIT

# Append a block to ~/.bashrc exactly once, keyed on a string that must appear
# in it. Every caller here was open-coding the same grep/heredoc pair.
bashrc_once() {
  local marker="$1"
  # -F: the markers are filenames, and an unescaped '.' would match anything.
  grep -qsF "$marker" "$HOME/.bashrc" && return 0
  { echo ''; echo '# added by aviggiano/setup'; cat; } >>"$HOME/.bashrc"
}

# Store the 1Password service account token. Mode 600 and sourced from
# ~/.bashrc, matching how the Claude Code token is handled in step 10b.
write_op_env() {
  mkdir -p "$HOME/.config"
  ( umask 077; printf 'export OP_SERVICE_ACCOUNT_TOKEN=%q\n' "$1" >"$OP_ENV" )
  bashrc_once 'op.env' <<'OP_BASHRC'
# The service account token in op.env is the only secret stored on this machine.
# Every other credential lives in 1Password and is fetched on demand.
#
# Discover what this token can reach:
#   op vault list                          # vaults granted to this service account
#   op item list --vault <vault>           # credentials available in one
#   op item get <item> --vault <vault>     # its fields (--vault is REQUIRED for
#                                          # service accounts; without it op errors)
#
# Use one without storing it:
#   export <VAR>=$(op read "op://<vault>/<item>/<field>")
#   op run --env-file=<file> -- <cmd>      # file holds op:// references, not values
#
# Reference syntax: https://developer.1password.com/docs/cli/secret-reference-syntax/
[ -r "$HOME/.config/op.env" ] && . "$HOME/.config/op.env"
OP_BASHRC
}

# Read a service account token from the terminal.
#
# No asterisk echo: that needs a character-at-a-time loop, which throws away the
# terminal's own line editing, so a mistyped 800-character paste becomes
# unfixable. `read -s` keeps backspace and ctrl-U working; the fingerprint below
# is what actually confirms the paste landed. Reads /dev/tty, not stdin, so this
# survives `curl | bash`.
prompt_op_token() {
  local t ans
  while :; do
    printf '\n    Paste the 1Password service account token (input hidden), or Enter to skip: ' >/dev/tty
    IFS= read -rs t </dev/tty || true
    printf '\n' >/dev/tty
    [[ -z "$t" ]] && return 1
    if [[ "$t" != ops_* ]]; then
      warn "a service account token starts with 'ops_' — that looks like the wrong entry"
      continue
    fi
    printf '    %d chars, %s...%s — correct? [y/N] ' "${#t}" "${t:0:8}" "${t: -4}" >/dev/tty
    IFS= read -r ans </dev/tty || true
    printf '\n' >/dev/tty
    if [[ "$ans" == [yY]* ]]; then OP_TOKEN="$t"; return 0; fi
  done
}

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
[[ $EUID -ne 0 ]] || die "run as a normal user, not root — this installs per-user tools and systemd --user services"
command -v apt-get >/dev/null || die "apt-get not found; this script targets Debian/Ubuntu"
command -v sudo >/dev/null    || die "sudo not found; it is required for the apt steps"

info "user      : $USER"
info "home      : $HOME"
if [[ "$CODEX_LB" == "1" ]]; then
  info "codex-lb  : ${CODEX_LB_HOST}:${CODEX_LB_PORT}"
else
  info "codex-lb  : disabled (CODEX_LB=1 to install it)"
fi
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

# Whether we can talk to the user is decided by the *controlling terminal*, not
# by stdin. Under `curl | bash` this script is stdin, so `-t 0` is false even
# with someone sitting right there — but /dev/tty is still the real terminal and
# still readable. Gate step 10 on that, and `curl | bash` keeps its sign-in.
#
# The cases with genuinely no terminal — cron, `ssh host 'cmd'`, a container
# without a pty — have no /dev/tty to open, and there step 10 is skipped.
if [[ -r /dev/tty && -w /dev/tty ]]; then
  HAVE_TTY=1
else
  HAVE_TTY=0
  warn "no controlling terminal — sign-in will be skipped (provisioning is unaffected)."
  warn "to sign in during the run, invoke this from an interactive shell."
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
# 3b. 1Password CLI — official apt repository, same reasoning as gh
# ---------------------------------------------------------------------------
# Only the binary is installed here. Storing the token is interactive and lives
# in step 10c; installing needs no terminal, so it belongs in the unattended run.
log "Installing 1Password CLI (op)"

OP_KEYRING=/usr/share/keyrings/1password-archive-keyring.gpg
OP_LIST=/etc/apt/sources.list.d/1password.list

if [[ ! -s "$OP_KEYRING" ]]; then
  curl -fsSL https://downloads.1password.com/linux/keys/1password.asc \
    | "${SUDO[@]}" gpg --dearmor --yes -o "$OP_KEYRING" \
    || die "could not install the 1Password apt keyring"
  "${SUDO[@]}" chmod go+r "$OP_KEYRING"
  info "installed apt keyring"
fi

OP_ARCH="$(dpkg --print-architecture)"
OP_REPO="deb [arch=$OP_ARCH signed-by=$OP_KEYRING] https://downloads.1password.com/linux/debian/$OP_ARCH stable main"
if [[ ! -f "$OP_LIST" ]] || ! grep -qF "$OP_REPO" "$OP_LIST"; then
  echo "$OP_REPO" | "${SUDO[@]}" tee "$OP_LIST" >/dev/null
  "${APT[@]}" update -y
  info "added downloads.1password.com apt repository"
fi

"${APT[@]}" install -y 1password-cli
info "$(op --version 2>&1 | head -1)"

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
# 5. uv
# ---------------------------------------------------------------------------
# Installed unconditionally: codex-lb is the only thing here that needs it, but
# uv is a general-purpose tool and the summary points at it either way.
log "Installing uv"

if command -v uv >/dev/null 2>&1; then
  info "$(uv --version)"
  uv self update </dev/null 2>/dev/null || info "uv is externally managed; skipping self-update"
else
  run_installer sh https://astral.sh/uv/install.sh || die "the uv installer failed"
  hash -r
fi
command -v uv >/dev/null || die "uv not on PATH after install"

# ---------------------------------------------------------------------------
# 6. systemd lingering
# ---------------------------------------------------------------------------
# Lingering keeps the user manager alive across logout and starts its units at
# boot without an interactive session. Both long-lived processes this script
# sets up want it — codex-lb in step 7 and the Codex app-server daemon in step
# 9 — so it is enabled regardless of CODEX_LB.
log "Enabling systemd lingering"

if ! loginctl show-user "$USER" --property=Linger 2>/dev/null | grep -q 'Linger=yes'; then
  "${SUDO[@]}" loginctl enable-linger "$USER"
  info "enabled systemd lingering for $USER"
else
  info "systemd lingering already enabled"
fi

# ---------------------------------------------------------------------------
# 7. codex-lb — install, service, health check   (opt-in: CODEX_LB=1)
# ---------------------------------------------------------------------------
# Skipping means "do not set it up", not "tear it down": a box that already has
# codex-lb keeps its service running and its config.toml provider untouched, so
# an unrelated re-run without CODEX_LB=1 cannot break a working install.
if [[ "$CODEX_LB" == "1" ]]; then

  log "Installing codex-lb (https://github.com/Soju06/codex-lb)"

  if uv tool list 2>/dev/null | grep -q '^codex-lb '; then
    uv tool upgrade codex-lb
  else
    uv tool install codex-lb
  fi

  hash -r
  command -v codex-lb >/dev/null || die "codex-lb not on PATH after install"
  info "installed: $(uv tool list | grep '^codex-lb ')"

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

  systemctl --user daemon-reload
  systemctl --user enable codex-lb.service >/dev/null
  systemctl --user restart codex-lb.service
  info "service enabled and (re)started"

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

else

  log "codex-lb"
  info "CODEX_LB=0 — skipping (set CODEX_LB=1 to install it and route Codex through it)"

fi

# ---------------------------------------------------------------------------
# 8. Codex configuration
# ---------------------------------------------------------------------------
log "Configuring Codex"

# The placeholder key belongs to codex-lb: requires_openai_auth = true makes
# Codex insist on ~/.codex/auth.json even though codex-lb supplies the real
# credentials. Without codex-lb there is no such provider, and writing a fake
# apikey here would stand in the way of a real `codex login`.
if [[ "$CODEX_LB" == "1" ]]; then
  # Only write it when absent — never clobber a real login.
  if [[ ! -s "$CODEX_HOME/auth.json" ]]; then
    umask 077
    printf '{\n  "auth_mode": "apikey",\n  "OPENAI_API_KEY": "codex-lb"\n}\n' >"$CODEX_HOME/auth.json"
    info "seeded placeholder $CODEX_HOME/auth.json"
  else
    info "$CODEX_HOME/auth.json already exists — left untouched"
  fi
fi

# Patch config.toml in place: replace the top-level keys and, when codex-lb is
# enabled, the [model_providers.codex-lb] table — leaving every other section
# (plugins, marketplaces, projects, MCP servers, ...) exactly as-is.
CODEX_MODEL="$CODEX_MODEL" CODEX_EFFORT="$CODEX_EFFORT" CODEX_LB_PORT="$CODEX_LB_PORT" \
CODEX_LB="$CODEX_LB" \
CODEX_CONFIG="$CODEX_HOME/config.toml" python3 - <<'PY'
import os, re, shutil

path   = os.environ["CODEX_CONFIG"]
model  = os.environ["CODEX_MODEL"]
effort = os.environ["CODEX_EFFORT"]
port   = os.environ["CODEX_LB_PORT"]
lb     = os.environ["CODEX_LB"] == "1"

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
]
# Only claim model_provider when we are actually standing up the provider.
# With codex-lb off an existing pointer is left as it is: the flag decides what
# gets installed, not what gets removed.
if lb:
    top.append(("model_provider", 'model_provider = "codex-lb"'))

if os.path.exists(path):
    with open(path) as fh:
        lines = fh.read().splitlines()
    shutil.copyfile(path, path + ".bak")
    backed_up = True
else:
    lines, backed_up = [], False

is_table = lambda s: s.lstrip().startswith("[")

# Drop any existing [model_providers.codex-lb] table so the one appended below
# replaces it. Skipped when codex-lb is off, so a re-run without CODEX_LB=1
# does not strip the table out from under a box that is still using it.
if lb:
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
if lb and not body.endswith(provider):
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
# Bootstrapped last so the daemon starts with the finished config.toml in place.
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

# --- 10c. 1Password service account ---------------------------------------
# Runs before the terminal gate on purpose: unlike gh and Claude Code this has
# no browser round trip, and when a provisioner has already put the token in the
# environment it needs no terminal at all. That is the path that makes an
# unattended `OP_SERVICE_ACCOUNT_TOKEN=... bash setup.sh` work end to end.
if [[ "$OP_AUTH" == "skip" ]]; then
  info "op: OP_AUTH=skip — not configuring 1Password"
elif [[ -s "$OP_ENV" && "$OP_AUTH" != "prompt" ]]; then
  info "op: token already present ($OP_ENV)"
elif [[ -n "${OP_SERVICE_ACCOUNT_TOKEN:-}" && "$OP_AUTH" != "prompt" ]]; then
  write_op_env "$OP_SERVICE_ACCOUNT_TOKEN"
  info "op: token taken from the environment, stored in $OP_ENV (mode 600)"
elif [[ $HAVE_TTY -eq 1 ]]; then
  if prompt_op_token; then
    write_op_env "$OP_TOKEN"
    unset OP_TOKEN
    info "op: token stored in $OP_ENV (mode 600) and sourced from ~/.bashrc"
  else
    warn "no token stored; export OP_SERVICE_ACCOUNT_TOKEN yourself before using op"
  fi
else
  info "op: no token supplied — set OP_SERVICE_ACCOUNT_TOKEN, or re-run with a terminal"
fi

if [[ "$CLAUDE_AUTH" == "skip" ]] || [[ $HAVE_TTY -eq 0 ]]; then
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
    #
    # </dev/tty for the same reason run_installer uses </dev/null: under
    # `curl | bash` our stdin is this script's source, and gh's prompts would
    # otherwise eat shell text bash has not parsed yet.
    GH_BROWSER=true gh auth login \
      --hostname github.com --git-protocol https --web </dev/tty \
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
    claude setup-token </dev/tty || die "claude setup-token failed"
    printf '\n    Paste the token (input hidden), or Enter to skip: '
    IFS= read -rs CC_TOKEN </dev/tty || true
    printf '\n'
    if [[ -n "${CC_TOKEN:-}" ]]; then
      mkdir -p "$HOME/.config"
      ( umask 077; printf 'export CLAUDE_CODE_OAUTH_TOKEN=%q\n' "$CC_TOKEN" \
          >"$HOME/.config/claude-code.env" )
      bashrc_once 'claude-code.env' <<'CC_BASHRC'
[ -r "$HOME/.config/claude-code.env" ] && . "$HOME/.config/claude-code.env"
CC_BASHRC
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
    claude </dev/tty || warn "claude exited non-zero"
    [[ -s "$CLAUDE_CREDS" ]] \
      || die "no credentials at $CLAUDE_CREDS — login did not complete. Re-run the script."
    info "claude: signed in (credentials at $CLAUDE_CREDS)"
  fi
fi

# ---------------------------------------------------------------------------
# 11. Summary
# ---------------------------------------------------------------------------
log "Done"

# The codex-lb lines only make sense when it was installed, and `uv tool list |
# grep` / `systemctl is-active` would print blanks and "inactive" otherwise. So
# build those fragments up front and interpolate them into the summary.
if [[ "$CODEX_LB" == "1" ]]; then
  LB_STATUS="$(uv tool list | grep '^codex-lb ' | awk '{print $2}')  ($(systemctl --user is-active codex-lb.service))"
  LB_FIRST_STEP="1. Open the codex-lb dashboard and add your ChatGPT account(s):
           http://127.0.0.1:${CODEX_LB_PORT}
       Set a dashboard password (and TOTP) there before exposing the port."
  LB_SERVICES="   systemctl --user status codex-lb        # load balancer
       systemctl --user restart codex-lb
       journalctl --user -u codex-lb -f

    "
else
  LB_STATUS="not installed (CODEX_LB=1 to enable)"
  LB_FIRST_STEP="1. Sign Codex in to your ChatGPT account:
           codex login"
  LB_SERVICES=""
fi

cat <<SUMMARY
    gh          $(gh --version | head -1)  ($(gh auth status --hostname github.com >/dev/null 2>&1 && echo 'signed in' || echo 'NOT signed in'))
    codex       $(codex --version 2>&1 | head -1)
    claude      $(claude --version 2>&1 | head -1)  ($([[ -s "$CLAUDE_CREDS" ]] && echo 'signed in' || echo 'NOT signed in'))
    op          $(op --version 2>&1 | head -1)  ($([[ -s "$OP_ENV" ]] && echo 'token stored' || echo 'NO token'))
    codex-lb    ${LB_STATUS}
    app-server  $(codex app-server daemon version 2>/dev/null | (jq -r '.status // "unknown"' 2>/dev/null || cat))

    Next steps
    ----------
    ${LB_FIRST_STEP}

    2. Pair the Codex app with this machine (prints a short-lived code):
           codex remote-control pair

    3. Verify Codex works:
           codex doctor
           codex exec 'say hi'

    4. See which credentials this machine can reach (no names are baked in —
       ask 1Password, so a credential added to the vault later just shows up):
           op vault list
           op item list --vault <vault>
           op read "op://<vault>/<item>/<field>"

    Managing the services
    ---------------------
    ${LB_SERVICES}   codex app-server daemon version         # app-server
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
  info "reboot when convenient; the user services come back on their own (lingering is enabled)"
fi
