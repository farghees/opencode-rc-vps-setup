#!/usr/bin/env bash
# Remove the OpenCode web service installed by install.sh.
# Leaves OpenCode itself, opencode.jsonc and the rest of ~/.config/opencode untouched.
# rc.env (password and provider keys) is kept unless --purge is given.
# If a Tailscale Serve handler on --serve-port proxies to this service, that handler is removed.
# Other Serve handlers are never touched.
#
# Usage: uninstall.sh [--purge] [--disable-linger] [--serve-port N]
#   --purge           also delete rc.env (credentials and provider API keys)
#   --disable-linger  also turn off linger for this user (needs sudo; affects ALL user services)
#   --serve-port N    Tailscale Serve HTTPS port to check (default 8443)
set -euo pipefail

UNIT_NAME="opencode-rc.service"
UNIT="$HOME/.config/systemd/user/$UNIT_NAME"
WRAPPER="$HOME/.config/opencode/rc-run.sh"
ENV_FILE="$HOME/.config/opencode/rc.env"
ME="${USER:-$(id -un)}"
PURGE=0
DISABLE_LINGER=0
SERVE_PORT=8443

usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --purge)           PURGE=1; shift ;;
    --disable-linger)  DISABLE_LINGER=1; shift ;;
    --serve-port)      SERVE_PORT="${2:?--serve-port needs a value}"; shift 2 ;;
    -h|--help)         usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

case "$SERVE_PORT" in ''|*[!0-9]*) echo "--serve-port must be a number" >&2; exit 2 ;; esac
[ "$SERVE_PORT" -ge 1 ] && [ "$SERVE_PORT" -le 65535 ] || { echo "--serve-port must be between 1 and 65535" >&2; exit 2; }

# Prints "<bind> <port>" from the installed wrapper, or nothing if there is no wrapper.
read_target() {
  [ -f "$WRAPPER" ] || return 0
  sed -n 's/.*--hostname "\([^"]*\)" --port "\([^"]*\)".*/\1 \2/p' "$WRAPPER" | head -n 1
}

# Removes the Serve handler on SERVE_PORT only if every handler there proxies to this service.
remove_serve_handler() {
  command -v tailscale >/dev/null 2>&1 || return 0
  local target bind port json state
  target="$(read_target)"
  if [ -z "$target" ]; then
    echo "Serve: no installed wrapper to read the bind address from; leaving Serve alone."
    return 0
  fi
  bind="${target% *}"
  port="${target#* }"

  json="$(timeout 20 tailscale serve status --json 2>/dev/null)" || { echo "Serve: could not read status; leaving it alone."; return 0; }
  state="$(SERVE_JSON="$json" python3 - "$SERVE_PORT" "http://$bind:$port" <<'PY' || echo error
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
    print("absent")
elif all(p == target for p in proxies):
    print("ours")
else:
    print("foreign")
PY
)"

  case "$state" in
    ours)
      echo "==> Removing Tailscale Serve handler on port $SERVE_PORT (it proxies to $bind:$port)"
      sudo -v 2>/dev/null || true
      if timeout -k 5 60 sudo tailscale serve --https="$SERVE_PORT" off; then
        echo "Serve: handler on port $SERVE_PORT removed."
      else
        echo "WARNING: could not remove the Serve handler. Check: tailscale serve status" >&2
      fi
      ;;
    foreign) echo "Serve: port $SERVE_PORT proxies to something else; leaving it alone." ;;
    absent)  echo "Serve: no handler on port $SERVE_PORT for this service." ;;
    *)       echo "Serve: could not parse status; leaving it alone." ;;
  esac
}

remove_serve_handler

echo "==> Stopping and disabling $UNIT_NAME"
systemctl --user disable --now "$UNIT_NAME" 2>/dev/null || true
tmux -L opencode-rc kill-server 2>/dev/null || true

echo "==> Removing unit and wrapper"
rm -f "$UNIT" "$WRAPPER"
systemctl --user daemon-reload 2>/dev/null || true
systemctl --user reset-failed "$UNIT_NAME" 2>/dev/null || true

if [ "$PURGE" = 1 ]; then
  echo "==> Deleting $ENV_FILE (credentials and provider keys)"
  rm -f "$ENV_FILE"
else
  echo "Kept $ENV_FILE (password and provider keys). Use --purge to delete it."
fi

if [ "$DISABLE_LINGER" = 1 ]; then
  echo "==> Disabling linger for $ME"
  sudo loginctl disable-linger "$ME"
else
  echo "Linger left enabled (other user services may rely on it). Use --disable-linger to turn it off."
fi

echo "Done. Verify: systemctl --user status $UNIT_NAME  (should report 'could not be found')"
