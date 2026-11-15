#!/usr/bin/env bash
# Remove the OpenCode web service installed by install.sh.
# Leaves OpenCode itself, opencode.jsonc and the rest of ~/.config/opencode untouched.
# rc.env (password and provider keys) is kept unless --purge is given.
#
# Usage: uninstall.sh [--purge] [--disable-linger]
#   --purge           also delete rc.env (credentials and provider API keys)
#   --disable-linger  also turn off linger for this user (needs sudo; affects ALL user services)
set -euo pipefail

UNIT_NAME="opencode-rc.service"
UNIT="$HOME/.config/systemd/user/$UNIT_NAME"
WRAPPER="$HOME/.config/opencode/rc-run.sh"
ENV_FILE="$HOME/.config/opencode/rc.env"
ME="${USER:-$(id -un)}"
PURGE=0
DISABLE_LINGER=0

usage() { sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --purge)           PURGE=1; shift ;;
    --disable-linger)  DISABLE_LINGER=1; shift ;;
    -h|--help)         usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

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
