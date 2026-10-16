#!/bin/ash
# First-run provisioning for Pterodactyl on Umbrel.
#
# Runs inside the panel image after the panel is healthy, then exits so Wings
# can start. It creates the admin user, a location, a node for the bundled
# Wings daemon with a block of port allocations, and the Wings config.yml.
# Every step is idempotent: on later starts it only checks and exits.
#
# To re-provision Wings (for example after deleting the node in the panel),
# delete data/wings/config.yml and data/wings/.node-id and restart the app.
set -eu

: "${WINGS_DIR:?}" "${PANEL_REMOTE:?}" "${NODE_FQDN:?}" "${WINGS_PORT:?}" "${SFTP_PORT:?}"
: "${ALLOCATION_START:?}" "${ALLOCATION_END:?}" "${ADMIN_EMAIL:?}" "${ADMIN_USERNAME:?}" "${ADMIN_PASSWORD:?}"
: "${WINGS_NETWORK_NAME:?}" "${WINGS_NETWORK_SUBNET:?}" "${WINGS_NETWORK_GATEWAY:?}"
: "${WINGS_NETWORK_SUBNET_V6:?}" "${WINGS_NETWORK_GATEWAY_V6:?}"
NODE_NAME="${NODE_NAME:-Umbrel}"

cd /app
ln -sfn /app/var/.env /app/.env
mkdir -p "$WINGS_DIR"

CONFIG="$WINGS_DIR/config.yml"
NODE_ID_FILE="$WINGS_DIR/.node-id"
MYCNF=/tmp/umbrel-my.cnf

umask 077
cat > "$MYCNF" <<EOF
[client]
host=${DB_HOST}
port=${DB_PORT:-3306}
user=${DB_USERNAME}
password=${DB_PASSWORD}
skip-ssl
EOF

sql() {
  mysql --defaults-extra-file="$MYCNF" -N -B "$DB_DATABASE" -e "$1"
}

echo "Waiting for the panel database schema..."
tries=0
until sql "SELECT 1 FROM users LIMIT 1" >/dev/null 2>&1; do
  tries=$((tries + 1))
  if [ "$tries" -ge 300 ]; then
    echo "The panel database is not ready after 10 minutes." >&2
    exit 1
  fi
  sleep 2
done

if [ "$(sql "SELECT COUNT(*) FROM users WHERE root_admin = 1")" = "0" ]; then
  echo "Creating admin user '$ADMIN_USERNAME'."
  php artisan p:user:make --no-interaction --admin=1 \
    --email="$ADMIN_EMAIL" --username="$ADMIN_USERNAME" \
    --name-first=Umbrel --name-last=Admin --password="$ADMIN_PASSWORD"
fi

if [ -s "$CONFIG" ]; then
  echo "Wings is already configured."
  exit 0
fi

NODE_ID=""
if [ -f "$NODE_ID_FILE" ]; then
  NODE_ID=$(tr -cd '0-9' < "$NODE_ID_FILE")
  if [ -n "$NODE_ID" ] && [ -z "$(sql "SELECT id FROM nodes WHERE id = $NODE_ID")" ]; then
    NODE_ID=""
  fi
fi

if [ -z "$NODE_ID" ]; then
  LOCATION_ID=$(sql "SELECT id FROM locations WHERE short = 'umbrel' LIMIT 1")
  if [ -z "$LOCATION_ID" ]; then
    echo "Creating location 'umbrel'."
    php artisan p:location:make --no-interaction --short=umbrel --long="This Umbrel"
    LOCATION_ID=$(sql "SELECT id FROM locations WHERE short = 'umbrel' LIMIT 1")
  fi

  MEMORY_MB=$(awk '/^MemTotal:/ { printf "%d", $2 / 1024 }' /proc/meminfo)
  DISK_MB=$(df -Pm "$WINGS_DIR" | awk 'NR == 2 { print $2 }')

  echo "Creating node '$NODE_NAME' (${MEMORY_MB} MiB RAM, ${DISK_MB} MiB disk)."
  php artisan p:node:make --no-interaction \
    --name="$NODE_NAME" --description="Wings bundled with the Umbrel app" \
    --locationId="$LOCATION_ID" --fqdn="$NODE_FQDN" --public=1 --scheme=http \
    --proxy=0 --maintenance=0 --maxMemory="$MEMORY_MB" --overallocateMemory=0 \
    --maxDisk="$DISK_MB" --overallocateDisk=0 --uploadSize=100 \
    --daemonListeningPort="$WINGS_PORT" --daemonSFTPPort="$SFTP_PORT" \
    --daemonBase="$WINGS_DIR/volumes"
  NODE_ID=$(sql "SELECT MAX(id) FROM nodes WHERE name = '$NODE_NAME'")
  echo "$NODE_ID" > "$NODE_ID_FILE"

  echo "Adding allocations ${ALLOCATION_START}-${ALLOCATION_END}."
  values=""
  port=$ALLOCATION_START
  while [ "$port" -le "$ALLOCATION_END" ]; do
    values="${values}${values:+,}($NODE_ID, '0.0.0.0', '$NODE_FQDN', $port, NOW(), NOW())"
    port=$((port + 1))
  done
  sql "INSERT IGNORE INTO allocations (node_id, ip, ip_alias, port, created_at, updated_at) VALUES $values" \
    || echo "Could not add allocations; add them in Admin > Nodes > $NODE_NAME > Allocation." >&2
fi

echo "Writing Wings configuration for node $NODE_ID."
php artisan p:node:configuration "$NODE_ID" --format=json > /tmp/umbrel-node.json

# The panel's config only covers the API, token and data path. Wings runs in a
# container next to the host Docker daemon, so every path it bind-mounts into
# game containers must exist at the same location on the host.
php > "$CONFIG.tmp" <<'PHP'
<?php
$raw = file_get_contents('/tmp/umbrel-node.json');
$start = strpos($raw, '{');
$end = strrpos($raw, '}');
if ($start === false || $end === false) {
    fwrite(STDERR, "The panel returned no node configuration.\n");
    exit(1);
}
$config = json_decode(substr($raw, $start, $end - $start + 1), true, 512, JSON_THROW_ON_ERROR);

$dir = getenv('WINGS_DIR');
$config['remote'] = getenv('PANEL_REMOTE');
// The browser reaches the panel by umbrel.local, the IP or a Tailscale name,
// so allow the console websocket from any origin.
$config['allowed_origins'] = ['*'];
$config['system'] = array_merge($config['system'] ?? [], [
    'root_directory' => "$dir/lib",
    'data' => "$dir/volumes",
    'archive_directory' => "$dir/lib/archives",
    'backup_directory' => "$dir/backups",
    'tmp_directory' => "$dir/tmp",
    'log_directory' => "$dir/logs",
    'machine_id' => ['enabled' => true, 'directory' => "$dir/run/machine-id"],
    'passwd' => ['enabled' => false, 'directory' => "$dir/run/etc"],
]);
$network = getenv('WINGS_NETWORK_NAME');
$config['docker']['network'] = [
    'name' => $network,
    'network_mode' => $network,
    'interface' => getenv('WINGS_NETWORK_GATEWAY'),
    'interfaces' => [
        'v4' => ['subnet' => getenv('WINGS_NETWORK_SUBNET'), 'gateway' => getenv('WINGS_NETWORK_GATEWAY')],
        'v6' => ['subnet' => getenv('WINGS_NETWORK_SUBNET_V6'), 'gateway' => getenv('WINGS_NETWORK_GATEWAY_V6')],
    ],
];

// JSON is valid YAML, which is what Wings reads.
echo json_encode($config, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES | JSON_THROW_ON_ERROR), "\n";
PHP
mv "$CONFIG.tmp" "$CONFIG"
rm -f /tmp/umbrel-node.json
echo "Wings configuration written to $CONFIG."
