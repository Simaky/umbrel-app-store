#!/usr/bin/env bash
# Boots one app the way umbrelOS would (without app_proxy) and checks that the
# panel comes up, setup provisions Wings, Wings accepts the panel's token, and a
# second start is a no-op. Needs Docker, yq (mikefarah), jq and passwordless sudo.
#
# Usage: scripts/smoke-test.sh <app-dir>
set -euo pipefail

app="${1:?usage: $0 <app-dir>}"
root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)

export APP_DATA_DIR="$work/$app"
export APP_PASSWORD="smoke-test-password-0123456789"
export DEVICE_DOMAIN_NAME="umbrel.local"

cp -r "$root/$app" "$APP_DATA_DIR"
# The database and Redis run as 1000:1000, like the umbrel user owns app data.
chmod -R a+rwX "$APP_DATA_DIR/data"

# umbrelOS injects app_proxy and names containers <app-id>_<service>_1.
compose_file="$APP_DATA_DIR/docker-compose.test.yml"
yq "del(.services.app_proxy) | .services |= with_entries(.value.container_name = \"${app}_\" + .key + \"_1\")" \
  "$APP_DATA_DIR/docker-compose.yml" > "$compose_file"
compose() { docker compose --project-name "$app" --file "$compose_file" "$@"; }

wings_port=$(yq '.services.wings.ports[0] | split(":") | .[0]' "$compose_file")
network=$(yq '.services.setup.environment.WINGS_NETWORK_NAME' "$compose_file")
config="$APP_DATA_DIR/data/wings/config.yml"

cleanup() {
  status=$?
  if [ "$status" -ne 0 ]; then
    compose ps -a || true
    compose logs --no-color --tail 200 || true
  fi
  compose down --volumes --remove-orphans || true
  docker network rm "$network" >/dev/null 2>&1 || true
  sudo rm -rf "$work"
  exit "$status"
}
trap cleanup EXIT

echo "::group::Start $app"
compose up --detach
echo "::endgroup::"

echo "Checking the setup container output."
docker wait "${app}_setup_1" | grep -qx 0
sudo test -s "$config"

echo "Checking the panel serves its login page."
docker exec "${app}_web_1" curl -fsS -o /dev/null http://127.0.0.1/auth/login

echo "Checking Wings accepts the panel's token on port $wings_port."
token=$(sudo jq -r .token "$config")
for _ in $(seq 1 60); do
  if curl -fsS -H "Authorization: Bearer $token" "http://127.0.0.1:$wings_port/api/system" >/dev/null 2>&1; then
    break
  fi
  sleep 2
done
curl -fsS -H "Authorization: Bearer $token" "http://127.0.0.1:$wings_port/api/system"
echo

echo "Checking the panel can reach Wings through the node FQDN."
docker exec "${app}_web_1" curl -fsS -o /dev/null -H "Authorization: Bearer $token" \
  "http://$DEVICE_DOMAIN_NAME:$wings_port/api/system"

echo "Checking Wings stays up."
sleep 10
[ "$(docker inspect -f '{{.State.Running}}' "${app}_wings_1")" = "true" ]

echo "Checking a restart keeps the existing configuration."
before=$(sudo sha256sum "$config")
compose up --detach --force-recreate
docker wait "${app}_setup_1" | grep -qx 0
[ "$(sudo sha256sum "$config")" = "$before" ]
[ "$(docker exec "${app}_db_1" mariadb -upterodactyl -p"$APP_PASSWORD" panel -N -B -e 'SELECT COUNT(*) FROM nodes')" = "1" ]

echo "$app passed."
