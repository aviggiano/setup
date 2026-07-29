#!/usr/bin/env bash
#
# setup.sh — provision a Debian/Ubuntu box with:
#   * system packages brought up to date (apt update && apt full-upgrade)
#   * GitHub CLI (gh)          via GitHub's official apt repository
#   * OpenAI Codex CLI         via https://chatgpt.com/codex/install.sh
#   * codex-lb                 via `uv tool install` + a systemd --user service
#   * ~/.codex/config.toml     pointed at the local codex-lb endpoint
#   * Codex app-server daemon  bootstrapped with remote control enabled
#
# Idempotent: safe to re-run to upgrade an existing install.
#
# Usage:
#   ./setup.sh
#
# Environment overrides:
#   CODEX_MODEL       model written to config.toml        (default: gpt-5.6-sol)
#   CODEX_EFFORT      model_reasoning_effort              (default: xhigh)
#   CODEX_LB_HOST     interface codex-lb binds to         (default: 0.0.0.0)
#   CODEX_LB_PORT     port codex-lb listens on            (default: 2455)
#   SKIP_APT_UPGRADE  set to 1 to skip the apt upgrade step
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

LOCAL_BIN="$HOME/.local/bin"
CODEX_HOME="$HOME/.codex"
UNIT_DIR="$HOME/.config/systemd/user"
UNIT="$UNIT_DIR/codex-lb.service"

log()  { printf '\n\033[1;34m==>\033[0m \033[1m%s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[1;33m    warning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m==> error:\033[0m %s\n' "$*" >&2; exit 1; }

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

sudo -v || die "could not acquire sudo credentials"

export DEBIAN_FRONTEND=noninteractive
export PATH="$LOCAL_BIN:$PATH"
mkdir -p "$LOCAL_BIN" "$CODEX_HOME" "$UNIT_DIR"

# ---------------------------------------------------------------------------
# 1. System packages
# ---------------------------------------------------------------------------
log "Updating system packages"

sudo apt-get update -y

if [[ "$SKIP_APT_UPGRADE" != "1" ]]; then
  sudo apt-get full-upgrade -y
else
  info "SKIP_APT_UPGRADE=1 — skipping full-upgrade"
fi

# bubblewrap is the sandbox backend Codex expects on PATH; without it the
# app-server falls back to its bundled copy and logs an error on every start.
sudo apt-get install -y --no-install-recommends \
  ca-certificates curl wget git gnupg jq python3 unzip bubblewrap

sudo apt-get autoremove -y

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
    | sudo tee "$GH_KEYRING" >/dev/null
  sudo chmod go+r "$GH_KEYRING"
  info "installed apt keyring"
fi

GH_REPO="deb [arch=$(dpkg --print-architecture) signed-by=$GH_KEYRING] https://cli.github.com/packages stable main"
if [[ ! -f "$GH_LIST" ]] || ! grep -qF "$GH_REPO" "$GH_LIST"; then
  echo "$GH_REPO" | sudo tee "$GH_LIST" >/dev/null
  sudo apt-get update -y
  info "added cli.github.com apt repository"
fi

sudo apt-get install -y gh
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
  codex update || warn "codex update failed; falling back to the install script"
fi

if ! command -v codex >/dev/null 2>&1; then
  curl -fsSL https://chatgpt.com/codex/install.sh | sh
fi

hash -r
command -v codex >/dev/null || die "codex not on PATH after install; open a new shell and re-run"
info "$(codex --version 2>&1 | head -1)"

# ---------------------------------------------------------------------------
# 5. uv + codex-lb
# ---------------------------------------------------------------------------
log "Installing uv"

if command -v uv >/dev/null 2>&1; then
  info "$(uv --version)"
  uv self update 2>/dev/null || info "uv is externally managed; skipping self-update"
else
  curl -LsSf https://astral.sh/uv/install.sh | sh
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
  sudo loginctl enable-linger "$USER"
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

LB_READY=0
for _ in $(seq 1 60); do
  if curl -fsS -o /dev/null --max-time 3 "http://127.0.0.1:${CODEX_LB_PORT}/"; then
    LB_READY=1
    break
  fi
  sleep 2
done

if [[ "$LB_READY" == "1" ]]; then
  info "responding on http://127.0.0.1:${CODEX_LB_PORT}/"
else
  warn "no response after ~120s. Check: journalctl --user -u codex-lb -n 50 --no-pager"
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

if codex app-server daemon bootstrap --remote-control; then
  info "app-server bootstrapped with remote control enabled"
else
  warn "bootstrap failed — retrying as a plain restart"
  codex app-server daemon restart || warn "could not start the app-server daemon"
  codex app-server daemon enable-remote-control || warn "could not enable remote control"
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
# 10. Summary
# ---------------------------------------------------------------------------
log "Done"

cat <<SUMMARY
    gh          $(gh --version | head -1)
    codex       $(codex --version 2>&1 | head -1)
    codex-lb    $(uv tool list | grep '^codex-lb ' | awk '{print $2}')  ($(systemctl --user is-active codex-lb.service))
    app-server  $(codex app-server daemon version 2>/dev/null | (jq -r '.status // "unknown"' 2>/dev/null || cat))

    Next steps
    ----------
    1. Open the codex-lb dashboard and add your ChatGPT account(s):
           http://127.0.0.1:${CODEX_LB_PORT}
       Set a dashboard password (and TOTP) there before exposing the port.

    2. Authenticate the GitHub CLI, if you have not already:
           gh auth login

    3. Pair the Codex app with this machine (prints a short-lived code):
           codex remote-control pair

    4. Verify Codex is routing through codex-lb:
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

    Note: 'codex' and 'uv' live in ~/.local/bin — run 'exec \$SHELL -l' or open a
    new shell if this was a first-time install.
SUMMARY
