#!/bin/sh
# Starts Newt once the setup page has saved the site credentials, and restarts
# it whenever they change. Newt gets its own copy of the file, so anything it
# writes back doesn't look like a new configuration.
set -eu

SITE=/data/site.json
CONFIG=/tmp/newt-config.json

checksum() {
  sha256sum "$SITE" 2>/dev/null | cut -d' ' -f1
}

if [ ! -s "$SITE" ]; then
  echo "Waiting for site credentials. Open the app in umbrelOS to add them."
  until [ -s "$SITE" ]; do sleep 5; done
fi

while true; do
  current=$(checksum)
  cp "$SITE" "$CONFIG"
  # A stale health file would show "Connected" on the setup page.
  rm -f "${HEALTH_FILE:-/nonexistent}"
  echo "Starting Newt."
  CONFIG_FILE="$CONFIG" newt &
  pid=$!

  while kill -0 "$pid" 2>/dev/null && [ "$(checksum)" = "$current" ]; do
    sleep 5
  done

  if kill -0 "$pid" 2>/dev/null; then
    echo "Site credentials changed, restarting Newt."
    kill "$pid"
    wait "$pid" || true
  else
    # Newt exited by itself: let Docker's restart policy handle it.
    wait "$pid" || exit $?
    exit 0
  fi
done
