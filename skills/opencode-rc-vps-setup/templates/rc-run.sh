#!/usr/bin/env bash
# Runs OpenCode web bound to a single address and restarts it if it exits.
# Placeholders (__X__) are filled in by scripts/install.sh.
#   __ENV_FILE__  credentials and provider API keys (chmod 600), read at start
#   __WORKDIR__   directory OpenCode starts in
#   __OPENCODE__  absolute path to the opencode binary
#   __BIND__      address to listen on (never 0.0.0.0)
#   __PORT__      port to listen on
set -a
. "__ENV_FILE__"
set +a

# Refuse to start without basic-auth credentials: a web UI with shell access must never run open.
: "${OPENCODE_SERVER_USERNAME:?OPENCODE_SERVER_USERNAME is not set in __ENV_FILE__; refusing to start}"
: "${OPENCODE_SERVER_PASSWORD:?OPENCODE_SERVER_PASSWORD is not set in __ENV_FILE__; refusing to start}"

cd "__WORKDIR__" || exit 1
while true; do
  "__OPENCODE__" web --hostname "__BIND__" --port "__PORT__"
  echo "opencode exited ($?), restarting in 5s"
  sleep 5
done
