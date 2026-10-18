#!/usr/bin/env bash
# Boots the Newt app the way umbrelOS would (without app_proxy) and checks that
# the setup page validates and saves credentials, and that Newt starts with them.
# There is no Pangolin server here, so it doesn't check that Newt connects.
# Needs Docker, yq (mikefarah) and passwordless sudo.
#
# Usage: scripts/smoke-test-newt.sh simaky-newt
set -euo pipefail

app="${1:?usage: $0 <app-dir>}"
root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)

export APP_DATA_DIR="$work/$app"
cp -r "$root/$app" "$APP_DATA_DIR"
# The setup page runs as 1000:1000, like the umbrel user owns app data.
chmod -R a+rwX "$APP_DATA_DIR/data"

# umbrelOS injects app_proxy and names containers <app-id>_<service>_1.
compose_file="$APP_DATA_DIR/docker-compose.test.yml"
yq "del(.services.app_proxy) | .services |= with_entries(.value.container_name = \"${app}_\" + .key + \"_1\")
  | .services.web.ports = [\"127.0.0.1:18080:8080\"]" \
  "$APP_DATA_DIR/docker-compose.yml" > "$compose_file"
compose() { docker compose --project-name "$app" --file "$compose_file" "$@"; }

page=http://127.0.0.1:18080/cgi-bin/index.cgi
site="$APP_DATA_DIR/data/site.json"

cleanup() {
  status=$?
  if [ "$status" -ne 0 ]; then
    compose ps -a || true
    compose logs --no-color --tail 100 || true
    tail_log=$(compose logs --no-color --tail 15 2>&1 | sed -e "s/%/%25/g" | awk '{printf "%s%%0A", $0}')
    echo "::error title=$app smoke test failed::$tail_log"
  fi
  compose down --volumes --remove-orphans || true
  sudo rm -rf "$work"
  exit "$status"
}
trap cleanup EXIT

compose up --detach

echo "Checking the setup page loads."
for _ in $(seq 1 30); do curl -fsS -o /dev/null "$page" && break; sleep 1; done
curl -fsS "$page" | grep -q 'Not set up'

echo "Checking invalid input is rejected."
curl -fsS --data 'endpoint=not-a-url&id=abc&secret=def' "$page" | grep -q 'Enter the Pangolin address'
[ ! -e "$site" ]

echo "Checking a cross-site request is ignored."
curl -fsS -H 'Origin: https://evil.example' --data 'endpoint=https%3A%2F%2Fpangolin.example.com&id=abc&secret=def' "$page" \
  | grep -q 'another site'
[ ! -e "$site" ]

echo "Checking valid credentials are saved."
curl -fsS --data 'endpoint=https%3A%2F%2Fpangolin.example.com%2F&id=site_id-1&secret=Secret123' "$page" | grep -q 'Saved'
sudo grep -q '"endpoint": "https://pangolin.example.com"' "$site"
sudo grep -q '"secret": "Secret123"' "$site"

echo "Checking an empty secret keeps the saved one."
curl -fsS --data 'endpoint=https%3A%2F%2Fpangolin.example.com&id=site_id-2&secret=' "$page" | grep -q 'Saved'
sudo grep -q '"id": "site_id-2"' "$site"
sudo grep -q '"secret": "Secret123"' "$site"

echo "Checking Newt starts with the saved credentials."
for _ in $(seq 1 30); do
  compose logs newt 2>&1 | grep -q 'Starting Newt' && break
  sleep 2
done
compose logs newt 2>&1 | grep -q 'Starting Newt'
docker exec "${app}_newt_1" newt --version 2>&1 | head -n 1 || true
[ "$(docker inspect -f '{{.State.Running}}' "${app}_newt_1")" = "true" ]

echo "$app passed."
