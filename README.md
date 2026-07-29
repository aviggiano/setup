# setup

A single idempotent script that provisions a Debian/Ubuntu machine for
[Codex](https://developers.openai.com/codex/) running behind
[codex-lb](https://github.com/Soju06/codex-lb).

On a fresh machine:

```bash
curl -fsSL https://raw.githubusercontent.com/aviggiano/setup/main/setup.sh | bash
```

Or clone it first if you'd rather read the script before running it — it does
`apt full-upgrade`, installs a systemd unit, and edits `~/.codex/config.toml`:

```bash
git clone https://github.com/aviggiano/setup
cd setup
./setup.sh
```

Re-run it any time — it upgrades in place rather than reinstalling.

Environment overrides go on `bash`, not `curl`:

```bash
curl -fsSL https://raw.githubusercontent.com/aviggiano/setup/main/setup.sh \
  | CODEX_LB_HOST=127.0.0.1 SKIP_APT_UPGRADE=1 bash
```

The script needs `sudo` for the apt steps and asks for your password up front.
That means it needs a terminal: piping it into a non-interactive context (CI,
`ssh host < script`) fails at the preflight check rather than half-running.
`curl | sudo bash` is **not** a fix — codex-lb is a `systemd --user` service and
must be installed as your own user.

## What it does

| Step | Detail |
| --- | --- |
| System packages | `apt update` + `apt full-upgrade`, plus `curl`, `git`, `jq`, `python3`, `bubblewrap` (Codex's sandbox backend) |
| `gh` | GitHub CLI from GitHub's official apt repository, so `apt upgrade` keeps it current |
| `codex` | Codex CLI via `https://chatgpt.com/codex/install.sh` (or `codex update` if already present) |
| `codex-lb` | Installed with `uv tool install codex-lb`, run as a `systemd --user` service with lingering enabled so it starts at boot and survives logout |
| Codex config | `~/.codex/config.toml` patched to route through codex-lb; other sections (plugins, marketplaces, MCP servers, project trust) are preserved and the previous file is saved as `config.toml.bak` |
| App-server | `codex app-server daemon bootstrap --remote-control`, so the Codex app can drive this machine over the control socket |

## Configuration

Override with environment variables:

| Variable | Default | Purpose |
| --- | --- | --- |
| `CODEX_MODEL` | `gpt-5.6-sol` | `model` in `config.toml` |
| `CODEX_EFFORT` | `xhigh` | `model_reasoning_effort` |
| `CODEX_LB_HOST` | `0.0.0.0` | Interface codex-lb binds to |
| `CODEX_LB_PORT` | `2455` | Port codex-lb listens on |
| `SKIP_APT_UPGRADE` | `0` | Set to `1` to skip `apt full-upgrade` |

```bash
CODEX_LB_HOST=127.0.0.1 SKIP_APT_UPGRADE=1 ./setup.sh
```

> **Security:** the default `CODEX_LB_HOST=0.0.0.0` exposes the codex-lb
> dashboard — which holds your ChatGPT account tokens — to anything that can
> reach the machine. Set a dashboard password and TOTP in the UI, or bind to
> `127.0.0.1` and reach it over an SSH tunnel.

## After the script

1. Add your ChatGPT account(s) at <http://127.0.0.1:2455>.
2. `gh auth login`
3. `codex remote-control pair` — prints a short-lived code to link the Codex app.
4. `codex doctor` to confirm Codex is routing through codex-lb.

## Operating

```bash
systemctl --user status codex-lb          # load balancer
journalctl --user -u codex-lb -f

codex app-server daemon version           # app-server
codex app-server daemon restart
tail -f ~/.codex/app-server-control/app-server.log
```

## Notes

Codex's `requires_openai_auth = true` makes it insist on `~/.codex/auth.json`
even though codex-lb supplies the real credentials, so the script seeds a
placeholder API key there — only when the file is absent, never overwriting a
real login.

The dotfiles and per-tool install scripts that used to live here are still in
the git history.
