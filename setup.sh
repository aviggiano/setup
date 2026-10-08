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
#   * opencode                 via https://opencode.ai/install, plus a plugin
#                              that stops OpenRouter's prompt-injection
#                              guardrail from blocking opencode's own prompts
#   * T3 Code (default on)     release tarball + its systemd --user service,
#                              with its OpenCode provider switched on
#   * hob (default on)         verified release binary + a systemd --user
#                              service running `hob --headless`
#   * secrets from 1Password   a service account token is the one secret you
#                              supply; OPENROUTER_API_KEY (for opencode and the
#                              systemd --user services) and the hob license
#                              key are read from its vault with `op`
#   * sign-in                  gh, Codex (device auth, when codex-lb is off),
#                              then Claude Code — interactive, last, in series
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
#   GH_AUTH           login (device flow, default) | skip
#   CODEX_AUTH        login (device auth, default) | skip — ignored when
#                     CODEX_LB=1, where the accounts live in codex-lb
#   CLAUDE_AUTH       login (browser OAuth, default) | token (setup-token) | skip
#   T3CODE            0 to skip installing T3 Code and its service
#                                                         (default: 1)
#   T3_PAIR_TTL       lifetime of the T3 Code pairing token printed at the end
#                     when Tailscale is up                (default: 15m)
#   HOB               0 to skip installing hob and its service
#                                                         (default: 1)
#   OP_AUTH           auto (default) | prompt | skip — auto stores
#                     OP_SERVICE_ACCOUNT_TOKEN or prompts for one
#   OP_SERVICE_ACCOUNT_TOKEN
#                     1Password service account token; when set it is stored
#                     without prompting, which is how an automated provisioner
#                     should pass it.
#   OP_VAULT          vault the secrets below are read from
#                     (default: the only vault the token can see)
#
# Secrets read from 1Password, by item title, from the item's "credential"
# field (an API Credential item) or else its "password" field:
#   OPENROUTER_API_KEY  OpenRouter API key for opencode and T3 Code; re-running
#                       after changing it in the vault rotates the stored copy
#   HOB_LICENSE_KEY     hob license key, activated when hob has no license
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
# Each of the three sign-ins in step 10 has its own switch. They used to share
# one — CLAUDE_AUTH=skip skipped gh as well — which stopped making sense once
# Codex joined them.
GH_AUTH="${GH_AUTH:-login}"
case "$GH_AUTH" in
  login | skip) ;;
  *) printf 'GH_AUTH must be login or skip (got: %s)\n' "$GH_AUTH" >&2; exit 1 ;;
esac
# login = `codex login --device-auth`, the device-code flow
# skip  = leave sign-in to you
# Only consulted when CODEX_LB=0. With codex-lb the ChatGPT accounts are added
# in its dashboard and ~/.codex/auth.json holds a placeholder, so there is
# nothing for `codex login` to do.
CODEX_AUTH="${CODEX_AUTH:-login}"
case "$CODEX_AUTH" in
  login | skip) ;;
  *) printf 'CODEX_AUTH must be login or skip (got: %s)\n' "$CODEX_AUTH" >&2; exit 1 ;;
esac
# login = browser OAuth, full credentials (needed for Remote Control)
# token = `claude setup-token`, model requests only
# skip  = leave sign-in to you
CLAUDE_AUTH="${CLAUDE_AUTH:-login}"
case "$CLAUDE_AUTH" in
  login | token | skip) ;;
  *) printf 'CLAUDE_AUTH must be login, token or skip (got: %s)\n' "$CLAUDE_AUTH" >&2; exit 1 ;;
esac
# skip   = leave 1Password alone (the op binary is still installed)
# auto   = use OP_SERVICE_ACCOUNT_TOKEN if set, else the stored token, else
#          prompt when a terminal exists
# prompt = always ask, even if the variable is already set
# On by default: every other secret this script needs is read from 1Password,
# so without a token opencode has no OpenRouter key and hob no license.
OP_AUTH="${OP_AUTH:-auto}"
case "$OP_AUTH" in
  auto | prompt | skip) ;;
  *) printf 'OP_AUTH must be auto, prompt or skip (got: %s)\n' "$OP_AUTH" >&2; exit 1 ;;
esac
# Empty means "the only vault the token can see"; see op_vault.
OP_VAULT="${OP_VAULT:-}"
# T3 Code (https://github.com/pingdotgg/t3code) is a web UI over the Claude Code
# and Codex CLIs installed above. On by default; T3CODE=0 skips it. Like
# CODEX_LB, skipping means "do not set it up", not "tear it down".
T3CODE="${T3CODE:-1}"
case "$T3CODE" in
  1 | true | yes) T3CODE=1 ;;
  0 | false | no) T3CODE=0 ;;
  *) printf 'T3CODE must be 0 or 1 (got: %s)\n' "$T3CODE" >&2; exit 1 ;;
esac
# t3's default is 5m, which is gone before you have read the summary it follows.
T3_PAIR_TTL="${T3_PAIR_TTL:-15m}"
# hob (https://hob.dev) runs headless here so its desktop app can connect over
# SSH. On by default; HOB=0 skips it, and like T3CODE does not tear it down.
HOB="${HOB:-1}"
case "$HOB" in
  1 | true | yes) HOB=1 ;;
  0 | false | no) HOB=0 ;;
  *) printf 'HOB must be 0 or 1 (got: %s)\n' "$HOB" >&2; exit 1 ;;
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
T3_HOME="$HOME/.t3"
T3_STATE="$T3_HOME/runtime/service-state.json"
T3_SETTINGS="$T3_HOME/userdata/settings.json"
# opencode and systemd both read XDG_CONFIG_HOME, so these paths follow it.
OPENCODE_BIN="$HOME/.opencode/bin/opencode"
OPENCODE_PLUGIN="${XDG_CONFIG_HOME:-$HOME/.config}/opencode/plugins/openrouter-guardrail.js"
OPENROUTER_ENV="${XDG_CONFIG_HOME:-$HOME/.config}/environment.d/60-openrouter.conf"
HOB_BIN="$LOCAL_BIN/hob"
HOB_UNIT="$UNIT_DIR/hob.service"

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
  # The secret lookups later in this run need it too.
  export OP_SERVICE_ACCOUNT_TOKEN="$1"
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

# Decide whether an OpenRouter key can be stored. GET /api/v1/key returns the
# key's own limits and usage and spends no credits. The header goes through
# stdin, so the key is not in curl's argv, which other local users can read in
# /proc.
check_openrouter_key() {
  local code
  # bash sources the file this key goes into, and systemd parses it. Other
  # characters can break either one, or run as a command in every new shell.
  if [[ ! "$1" =~ ^[A-Za-z0-9_-]+$ ]]; then
    warn "the OpenRouter key has characters other than letters, digits, '-' and '_'"
    return 1
  fi
  code="$(printf 'Authorization: Bearer %s\n' "$1" \
    | curl -s -o /dev/null -w '%{http_code}' --max-time 15 -H @- \
        https://openrouter.ai/api/v1/key || true)"
  case "$code" in
    200) return 0 ;;
    401 | 403) warn "OpenRouter rejected the key (HTTP $code)"; return 1 ;;
    *) warn "could not check the key with OpenRouter (HTTP ${code:-none}); storing it unchecked"; return 0 ;;
  esac
}

# The vault secrets are read from: OP_VAULT, or else the only vault the token
# can see. A service account is granted specific vaults, so one vault is the
# usual case and naming it would be one more thing to keep in sync. With
# several, guessing could read the wrong item, so that needs OP_VAULT.
# Sets OP_VAULT rather than printing it, so call it in this shell, not in
# $(...), or the answer is lost and every lookup lists the vaults again.
op_vault() {
  local vaults n
  if [[ -z "$OP_VAULT" ]]; then
    # A rejected token fails here first; say so instead of "no vaults".
    if ! vaults="$(op vault list --format json 2>&1)"; then
      warn "op: could not list vaults — $(head -n 1 <<<"$vaults")"
      warn "op: to replace the stored token: OP_AUTH=prompt ./setup.sh"
      return 1
    fi
    vaults="$(jq -r '.[].name' <<<"$vaults")"
    n="$(grep -c . <<<"$vaults" || true)"
    case "$n" in
      1) OP_VAULT="$vaults" ;;
      0) warn "op: the service account token cannot see any vault"; return 1 ;;
      *) warn "op: the token can see $n vaults ($(tr '\n' ' ' <<<"$vaults")) — set OP_VAULT to pick one"
         return 1 ;;
    esac
  fi
}

# Print the secret stored in the item titled $1. API Credential items keep it
# in "credential", Password items in "password"; try both so either item type
# works. Nothing reaches argv but the reference, and nothing reaches the log.
op_secret() {
  local field v
  [[ -n "${OP_SERVICE_ACCOUNT_TOKEN:-}" ]] && op_vault || return 1
  for field in credential password; do
    if v="$(op read --no-newline "op://$OP_VAULT/$1/$field" 2>/dev/null)" && [[ -n "$v" ]]; then
      printf '%s' "$v"
      return 0
    fi
  done
  return 1
}

# True only when the vault was listed successfully and has no item titled $1.
# A failed listing (network, rate limit) is not proof the item is gone.
op_item_missing() {
  local titles
  titles="$(op item list --vault "$OP_VAULT" --format json 2>/dev/null)" || return 1
  ! jq -e --arg t "$1" 'any(.[]; .title == $t)' <<<"$titles" >/dev/null
}

# Store the OpenRouter key in an environment.d file, mode 600. The systemd
# --user manager reads environment.d when it starts and on daemon-reload, and
# gives the variables to every service it starts after that. ~/.bashrc sources
# the same file, so interactive shells get the key too.
write_openrouter_env() {
  mkdir -p "${OPENROUTER_ENV%/*}"
  ( umask 077; printf 'OPENROUTER_API_KEY=%s\n' "$1" >"$OPENROUTER_ENV" )
  # The umask applies only when the file is new.
  chmod 600 "$OPENROUTER_ENV"
  bashrc_once '60-openrouter.conf' <<'OR_BASHRC'
# OPENROUTER_API_KEY for opencode and other OpenRouter clients. systemd --user
# services read the same file through environment.d.
if [ -r "${XDG_CONFIG_HOME:-$HOME/.config}/environment.d/60-openrouter.conf" ]; then
  set -a; . "${XDG_CONFIG_HOME:-$HOME/.config}/environment.d/60-openrouter.conf"; set +a
fi
OR_BASHRC
  export OPENROUTER_API_KEY="$1"
  systemctl --user daemon-reload
  OR_WRITTEN=1
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
# ripgrep: opencode's search tools need rg, and without one on PATH opencode
# downloads its own copy on first use.
"${APT[@]}" install -y --no-install-recommends \
  ca-certificates curl wget git gnupg jq python3 unzip bubblewrap ripgrep

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
# 4c. opencode
# ---------------------------------------------------------------------------
# The installer always puts the binary in ~/.opencode/bin. --no-modify-path
# stops it from editing ~/.bashrc; the symlink below puts opencode in
# ~/.local/bin next to codex and claude. On a re-run the installer exits early
# when the installed version is the latest release.
#   https://opencode.ai/docs/
log "Installing opencode"

# Without --version the installer asks api.github.com for the latest release.
# That API allows 60 unauthenticated requests per hour per IP, so it fails
# behind a busy NAT. The /releases/latest redirect has no such limit; the T3
# Code step uses it for the same reason. With --version the installer only
# checks that the tag exists.
OC_ARGS=(--no-modify-path)
OC_TAG="$(curl -fsSLI -o /dev/null -w '%{url_effective}' \
  https://github.com/anomalyco/opencode/releases/latest || true)"
OC_TAG="${OC_TAG##*/}"
[[ "$OC_TAG" == v* ]] && OC_ARGS+=(--version "${OC_TAG#v}")

if [[ -x "$OPENCODE_BIN" ]]; then
  info "found opencode $("$OPENCODE_BIN" --version 2>&1 | head -1) — upgrading in place"
  run_installer bash https://opencode.ai/install "${OC_ARGS[@]}" \
    || warn "the opencode installer failed; keeping the installed version"
else
  run_installer bash https://opencode.ai/install "${OC_ARGS[@]}" \
    || die "the opencode installer failed"
fi
[[ -x "$OPENCODE_BIN" ]] || die "opencode not found at $OPENCODE_BIN after install"

# A symlink, not a copy: opencode's self-update replaces the file in
# ~/.opencode/bin. An existing opencode that is not ours is left alone.
if [[ ! -e "$LOCAL_BIN/opencode" || -L "$LOCAL_BIN/opencode" ]]; then
  ln -sfn "$OPENCODE_BIN" "$LOCAL_BIN/opencode"
else
  warn "$LOCAL_BIN/opencode is not a symlink to $OPENCODE_BIN; leaving it alone"
fi
hash -r

# opencode's self-update runs the same installer without --no-modify-path, and
# the installer then appends this exact line to ~/.bashrc unless the line is
# already there. Write it here, so that all ~/.bashrc edits come from this
# script.
# shellcheck disable=SC2016 # $PATH must expand in ~/.bashrc, not here
printf 'export PATH=%s:$PATH\n' "${OPENCODE_BIN%/*}" \
  | bashrc_once "export PATH=${OPENCODE_BIN%/*}:"

# OpenRouter can scan each request for prompt injection. When a guardrail on
# the API key sets that scan to "block", OpenRouter rejects a request with HTTP
# 403 if any message matches one of its published regexes. Two matches come
# from text that opencode writes itself. This plugin rewrites that text in
# requests to OpenRouter only. The header comment of the plugin has the details.
# opencode loads *.js and *.ts from this directory. The temporary name has
# neither suffix, so opencode never loads a partly written file.
mkdir -p "${OPENCODE_PLUGIN%/*}"
OC_PLUGIN_TMP="$(mktemp "${OPENCODE_PLUGIN%/*}/.openrouter-guardrail.XXXXXX")"
cat >"$OC_PLUGIN_TMP" <<'OC_PLUGIN_EOF'
// opencode plugin installed by aviggiano/setup (setup.sh). A re-run of setup.sh
// replaces this file, so do not edit it here.
//
// OpenRouter can scan each request for prompt injection. When a guardrail on
// the API key sets that scan to "block", OpenRouter rejects the request with
// HTTP 403 "Request blocked: prompt injection patterns detected" if any message
// matches one of its published regexes:
//   https://openrouter.ai/docs/guides/features/guardrails/prompt-injection
//
// Two matches come from text that opencode writes itself:
//
// 1. System prompt. Models without a prompt of their own (Qwen, DeepSeek, GLM,
//    Mistral, Trinity and others) get default.txt or trinity.txt. Both have an
//    example in which a line ends with "]" and the next line starts with
//    "user:". That matches role_delimiter_injection:
//      /\][^\S\n]*\n\s*\[?(system|assistant|user)\]?:/i
//    Fix: put "." after that "]".
//
// 2. Compaction. opencode sends the history as one user message, and labels
//    each entry "[User]: " or "[Assistant]: ". "[Assistant]" matches
//    bracketed_role_spoofing, so compaction fails for every model:
//      /\[\s*(System\s*Message|System|Assistant|Internal)\s*\]/i
//    A "[User]: " label after a line that ends with "]" also matches
//    role_delimiter_injection.
//    Fix: change the labels to "[User turn]: " and "[Assistant turn]: ".
//    No plugin hook sees this text, so the fix goes in the fetch function of
//    the openrouter provider.
//
// The plugin does not change tool output, file content or user text, and a
// match there still gets a 403. To stop all of these, set prompt injection
// detection to "flag" on every guardrail that covers the key. Do not use
// "redact": it changes the prompt and gives no error.
//
// Each hook catches its own errors, because opencode fails the request when a
// hook throws. If a later opencode release changes these internals, the
// plugin does nothing and the 403 comes back.

const ROLE_DELIMITER = /\](?=[^\S\n]*\n\s*\[?(?:system|assistant|user)\]?:)/gi
const COMPACTION_LABEL = /^\[(User|Assistant)\]: /gm
// The first marker is from opencode's compaction prompt. A plugin that
// replaces that prompt makes opencode use the second one.
const COMPACTION_MARKERS = ["<conversation>", "The following is the conversation history:"]
const WRAPPED = Symbol.for("aviggiano/setup openrouter-guardrail")

const isOpenRouter = (model) =>
  model?.providerID === "openrouter" || model?.api?.npm === "@openrouter/ai-sdk-provider"

// Rewrite the compaction message in a chat completions request body. Return
// the body unchanged when there is nothing to rewrite.
const fixCompaction = (body) => {
  if (typeof body !== "string" || !COMPACTION_MARKERS.some((m) => body.includes(m))) return body
  const data = JSON.parse(body)
  if (!Array.isArray(data?.messages)) return body
  let changed = false
  const fix = (text) => {
    if (!COMPACTION_MARKERS.some((m) => text.includes(m))) return text
    const next = text.replace(COMPACTION_LABEL, "[$1 turn]: ")
    if (next !== text) changed = true
    return next
  }
  for (const message of data.messages) {
    if (message?.role !== "user") continue
    if (typeof message.content === "string") {
      message.content = fix(message.content)
    } else if (Array.isArray(message.content)) {
      for (const part of message.content) {
        if (typeof part?.text === "string") part.text = fix(part.text)
      }
    }
  }
  return changed ? JSON.stringify(data) : body
}

export const OpenRouterGuardrail = async () => ({
  // opencode runs this hook before it creates providers, so the fetch function
  // set here is the one the openrouter provider uses.
  config: async (cfg) => {
    try {
      // With no key and no provider.openrouter entry, OpenRouter is not in use.
      // An entry made here would make opencode list OpenRouter models anyway.
      if (!cfg.provider?.openrouter && !process.env.OPENROUTER_API_KEY) return
      cfg.provider ??= {}
      cfg.provider.openrouter ??= {}
      const options = (cfg.provider.openrouter.options ??= {})
      if (options.fetch?.[WRAPPED]) return
      const next = typeof options.fetch === "function" ? options.fetch : globalThis.fetch
      const wrapped = (url, init) => {
        try {
          if (typeof init?.body === "string") init = { ...init, body: fixCompaction(init.body) }
        } catch {
          // Send the request unchanged.
        }
        return next(url, init)
      }
      wrapped[WRAPPED] = true
      options.fetch = wrapped
    } catch {
      // Leave the config unchanged.
    }
  },
  "experimental.chat.system.transform": async (input, output) => {
    try {
      if (!isOpenRouter(input?.model)) return
      // Change the array in place. opencode reads its own reference to it, not
      // a new array assigned to output.system.
      for (let i = 0; i < output.system.length; i++) {
        const text = output.system[i]
        if (typeof text === "string") output.system[i] = text.replace(ROLE_DELIMITER, "].")
      }
    } catch {
      // Send the system prompt unchanged.
    }
  },
})
OC_PLUGIN_EOF
chmod 644 "$OC_PLUGIN_TMP"
mv -f "$OC_PLUGIN_TMP" "$OPENCODE_PLUGIN"
info "wrote $OPENCODE_PLUGIN"
info "opencode $("$OPENCODE_BIN" --version 2>&1 | head -1)"

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
  # Only write it when absent — never clobber a real login. The umask is scoped
  # to a subshell (as in write_op_env): it used to leak into the rest of the
  # script, which is the only reason config.toml came out 0600 — and only on
  # boxes that happened to have no auth.json yet. chmod below replaces that.
  if [[ ! -s "$CODEX_HOME/auth.json" ]]; then
    ( umask 077; printf '{\n  "auth_mode": "apikey",\n  "OPENAI_API_KEY": "codex-lb"\n}\n' >"$CODEX_HOME/auth.json" )
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

# config.toml carries MCP server definitions, and those routinely hold API keys
# in their env blocks. Set the mode explicitly rather than depending on the
# umask in effect, which is what decided this before.
chmod 600 "$CODEX_HOME/config.toml"
[[ -f "$CODEX_HOME/config.toml.bak" ]] && chmod 600 "$CODEX_HOME/config.toml.bak"

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
# 9b. T3 Code — install and background service   (default on: T3CODE=0 skips)
# ---------------------------------------------------------------------------
# From the GitHub release tarball, not `npx t3`. The npm package keeps its
# binary in a per-platform optional dependency that bundles node-pty, and npm
# compiles node-pty on install — without make and g++ that fails silently, and
# t3 then reports "no build for linux-x64". The tarball ships node-pty prebuilt,
# so this needs neither Node nor a compiler.
#
# `t3 service install` copies the release into ~/.t3/runtime/versions/<v>/ and
# writes a systemd --user unit (t3code.service). From then on `t3 update`
# upgrades both, so a re-run upgrades through it instead of downloading again.
# `t3 service uninstall` removes the unit but keeps ~/.t3/runtime, so "the
# binary is there" and "the service is installed" are checked separately.
# The server listens on 127.0.0.1:3773 only; `t3 pair` handles remote access.
t3_bin() {
  local v
  v="$(jq -r '.activeVersion // empty' "$T3_STATE" 2>/dev/null)" || return 1
  [[ -n "$v" && -x "$T3_HOME/runtime/versions/$v/t3" ]] || return 1
  printf '%s\n' "$T3_HOME/runtime/versions/$v/t3"
}

# Tailscale is not installed by this script; when the box is already on a
# tailnet, T3 Code is paired through it at the end (step 12).
tailscale_up() {
  command -v tailscale >/dev/null 2>&1 \
    && [[ "$(tailscale status --json 2>/dev/null | jq -r '.BackendState // empty')" == "Running" ]]
}

if [[ "$T3CODE" == "1" ]]; then

  log "Installing T3 Code (https://github.com/pingdotgg/t3code)"

  # The prebuilt Linux binary needs libatomic.so.1, which minimal Debian/Ubuntu
  # installs may lack. Install it before invoking t3, including on upgrades.
  "${APT[@]}" install -y --no-install-recommends libatomic1

  if T3_BIN="$(t3_bin)" && [[ -f "$UNIT_DIR/t3code.service" ]]; then
    info "found $("$T3_BIN" --version 2>&1 | head -1) — upgrading in place"
    # -y: without it update asks before restarting the service, and there is
    # no one to answer here.
    "$T3_BIN" update -y </dev/null || warn "t3 update failed; keeping the installed version"
  elif T3_BIN="$(t3_bin)"; then
    info "found $("$T3_BIN" --version 2>&1 | head -1) without its service — reinstalling it"
    "$T3_BIN" service install </dev/null || die "t3 service install failed"
    "$T3_BIN" update -y </dev/null || warn "t3 update failed; keeping the installed version"
  else
    case "$(dpkg --print-architecture)" in
      amd64) T3_ARCH=x64 ;;
      arm64) T3_ARCH=arm64 ;;
      *)     T3_ARCH="" ;;
    esac
    if [[ -z "$T3_ARCH" ]]; then
      warn "no T3 Code build for $(dpkg --print-architecture); skipping"
    else
      # /releases/latest redirects to the newest stable tag. Going by the
      # redirect instead of api.github.com avoids its unauthenticated rate limit.
      T3_TAG="$(curl -fsSLI -o /dev/null -w '%{url_effective}' \
        https://github.com/pingdotgg/t3code/releases/latest)"
      T3_TAG="${T3_TAG##*/}"
      [[ "$T3_TAG" == v* ]] || die "could not resolve the latest T3 Code release"
      T3_TARBALL="t3-${T3_TAG#v}-linux-${T3_ARCH}.tar.gz"
      T3_URL="https://github.com/pingdotgg/t3code/releases/download/$T3_TAG"
      curl -fsSL "$T3_URL/$T3_TARBALL" -o "$TMPWORK/$T3_TARBALL" \
        || die "could not download $T3_URL/$T3_TARBALL"
      curl -fsSL "$T3_URL/SHA256SUMS" -o "$TMPWORK/t3.SHA256SUMS" \
        || die "could not download $T3_URL/SHA256SUMS"
      ( cd "$TMPWORK" && grep -F " $T3_TARBALL" t3.SHA256SUMS | sha256sum -c --quiet - ) \
        || die "checksum mismatch for $T3_TARBALL"
      tar -xzf "$TMPWORK/$T3_TARBALL" -C "$TMPWORK"
      "$TMPWORK/${T3_TARBALL%.tar.gz}/t3" service install </dev/null \
        || die "t3 service install failed"
    fi
  fi

  # Nothing puts t3 on PATH: the service runs the versioned binary directly.
  # This shim follows activeVersion, so it keeps working after `t3 update`. An
  # existing t3 that is not ours (an npm launcher, say) is left alone.
  T3_SHIM="$LOCAL_BIN/t3"
  if [[ ! -e "$T3_SHIM" ]] || grep -qsF 'aviggiano/setup' "$T3_SHIM"; then
    cat >"$T3_SHIM" <<'T3_SHIM_EOF'
#!/bin/sh
# t3 launcher — added by aviggiano/setup. Runs the version the service is on.
state="$HOME/.t3/runtime/service-state.json"
v="$(jq -r '.activeVersion // empty' "$state" 2>/dev/null)"
[ -n "$v" ] || { echo "t3: no installed version in $state" >&2; exit 1; }
exec "$HOME/.t3/runtime/versions/$v/t3" "$@"
T3_SHIM_EOF
    chmod 755 "$T3_SHIM"
  fi

  # T3 Code ships with its OpenCode provider off: on first start it writes
  # providers.opencode.enabled=false to settings.json by itself, so an existing
  # false there is not a choice someone made. With the provider off, T3 Code
  # neither probes for the opencode binary nor lists its models. The server
  # reads this file when it starts and finds opencode through the PATH of a
  # login shell, which step 4c set up. jq writes to a temporary file first, so
  # a failed run cannot leave a truncated settings.json behind.
  if [[ -x "$OPENCODE_BIN" ]]; then
    mkdir -p "${T3_SETTINGS%/*}"
    [[ -s "$T3_SETTINGS" ]] || printf '{}\n' >"$T3_SETTINGS"
    if [[ "$(jq -r '.providers.opencode.enabled // false' "$T3_SETTINGS")" == "true" ]]; then
      info "OpenCode is already enabled in T3 Code ($T3_SETTINGS)"
    else
      jq '.providers.opencode.enabled = true' "$T3_SETTINGS" >"$TMPWORK/t3-settings.json" \
        && mv -f "$TMPWORK/t3-settings.json" "$T3_SETTINGS" \
        && T3_SETTINGS_CHANGED=1 \
        && info "enabled OpenCode in T3 Code ($T3_SETTINGS)" \
        || warn "could not enable OpenCode in $T3_SETTINGS; turn it on under Settings > Providers"
    fi
  fi

  if T3_BIN="$(t3_bin)"; then
    info "$("$T3_BIN" --version 2>&1 | head -1), service $(systemctl --user is-active t3code.service || true)"
  else
    warn "T3 Code is not installed — see the output above"
  fi

else

  log "T3 Code"
  info "T3CODE=0 — skipping"

fi

# ---------------------------------------------------------------------------
# 9c. hob — install and background service   (default on: HOB=0 skips)
# ---------------------------------------------------------------------------
# hob's installer (get.hob.dev/install) downloads a binary and runs it, and the
# binary copies itself to ~/.local/bin/hob. The installer only compares the
# file size with the manifest; the manifest also carries a sha256, so this
# reads the manifest itself and checks that instead. The hash comes from the
# same host as the binary: it catches a corrupt download, not a compromised
# host. A re-run downloads only when the manifest names a newer version.
#
# The service runs `hob --headless` in the foreground; --detach is for a shell,
# where it forks away from the terminal. Desktop connections are pinned to
# localhost below (2.4.1's default, made explicit so a changed default cannot
# expose it); the desktop app reaches it through an SSH tunnel it opens itself.
#   https://hob.dev
if [[ "$HOB" == "1" ]]; then

  log "Installing hob (https://hob.dev)"

  # The Linux build needs GTK 3, NSS and ALSA even when headless, and stops to
  # ask to install them when they are missing. libasound2 became libasound2t64
  # in Ubuntu 24.04 and Debian 13.
  HOB_ALSA=libasound2t64
  apt-cache show "$HOB_ALSA" >/dev/null 2>&1 || HOB_ALSA=libasound2
  "${APT[@]}" install -y --no-install-recommends libgtk-3-0 libnss3 "$HOB_ALSA"

  case "$(dpkg --print-architecture)" in
    amd64) HOB_ARCH=amd64 ;;
    arm64) HOB_ARCH=arm64 ;;
    *)     HOB_ARCH="" ;;
  esac
  if [[ -z "$HOB_ARCH" ]]; then
    warn "no hob build for $(dpkg --print-architecture); skipping"
  elif ! curl -fsSL https://get.hob.dev/updates/stable/manifest.json -o "$TMPWORK/hob-manifest.json"; then
    warn "could not download the hob release manifest; skipping"
  else
    HOB_VERSION="$(jq -r '.version // empty' "$TMPWORK/hob-manifest.json")"
    HOB_URL="$(jq -r --arg p "linux-$HOB_ARCH" '.platforms[$p].url // empty' "$TMPWORK/hob-manifest.json")"
    HOB_SHA="$(jq -r --arg p "linux-$HOB_ARCH" '.platforms[$p].sha256 // empty' "$TMPWORK/hob-manifest.json")"
    [[ -n "$HOB_VERSION" && -n "$HOB_URL" && -n "$HOB_SHA" ]] \
      || die "the hob manifest has no linux-$HOB_ARCH release"
    HOB_INSTALLED="$("$HOB_BIN" app version 2>/dev/null </dev/null || true)"
    # Replace only a missing or older hob: a beta build, or a stable release
    # the manifest has since rolled back, is left alone rather than downgraded.
    if [[ -n "$HOB_INSTALLED" ]] \
      && [[ "$(printf '%s\n%s\n' "$HOB_VERSION" "$HOB_INSTALLED" | sort -V | tail -n 1)" == "$HOB_INSTALLED" ]]; then
      info "hob $HOB_INSTALLED is current (stable: $HOB_VERSION)"
    else
      info "installing hob $HOB_VERSION${HOB_INSTALLED:+ (replacing $HOB_INSTALLED)}"
      curl -fsSL "$HOB_URL" -o "$TMPWORK/hob" || die "could not download $HOB_URL"
      echo "$HOB_SHA  $TMPWORK/hob" | sha256sum -c --quiet - \
        || die "checksum mismatch for $HOB_URL"
      chmod +x "$TMPWORK/hob"
      "$TMPWORK/hob" </dev/null || die "the hob installer failed"
      [[ -x "$HOB_BIN" ]] || die "hob not found at $HOB_BIN after install"
      HOB_UPGRADED=1
    fi
  fi

  if [[ -x "$HOB_BIN" ]]; then
    # Rewritten every run, so a change here reaches existing boxes; restarted
    # only when the unit or the binary changed.
    cat >"$TMPWORK/hob.service" <<'HOB_UNIT_EOF'
[Unit]
Description=hob headless host (added by aviggiano/setup)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=%h/.local/bin/hob --headless
Restart=on-failure
RestartSec=5
Environment=PATH=%h/.local/bin:/usr/local/bin:/usr/bin:/bin

[Install]
WantedBy=default.target
HOB_UNIT_EOF
    if ! cmp -s "$TMPWORK/hob.service" "$HOB_UNIT"; then
      mv -f "$TMPWORK/hob.service" "$HOB_UNIT"
      systemctl --user daemon-reload
      HOB_UPGRADED=1
    fi
    systemctl --user enable hob.service >/dev/null 2>&1
    # A Host started by hand (`hob --headless --detach`) keeps running outside
    # the unit, and a second `hob --headless` only attaches to it, so the unit
    # would never own the Host. Stop it first — unless this script runs inside
    # it, in which case that would kill this run.
    if ! systemctl --user is-active --quiet hob.service; then
      HOB_STRAY=()
      for pid in $(pgrep -u "$USER" -x hob || true); do
        grep -qs '/hob\.service$' "/proc/$pid/cgroup" || HOB_STRAY+=("$pid")
      done
      if (( ${#HOB_STRAY[@]} )); then
        HOB_ANCESTOR=0 pid=$$
        while [[ "$pid" -gt 1 ]]; do
          [[ " ${HOB_STRAY[*]} " == *" $pid "* ]] && HOB_ANCESTOR=1
          pid="$(ps -o ppid= -p "$pid" | tr -d ' ')"
        done
        if [[ $HOB_ANCESTOR -eq 1 ]]; then
          warn "hob is already running outside systemd, and this script runs inside it."
          warn "after this finishes, quit that hob and run: systemctl --user start hob"
        else
          info "stopping a hob started outside systemd (pid ${HOB_STRAY[*]})"
          kill -TERM "${HOB_STRAY[@]}" 2>/dev/null || true
          for _ in $(seq 1 15); do
            pgrep -u "$USER" -x hob >/dev/null || break
            sleep 1
          done
        fi
      fi
    fi
    # A terminal or agent inside hob is a child of the service, so restarting
    # it from there would kill this script mid-run (T3 Code has the same rule).
    if [[ "${HOB_UPGRADED:-0}" == 1 ]] && grep -qs '/hob\.service$' /proc/self/cgroup; then
      info "running inside hob — not restarting it; when this finishes, run:"
      info "    systemctl --user restart hob"
    elif [[ "${HOB_UPGRADED:-0}" == 1 ]]; then
      systemctl --user restart hob.service
    else
      systemctl --user start hob.service
    fi
    # The Host takes a few seconds to answer after a (re)start.
    for _ in $(seq 1 30); do
      "$HOB_BIN" connection desktop </dev/null >/dev/null 2>&1 && break
      sleep 1
    done
    "$HOB_BIN" connection desktop localhost </dev/null >/dev/null 2>&1 \
      || warn "could not restrict hob desktop connections to localhost; check: hob connection desktop"
    info "hob $("$HOB_BIN" app version 2>/dev/null </dev/null), service $(systemctl --user is-active hob.service || true), $("$HOB_BIN" connection desktop </dev/null 2>/dev/null | head -n 1)"
  fi

else

  log "hob"
  info "HOB=0 — skipping"

fi

# codex-lb being *on the box* is not the same as CODEX_LB=1: step 7 skips
# rather than uninstalls, so a machine provisioned by an earlier run still has
# the service, still has config.toml pointing at it, and still has the
# placeholder auth.json — and `codex login` there would replace that
# placeholder and break the provider. Step 11 splits the same three states.
codex_lb_on_box() {
  [[ "$CODEX_LB" == "1" ]] || [[ -f "$UNIT" ]] || command -v codex-lb >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# 10. Interactive sign-in (gh, Codex, then Claude Code) — in series, last
# ---------------------------------------------------------------------------
# Everything above is unattended. These are not: each prints a code or URL,
# waits for you to finish in a browser elsewhere, and must not overlap with the
# others or you end up pasting the wrong code into the wrong page. So they run
# one at a time, at the very end, and a failure stops the script rather than
# falling through to a summary that claims success.
log "Interactive sign-in"

CLAUDE_CREDS="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.credentials.json"

# --- 10d. 1Password service account ---------------------------------------
# Runs before the terminal gate on purpose: unlike gh and Claude Code this has
# no browser round trip, and when a provisioner has already put the token in the
# environment it needs no terminal at all. That is the path that makes an
# unattended `OP_SERVICE_ACCOUNT_TOKEN=... bash setup.sh` work end to end.
if [[ "$OP_AUTH" == "skip" ]]; then
  info "op: OP_AUTH=skip — not configuring 1Password"
elif [[ -n "${OP_SERVICE_ACCOUNT_TOKEN:-}" && "$OP_AUTH" != "prompt" ]]; then
  # A token in the environment wins over the stored one, so a provisioner can
  # rotate it. ~/.bashrc sources op.env, so it is often the same token.
  # shellcheck source=/dev/null
  if [[ "$( [[ -r "$OP_ENV" ]] && . "$OP_ENV"; printf '%s' "${OP_SERVICE_ACCOUNT_TOKEN:-}")" == "$OP_SERVICE_ACCOUNT_TOKEN" && -s "$OP_ENV" ]]; then
    info "op: token already present ($OP_ENV)"
  else
    write_op_env "$OP_SERVICE_ACCOUNT_TOKEN"
    info "op: token taken from the environment, stored in $OP_ENV (mode 600)"
  fi
elif [[ -s "$OP_ENV" && "$OP_AUTH" != "prompt" ]]; then
  # shellcheck source=/dev/null
  . "$OP_ENV"
  info "op: token already present ($OP_ENV)"
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

# Resolve the vault here, in this shell, so the lookups below share it.
OP_READY=0
if [[ "$OP_AUTH" != "skip" && -n "${OP_SERVICE_ACCOUNT_TOKEN:-}" ]] && op_vault; then
  OP_READY=1
  info "op: reading secrets from vault '$OP_VAULT'"
fi

# --- 10e. OpenRouter API key ----------------------------------------------
# Read from the 1Password item OPENROUTER_API_KEY. A value that differs from
# the stored one replaces it, so rotating the key is: change it in the vault,
# re-run this script. Before the terminal gate for the same reason as 10d.
OR_STORED=""
[[ -r "$OPENROUTER_ENV" ]] \
  && OR_STORED="$(sed -n 's/^OPENROUTER_API_KEY=//p' "$OPENROUTER_ENV" | tail -n 1)"
if [[ $OP_READY -eq 0 ]]; then
  if [[ -n "$OR_STORED" ]]; then
    info "openrouter: no 1Password access; kept the stored key ($OPENROUTER_ENV)"
  else
    info "openrouter: no 1Password access — OPENROUTER_API_KEY not configured"
  fi
elif OR_KEY="$(op_secret OPENROUTER_API_KEY)"; then
  if [[ "$OR_KEY" == "$OR_STORED" ]]; then
    info "openrouter: key already stored ($OPENROUTER_ENV)"
  elif check_openrouter_key "$OR_KEY"; then
    write_openrouter_env "$OR_KEY"
    info "openrouter: key read from 1Password, stored in $OPENROUTER_ENV (mode 600)"
  else
    warn "openrouter: the key in 1Password (OPENROUTER_API_KEY) was not stored"
  fi
  unset OR_KEY
elif op_item_missing OPENROUTER_API_KEY; then
  # The vault answered and the item is gone: 1Password is the source of truth,
  # so deleting the item revokes this machine's copy too.
  if [[ -n "$OR_STORED" ]]; then
    rm -f "$OPENROUTER_ENV"
    unset OPENROUTER_API_KEY
    systemctl --user daemon-reload
    OR_WRITTEN=1
    warn "openrouter: no item OPENROUTER_API_KEY in vault '$OP_VAULT' — removed the stored key"
  else
    warn "openrouter: no item OPENROUTER_API_KEY in vault '$OP_VAULT'"
  fi
else
  warn "openrouter: could not read OPENROUTER_API_KEY from 1Password${OR_STORED:+; kept the stored key}"
fi

# --- 10f. hob license -----------------------------------------------------
# Read from the 1Password item HOB_LICENSE_KEY, only when hob has no active
# license, and handed over on stdin so it never reaches argv. hob keeps the
# activation itself, and the running service picks it up without a restart.
if [[ "$HOB" == "1" && -x "$HOB_BIN" ]]; then
  if "$HOB_BIN" app license status </dev/null 2>/dev/null | grep -q '^License: active'; then
    info "hob: license already active"
  elif [[ $OP_READY -eq 0 ]]; then
    info "hob: no 1Password access — license not activated (read-only mode)"
  elif HOB_KEY="$(op_secret HOB_LICENSE_KEY)"; then
    if printf '%s' "$HOB_KEY" | "$HOB_BIN" app license activate --key-stdin >/dev/null; then
      info "hob: license activated from 1Password"
    else
      warn "hob: license activation failed; check HOB_LICENSE_KEY in vault '$OP_VAULT'"
    fi
    unset HOB_KEY
  else
    warn "hob: no item HOB_LICENSE_KEY in vault '$OP_VAULT' — hob stays read-only"
  fi
fi

# A running service keeps the environment it started with and reads
# settings.json once at startup. Do not restart T3 Code from here: this script
# can itself run in a T3 Code terminal.
if [[ "${OR_WRITTEN:-0}" == 1 || "${T3_SETTINGS_CHANGED:-0}" == 1 ]] \
  && systemctl --user is-active --quiet t3code.service; then
  info "T3 Code was already running; restart it to pick up the OpenRouter key"
  info "and the OpenCode provider setting:"
  info "    systemctl --user restart t3code"
fi
# hob's agents (opencode among them) inherit hob's environment, which it got
# when step 9c started it — before the key above was written. Restart it so
# they see the new key, unless this script runs inside hob.
if [[ "${OR_WRITTEN:-0}" == 1 ]] && systemctl --user is-active --quiet hob.service; then
  if grep -qs '/hob\.service$' /proc/self/cgroup; then
    info "hob is running this script; restart it afterwards to pick up the OpenRouter key:"
    info "    systemctl --user restart hob"
  else
    systemctl --user restart hob.service
    info "restarted hob so its agents pick up the OpenRouter key"
  fi
fi

if [[ $HAVE_TTY -eq 0 ]]; then
  info "no terminal — skipping sign-in (provisioning above is complete)"
  info "run these yourself, one at a time:"
  info "    GH_BROWSER=true gh auth login --hostname github.com --git-protocol https --web"
  codex_lb_on_box \
    || info "    codex login --device-auth"
  info "    claude          # complete /login, then /exit"
else

  # --- 10a. GitHub -------------------------------------------------------
  if [[ "$GH_AUTH" == "skip" ]]; then
    info "gh: GH_AUTH=skip — not signing in"
  elif gh auth status --hostname github.com >/dev/null 2>&1; then
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

  # --- 10b. Codex --------------------------------------------------------
  # Only when codex-lb is off. With CODEX_LB=1 the ChatGPT accounts are added in
  # the codex-lb dashboard and ~/.codex/auth.json is the placeholder written in
  # step 8 — a real login here would replace it and break the provider.
  #
  # --device-auth is the device-code flow. The default `codex login` opens a
  # browser against a localhost callback, which a headless box cannot serve; the
  # device flow prints a URL and a code instead and polls until you approve.
  if [[ "$CODEX_LB" == "1" ]]; then
    info "codex: CODEX_LB=1 — accounts live in the codex-lb dashboard, not in ~/.codex/auth.json"
  elif codex_lb_on_box; then
    info "codex: codex-lb left in place by an earlier run — accounts live in its dashboard, not in ~/.codex/auth.json"
  elif [[ "$CODEX_AUTH" == "skip" ]]; then
    info "codex: CODEX_AUTH=skip — not signing in"
  elif codex login status >/dev/null 2>&1; then
    info "codex: $(codex login status 2>&1 | head -1)"
  else
    cat <<'CODEX_EOF'

    codex will print a URL and a one-time code. On your laptop, open the URL,
    paste the code, and approve. codex finishes on its own — nothing is typed
    back into this terminal.

CODEX_EOF
    # </dev/tty for the same reason as gh above: under `curl | bash` our stdin
    # is this script's source.
    codex login --device-auth </dev/tty \
      || die "codex login did not complete. Re-run the script when ready; it is idempotent."
    codex login status >/dev/null 2>&1 \
      || die "codex reports no credentials after login"
    info "codex: $(codex login status 2>&1 | head -1)"
    # The app-server (step 9) was bootstrapped before these credentials existed.
    # Restart it so remote-control sessions pick them up.
    codex app-server daemon restart </dev/null >/dev/null 2>&1 \
      || warn "could not restart the app-server daemon; run 'codex app-server daemon restart' yourself"
  fi

  # --- 10c. Claude Code --------------------------------------------------
  # Note: Claude Code has no device-code flow. `claude` runs a browser OAuth
  # round trip against a localhost callback; over SSH that callback is usually
  # unreachable, so the browser shows a code you paste back at the CLI's
  # "Paste code here if prompted" prompt. That is the paste step here.
  #   https://code.claude.com/docs/en/authentication
  if [[ "$CLAUDE_AUTH" == "skip" ]]; then
    info "claude: CLAUDE_AUTH=skip — not signing in"
  elif [[ -s "$CLAUDE_CREDS" ]]; then
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

# The codex-lb lines only make sense when it is actually on the box — but being
# on the box is not the same as CODEX_LB=1. Step 7 skips rather than uninstalls,
# so a machine provisioned before this run still has the service and still has
# config.toml pointing at it; saying "not installed" there would be a lie, and
# "run codex login" would be wrong advice. Three states, not two.
if [[ "$CODEX_LB" == "1" ]]; then
  LB_STATE=installed
elif [[ -f "$UNIT" ]] || command -v codex-lb >/dev/null 2>&1; then
  LB_STATE=preserved
else
  LB_STATE=absent
fi

if [[ "$LB_STATE" == "absent" ]]; then
  LB_STATUS="not installed (CODEX_LB=1 to enable)"
  # Step 10b already did this when a terminal was available, so do not tell
  # someone to run a command they have just finished running.
  if codex login status >/dev/null 2>&1; then
    LB_FIRST_STEP="1. Codex is signed in to your ChatGPT account —
           $(codex login status 2>&1 | head -1)"
  else
    LB_FIRST_STEP="1. Sign Codex in to your ChatGPT account:
           codex login --device-auth"
  fi
  LB_SERVICES=""
else
  # `is-active` exits nonzero for anything but "active" — a status result, not a
  # command failure. It still prints the state, so keep the text and drop the
  # exit code; without the `|| true` set -e would abort the whole summary at
  # exactly the moment the summary is most worth having.
  LB_VERSION="$(uv tool list 2>/dev/null | awk '/^codex-lb /{print $2}')"
  LB_STATUS="${LB_VERSION:-unknown}  ($(systemctl --user is-active codex-lb.service || true))"
  if [[ "$LB_STATE" == "preserved" ]]; then
    LB_STATUS="$LB_STATUS  — left in place; this run had CODEX_LB=0"
  fi
  LB_FIRST_STEP="1. Open the codex-lb dashboard and add your ChatGPT account(s):
           http://127.0.0.1:${CODEX_LB_PORT}
       Set a dashboard password (and TOTP) there before exposing the port."
  LB_SERVICES="   systemctl --user status codex-lb        # load balancer
       systemctl --user restart codex-lb
       journalctl --user -u codex-lb -f

    "
fi

# is-active: same `|| true` as codex-lb above.
if T3_BIN="$(t3_bin)"; then
  T3_STATUS="$("$T3_BIN" --version 2>&1 | head -1)  ($(systemctl --user is-active t3code.service || true))"
  if tailscale_up; then
    T3_PAIR_STEP="
    3. Pair the T3 Code app: the tailnet pairing URL is printed below (valid
       ${T3_PAIR_TTL}). Mint a new one with:
           t3 pair --tailscale
"
  else
    T3_PAIR_STEP="
    3. Pair a browser with T3 Code (the server only listens on 127.0.0.1:3773).
       Forward the port and open the printed URL on your laptop:
           ssh -N -L 13773:127.0.0.1:3773 <this host>
           t3 pair                 # then swap localhost:3773 for localhost:13773
       With Tailscale up on this box, re-running setup prints a tailnet URL.
"
  fi
  T3_SERVICES="   t3 service status                       # T3 Code
       systemctl --user restart t3code
       tail -f ~/.t3/userdata/logs/boot-service.log

    "
elif [[ "$T3CODE" == "1" ]]; then
  T3_STATUS="NOT installed — see the T3 Code step above"
  T3_PAIR_STEP="" T3_SERVICES=""
else
  T3_STATUS="skipped (T3CODE=0)"
  T3_PAIR_STEP="" T3_SERVICES=""
fi

if [[ "$HOB" == "1" && -x "$HOB_BIN" ]]; then
  HOB_STATUS="$("$HOB_BIN" app version 2>/dev/null </dev/null)  ($(systemctl --user is-active hob.service || true), license $("$HOB_BIN" app license status </dev/null 2>/dev/null | sed -n 's/^License: //p'))"
  HOB_PAIR_STEP="
    6. Connect the hob desktop app (2.4.1+): computer button at the left of the
       titlebar → Connect to a new computer → SSH machine → this host. If it
       asks for approval here:
           hob connection pending
           hob connection approve <id>     # once the code matches
"
  HOB_SERVICES="   systemctl --user status hob             # hob
       systemctl --user restart hob
       journalctl --user -u hob -f

    "
elif [[ "$HOB" == "1" ]]; then
  HOB_STATUS="NOT installed — see the hob step above"
  HOB_PAIR_STEP="" HOB_SERVICES=""
else
  HOB_STATUS="skipped (HOB=0)"
  HOB_PAIR_STEP="" HOB_SERVICES=""
fi

cat <<SUMMARY
    gh          $(gh --version | head -1)  ($(gh auth status --hostname github.com >/dev/null 2>&1 && echo 'signed in' || echo 'NOT signed in'))
    codex       $(codex --version 2>&1 | head -1)  ($(
                  if codex_lb_on_box; then echo 'via codex-lb'
                  elif codex login status >/dev/null 2>&1; then echo 'signed in'
                  else echo 'NOT signed in'; fi))
    claude      $(claude --version 2>&1 | head -1)  ($([[ -s "$CLAUDE_CREDS" ]] && echo 'signed in' || echo 'NOT signed in'))
    opencode    $("$OPENCODE_BIN" --version 2>&1 </dev/null | head -1)  ($([[ -s "$OPENROUTER_ENV" ]] && echo 'OpenRouter key stored' || echo 'no OpenRouter key — add OPENROUTER_API_KEY to 1Password and re-run'))
    op          $(op --version 2>&1 | head -1)  ($([[ -s "$OP_ENV" ]] && echo 'token stored' || echo 'no token — set OP_SERVICE_ACCOUNT_TOKEN and re-run'))
    hob         ${HOB_STATUS}
    t3          ${T3_STATUS}
    codex-lb    ${LB_STATUS}
    app-server  $(codex app-server daemon version 2>/dev/null | (jq -r '.status // "unknown"' 2>/dev/null || cat))

    Next steps
    ----------
    ${LB_FIRST_STEP}

    2. Pair the Codex app with this machine (prints a short-lived code):
           codex remote-control pair
${T3_PAIR_STEP}
    4. Verify Codex and opencode work:
           codex doctor
           codex exec 'say hi'
           opencode models openrouter | head
           opencode run -m openrouter/<model from the list> 'say hi'
       If OpenRouter answers 403 "Request blocked: prompt injection patterns
       detected", set prompt injection detection to "flag" on the guardrails
       that cover the key. The opencode plugin only fixes opencode's own text.

    5. See which credentials this machine can reach. Setup itself reads
       OPENROUTER_API_KEY and HOB_LICENSE_KEY; anything else in the vault is
       one op read away:
           op vault list
           op item list --vault <vault>
           op read "op://<vault>/<item>/<field>"
${HOB_PAIR_STEP}
    Managing the services
    ---------------------
    ${LB_SERVICES}${T3_SERVICES}${HOB_SERVICES}   codex app-server daemon version         # app-server
       codex app-server daemon restart
       tail -f ~/.codex/app-server-control/app-server.log

    Note: 'codex', 'claude', 'opencode', 'uv' and 't3' live in ~/.local/bin — run 'exec \$SHELL -l'
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

# ---------------------------------------------------------------------------
# 12. T3 Code pairing URL (when Tailscale is up)
# ---------------------------------------------------------------------------
# Last, so the URL is the final thing on screen and its token is not spent
# waiting on the interactive sign-ins. `t3 pair --tailscale` points Tailscale
# Serve (tailnet only, never Funnel) at 127.0.0.1:3773; that mapping persists,
# and `tailscale serve --https=443 off` removes it.
if [[ "$T3CODE" == "1" ]] && T3_BIN="$(t3_bin)" && tailscale_up; then
  log "Pairing T3 Code over Tailscale"

  # Changing serve config needs root or the operator role. Grant the role once
  # instead of running t3 under sudo, which would put its state in root's home.
  if [[ "$(tailscale debug prefs 2>/dev/null | jq -r '.OperatorUser // empty')" != "$USER" ]]; then
    "${SUDO[@]}" tailscale set --operator="$USER" \
      && info "made $USER a Tailscale operator (needed for tailscale serve)" \
      || warn "could not make $USER a Tailscale operator; run: sudo tailscale set --operator=$USER"
  fi

  "$T3_BIN" pair --tailscale --ttl "$T3_PAIR_TTL" </dev/null \
    || warn "t3 pair --tailscale failed. HTTPS certificates must be enabled for the tailnet
      (admin console → DNS → HTTPS Certificates); then run: t3 pair --tailscale"
fi
