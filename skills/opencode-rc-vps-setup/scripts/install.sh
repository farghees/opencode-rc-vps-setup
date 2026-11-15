#!/usr/bin/env bash
# Install OpenCode web (`opencode web`) as a systemd user service running in a detached tmux session.
# Idempotent: safe to re-run. Overwrites the unit and wrapper (keeping a timestamped backup if they changed).
# Never overwrites credentials or provider API keys that already exist in rc.env.
#
# Usage:
#   install.sh [--port N] [--bind IP] [--username NAME] [--workdir DIR]
#              [--tailscale-serve] [--serve-port N]
#     --port             port to listen on (default 4096)
#     --bind             IPv4 address to listen on (default: `tailscale ip -4`).
#                        0.0.0.0 and public addresses are refused. Loopback is allowed but local only.
#     --username         basic-auth user name, written only if rc.env has none (default admin)
#     --workdir          directory OpenCode starts in (default $HOME)
#     --tailscale-serve  also publish the service at a tailnet-only HTTPS URL with
#                        `tailscale serve` (off by default). Needs a one-time admin-console enable.
#     --serve-port       HTTPS port for Tailscale Serve (default 8443; 443 is often taken)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATES="$SCRIPT_DIR/../templates"
CONF_DIR="$HOME/.config/opencode"
ENV_FILE="$CONF_DIR/rc.env"
WRAPPER="$CONF_DIR/rc-run.sh"
JSONC="$CONF_DIR/opencode.jsonc"
UNIT_DIR="$HOME/.config/systemd/user"
UNIT_NAME="opencode-rc.service"
UNIT="$UNIT_DIR/$UNIT_NAME"
TMUX_SOCKET="opencode-rc"
ME="${USER:-$(id -un)}"

PORT=4096
BIND=""
USERNAME_NEW="admin"
WORKDIR="$HOME"

say()  { printf '\n==> %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }

TS_SERVE=0
SERVE_PORT=8443

while [ $# -gt 0 ]; do
  case "$1" in
    --port)     PORT="${2:?--port needs a value}"; shift 2 ;;
    --bind)     BIND="${2:?--bind needs a value}"; shift 2 ;;
    --username) USERNAME_NEW="${2:?--username needs a value}"; shift 2 ;;
    --workdir)  WORKDIR="${2:?--workdir needs a value}"; shift 2 ;;
    --tailscale-serve) TS_SERVE=1; shift ;;
    --serve-port)      SERVE_PORT="${2:?--serve-port needs a value}"; shift 2 ;;
    -h|--help)  usage; exit 0 ;;
    *) die "unknown option: $1 (see --help)" ;;
  esac
done

# ---------- 1. Prerequisites and input checks ----------
say "Checking prerequisites"
[ "$(uname -s)" = Linux ] || die "Linux with systemd is required."
command -v systemctl >/dev/null 2>&1 || die "systemd not found."
systemctl --user show-environment >/dev/null 2>&1 \
  || die "systemd user manager not reachable. Over SSH try: export XDG_RUNTIME_DIR=/run/user/\$(id -u)"
command -v tmux    >/dev/null 2>&1 || die "tmux is not installed (e.g. sudo apt install tmux) and re-run."
command -v openssl >/dev/null 2>&1 || die "openssl is needed to generate the password."
command -v curl    >/dev/null 2>&1 || die "curl is needed for the checks."
command -v python3 >/dev/null 2>&1 || die "python3 is needed to validate the bind address."
TMUX_BIN="$(readlink -f "$(command -v tmux)")"
if [ "$TS_SERVE" = 1 ]; then
  command -v tailscale >/dev/null 2>&1 || die "--tailscale-serve needs the tailscale CLI on this host."
fi

# The unit's PATH and non-interactive shells do not reliably find opencode, so use an absolute path.
OPENCODE_BIN=""
for cand in "$HOME/.opencode/bin/opencode" "$(command -v opencode 2>/dev/null || true)"; do
  if [ -n "$cand" ] && [ -x "$cand" ]; then OPENCODE_BIN="$(readlink -f "$cand")"; break; fi
done
[ -n "$OPENCODE_BIN" ] || die "opencode not found. Install it (https://opencode.ai) or put it at \$HOME/.opencode/bin/opencode."
"$OPENCODE_BIN" web --help >/dev/null 2>&1 || die "this OpenCode has no 'web' subcommand. Update OpenCode and re-run."

if [ -z "$BIND" ]; then
  command -v tailscale >/dev/null 2>&1 || die "no --bind given and tailscale is not installed. Pass --bind <private IP>."
  BIND="$({ tailscale ip -4 2>/dev/null || true; } | head -n 1)"
  [ -n "$BIND" ] || die "tailscale has no IPv4 address yet. Run 'tailscale up' or pass --bind <IP>."
fi

BIND_CLASS="$(python3 - "$BIND" <<'PY' 2>/dev/null || echo invalid
import ipaddress, sys
try:
    a = ipaddress.ip_address(sys.argv[1])
except ValueError:
    print("invalid"); sys.exit(0)
if a.version != 4:
    print("ipv6")
elif a.is_unspecified:
    print("wildcard")
elif a.is_loopback:
    print("loopback")
elif a.is_private or a in ipaddress.ip_network("100.64.0.0/10"):
    print("private")
else:
    print("public")
PY
)"
case "$BIND_CLASS" in
  private)  echo "bind:   $BIND (private or Tailscale address)" ;;
  loopback) warn "bind $BIND is loopback: OpenCode will only be reachable from this machine." ;;
  wildcard) die "refusing to bind $BIND (all interfaces). OpenCode gives shell access; bind to the Tailscale IP." ;;
  public)   die "refusing to bind public address $BIND. Use a Tailscale or other private address." ;;
  ipv6)     die "IPv6 bind addresses are not supported by these templates; use an IPv4 address." ;;
  *)        die "invalid --bind address: $BIND" ;;
esac

case "$PORT" in ''|*[!0-9]*) die "--port must be a number" ;; esac
[ "$PORT" -ge 1024 ] && [ "$PORT" -le 65535 ] || die "--port must be between 1024 and 65535"
case "$SERVE_PORT" in ''|*[!0-9]*) die "--serve-port must be a number" ;; esac
[ "$SERVE_PORT" -ge 1 ] && [ "$SERVE_PORT" -le 65535 ] || die "--serve-port must be between 1 and 65535"
[ "$SERVE_PORT" != "$PORT" ] || die "--serve-port must differ from --port"
[[ "$USERNAME_NEW" =~ ^[A-Za-z0-9._-]+$ ]] || die "--username may only contain letters, digits, '.', '_' and '-'."
[ -d "$WORKDIR" ] || die "--workdir does not exist: $WORKDIR"
WORKDIR="$(cd "$WORKDIR" && pwd)"
case "$TMUX_BIN$OPENCODE_BIN$WORKDIR$BIND$PORT$ENV_FILE$WRAPPER" in
  *'|'*) die "paths must not contain '|'" ;;
esac

echo "tmux:     $TMUX_BIN"
echo "opencode: $OPENCODE_BIN ($("$OPENCODE_BIN" --version 2>/dev/null || echo unknown version))"
echo "bind:     $BIND:$PORT"
echo "dir:      $WORKDIR"
if [ "$TS_SERVE" = 1 ]; then echo "serve:    tailnet-only HTTPS on port $SERVE_PORT (Tailscale Serve)"; fi

if systemctl --user is-active --quiet "$UNIT_NAME"; then
  echo "port:     $UNIT_NAME is already running and will be restarted"
else
  python3 - "$BIND" "$PORT" <<'PY' || die "cannot bind $BIND:$PORT (port in use, or the address is not assigned yet)."
import socket, sys
s = socket.socket()
try:
    s.bind((sys.argv[1], int(sys.argv[2])))
except OSError:
    sys.exit(1)
finally:
    s.close()
PY
  echo "port:     $BIND:$PORT is free"
fi

# ---------- 2. Linger (starts the user manager at boot, without a login) ----------
say "Checking linger"
if [ "$(loginctl show-user "$ME" -p Linger --value 2>/dev/null || echo no)" = yes ]; then
  echo "linger: already enabled for $ME"
else
  sudo loginctl enable-linger "$ME" || die "could not enable linger (needs sudo). Run: sudo loginctl enable-linger $ME"
  echo "linger: enabled for $ME"
fi

# ---------- 3. rc.env: create, or add only missing keys ----------
say "Preparing $ENV_FILE"
mkdir -p "$CONF_DIR"
( umask 077; touch "$ENV_FILE" )
chmod 600 "$ENV_FILE"

has_key() { grep -Eq "^[[:space:]]*$1=" "$ENV_FILE"; }
get_key() { sed -n "s/^[[:space:]]*$1=//p" "$ENV_FILE" | tail -n 1 | tr -d "\"'"; }

if has_key OPENCODE_SERVER_USERNAME; then
  echo "username: kept the existing value in rc.env"
else
  printf 'OPENCODE_SERVER_USERNAME=%s\n' "$USERNAME_NEW" >> "$ENV_FILE"
  echo "username: $USERNAME_NEW (written to rc.env)"
fi

if has_key OPENCODE_SERVER_PASSWORD && [ -n "$(get_key OPENCODE_SERVER_PASSWORD)" ]; then
  echo "password: kept the existing value in rc.env"
else
  printf 'OPENCODE_SERVER_PASSWORD=%s\n' "$(openssl rand -hex 24)" >> "$ENV_FILE"
  echo "password: generated and written to rc.env (not printed)"
fi

if grep -Eq '^[[:space:]]*[A-Z0-9_]*API_KEY=.+' "$ENV_FILE"; then
  echo "provider key: an *_API_KEY entry is present in rc.env"
else
  warn "no *_API_KEY entry in rc.env. Add your provider key (e.g. OPENROUTER_API_KEY=...) to $ENV_FILE, then: systemctl --user restart $UNIT_NAME"
fi
[ -f "$JSONC" ] || warn "$JSONC does not exist. Create it to choose the model (see SKILL.md)."

# ---------- 4. Write wrapper and unit ----------
say "Writing wrapper and unit"
render() {
  sed -e "s|__TMUX__|$TMUX_BIN|g" \
      -e "s|__OPENCODE__|$OPENCODE_BIN|g" \
      -e "s|__ENV_FILE__|$ENV_FILE|g" \
      -e "s|__WORKDIR__|$WORKDIR|g" \
      -e "s|__BIND__|$BIND|g" \
      -e "s|__PORT__|$PORT|g" \
      -e "s|__WRAPPER__|$WRAPPER|g" \
      "$1"
}
TMP_W="$(mktemp)"
TMP_U="$(mktemp)"
trap 'rm -f "$TMP_W" "$TMP_U"' EXIT
render "$TEMPLATES/rc-run.sh" > "$TMP_W"
render "$TEMPLATES/opencode-rc.service" > "$TMP_U"

install_if_changed() { # <new file> <destination> <mode>
  mkdir -p "$(dirname "$2")"
  if [ -f "$2" ] && ! cmp -s "$1" "$2"; then
    cp "$2" "$2.bak-$(date +%Y%m%d%H%M%S)"
    echo "existing $(basename "$2") differed; backed up to $2.bak-*"
  fi
  install -m "$3" "$1" "$2"
}
install_if_changed "$TMP_W" "$WRAPPER" 0700
install_if_changed "$TMP_U" "$UNIT" 0644
echo "wrote: $WRAPPER"
echo "wrote: $UNIT"

# ---------- 5. Enable and start ----------
say "Enabling and (re)starting $UNIT_NAME"
systemctl --user daemon-reload
systemctl --user enable "$UNIT_NAME"
systemctl --user restart "$UNIT_NAME"

# ---------- 6. Checks ----------
say "Checking the service"
URL="http://$BIND:$PORT/"
U="$(get_key OPENCODE_SERVER_USERNAME)"
P="$(get_key OPENCODE_SERVER_PASSWORD)"
http_code() { curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$@" 2>/dev/null || true; }

CODE=000
for _ in $(seq 1 45); do
  CODE="$(http_code "$URL")"
  [ "$CODE" != 000 ] && break
  sleep 2
done

if [ "$CODE" = 401 ]; then
  echo "without credentials: HTTP 401 (ok)"
else
  warn "without credentials: HTTP $CODE (expected 401). Check: systemctl --user status $UNIT_NAME ; tmux -L $TMUX_SOCKET capture-pane -p -t $TMUX_SOCKET | tail -n 20"
fi

# Credentials go through a curl config on a file descriptor, so they never appear in the process list.
AUTH_CODE="$(http_code -K <(printf 'user = "%s:%s"\n' "$U" "$P") "$URL")"
if [ "$AUTH_CODE" = 200 ]; then
  echo "with credentials:    HTTP 200 (ok)"
else
  warn "with credentials: HTTP $AUTH_CODE (expected 200). If you edited rc.env, restart the unit so it re-reads the file."
fi

if [ "$BIND" != 127.0.0.1 ]; then
  LOOP_CODE="$(http_code "http://127.0.0.1:$PORT/")"
  if [ "$LOOP_CODE" = 000 ]; then
    echo "127.0.0.1:$PORT: connection refused (ok: not listening on loopback)"
  else
    warn "127.0.0.1:$PORT answered HTTP $LOOP_CODE. Check the bind address in $UNIT."
  fi
fi

if systemctl --user is-active --quiet "$UNIT_NAME"; then
  echo "unit: active"
else
  warn "unit is not active. Check: journalctl --user -u $UNIT_NAME -n 50"
fi

# ---------- 7. Optional: tailnet-only HTTPS URL via Tailscale Serve ----------
# Serve is tailnet only. Never use `tailscale funnel` here: it publishes the UI to the internet.
# Problems in this step are reported as warnings; the service above is already running.
SERVE_URL=""
SERVE_TARGET="http://$BIND:$PORT"

# Prints one word: none (no handler on the port), same (already proxies to this service),
# other (the port serves something else), or error (status could not be read).
serve_state() {
  local json
  json="$(timeout 20 tailscale serve status --json 2>/dev/null)" || { echo error; return 0; }
  SERVE_JSON="$json" python3 - "$SERVE_PORT" "$SERVE_TARGET" <<'PY' || echo error
import json, os, sys
port, target = sys.argv[1], sys.argv[2]
try:
    cfg = json.loads(os.environ.get("SERVE_JSON") or "{}")
except ValueError:
    print("error"); sys.exit(0)
proxies = []
for key, site in (cfg.get("Web") or {}).items():
    if key.rsplit(":", 1)[-1] == port:
        for handler in ((site or {}).get("Handlers") or {}).values():
            proxies.append((handler or {}).get("Proxy", ""))
if not proxies:
    print("other" if (cfg.get("TCP") or {}).get(port) else "none")
elif all(p == target for p in proxies):
    print("same")
else:
    print("other")
PY
}

# Creates the handler. Returns 1 (with a message) when Serve is not enabled, blocks, or fails.
serve_apply() {
  local out rc enable_url
  out="$(mktemp)"
  # Cache sudo first, so the 60s timeout cannot cut off a password prompt.
  sudo -v 2>/dev/null || true
  set +e
  timeout -k 5 60 sudo tailscale serve --bg --https="$SERVE_PORT" "$SERVE_TARGET" >"$out" 2>&1
  rc=$?
  set -e
  if grep -q "Serve is not enabled" "$out"; then
    enable_url="$(grep -oE 'https://login\.tailscale\.com/[^[:space:]]+' "$out" | head -n 1 || true)"
    warn "Tailscale Serve is not enabled on this tailnet. This is a one-time admin-console step."
    if [ -n "$enable_url" ]; then echo "  Enable it at: $enable_url" >&2; fi
    echo "  Then re-run install.sh with --tailscale-serve. The service keeps running meanwhile." >&2
    rm -f "$out"; return 1
  fi
  if [ "$rc" = 124 ]; then
    warn "tailscale serve did not finish within 60s and was stopped. It may be waiting for Serve to be enabled. Check: tailscale serve status"
  elif [ "$rc" != 0 ]; then
    warn "tailscale serve failed (exit $rc): $(tail -n 3 "$out" | tr '\n' ' ')"
  fi
  rm -f "$out"
  [ "$rc" = 0 ]
}

# Confirms the handler is tailnet only and that HTTPS answers 401 without and 200 with credentials.
# Sets SERVE_URL only when all of that passes. Tailscale certificates can take a minute to appear.
serve_verify() {
  local status_txt line dns_name url code auth_code
  status_txt="$(timeout 20 tailscale serve status 2>/dev/null || true)"
  line="$(printf '%s\n' "$status_txt" | grep -F ":$SERVE_PORT" || true)"
  case "$line" in
    *"(tailnet only)"*) echo "serve status: port $SERVE_PORT is (tailnet only)" ;;
    *) warn "tailscale serve status does not show port $SERVE_PORT as (tailnet only). No URL published. Check: tailscale serve status"; return 1 ;;
  esac

  dns_name="$(timeout 20 tailscale status --json 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get("Self",{}).get("DNSName","").rstrip("."))' 2>/dev/null)" || dns_name=""
  if [ -z "$dns_name" ]; then warn "could not read this machine's Tailscale DNS name. Check: tailscale status"; return 1; fi
  url="https://$dns_name:$SERVE_PORT/"

  code=000
  for _ in $(seq 1 20); do
    code="$(http_code "$url")"
    [ "$code" != 000 ] && break
    sleep 3
  done
  if [ "$code" != 401 ]; then
    warn "$url without credentials: HTTP $code (expected 401). The certificate may still be provisioning; re-run in a minute."
    return 1
  fi
  echo "https without credentials: HTTP 401 (ok)"

  auth_code="$(http_code -K <(printf 'user = "%s:%s"\n' "$U" "$P") "$url")"
  if [ "$auth_code" != 200 ]; then
    warn "https with credentials: HTTP $auth_code (expected 200). If you edited rc.env, restart the unit."
    return 1
  fi
  echo "https with credentials:    HTTP 200 (ok)"
  SERVE_URL="$url"
}

if [ "$TS_SERVE" = 1 ]; then
  say "Tailscale Serve (tailnet-only HTTPS on port $SERVE_PORT)"
  SERVE_READY=0
  case "$(serve_state)" in
    same)  echo "serve: port $SERVE_PORT already proxies to $SERVE_TARGET (nothing to change)"; SERVE_READY=1 ;;
    none)  if serve_apply; then SERVE_READY=1; fi ;;
    other) warn "port $SERVE_PORT already has a Serve handler or listener for something else. Not overwriting it. Re-run with another --serve-port." ;;
    *)     warn "could not read Tailscale Serve status. Not changing Serve. Check: tailscale serve status" ;;
  esac
  if [ "$SERVE_READY" = 1 ]; then serve_verify || true; fi
fi

say "Done"
cat <<EOF
  Open:           $URL
  Username:       $U
  View password:  grep OPENCODE_SERVER_PASSWORD $ENV_FILE
  Read-only view: tmux -L $TMUX_SOCKET attach -r -t $TMUX_SOCKET   (detach: Ctrl-b, then d)
  Logs:           journalctl --user -u $UNIT_NAME -n 50
  Keys and model: $ENV_FILE and $JSONC, then: systemctl --user restart $UNIT_NAME
  Linger check:   loginctl show-user $ME -p Linger
The web UI is plain HTTP. Keep it on the private address only; it gives shell access.
EOF
if [ -n "$SERVE_URL" ]; then
  echo "  HTTPS (tailnet only): $SERVE_URL"
  echo "  Phone tip: open that URL in the browser and choose 'Add to Home Screen'."
elif [ "$TS_SERVE" = 1 ]; then
  echo "  HTTPS: not published (see the warnings above). Fix them and re-run with --tailscale-serve."
fi
