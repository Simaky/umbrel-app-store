#!/bin/sh
# Setup page for Newt, served by busybox httpd behind the umbrelOS login.
# GET shows the form and the connection status; POST saves the site
# credentials to /data/site.json, which run-newt.sh picks up.

SITE=/data/site.json
HEALTH=/data/run/healthy

field() {
  # Reads a value from a JSON file written by this script (values are validated,
  # so they never contain quotes).
  sed -n "s/.*\"$1\": *\"\([^\"]*\)\".*/\1/p" "$SITE" 2>/dev/null
}

form_value() {
  # Extracts and URL-decodes one field from an application/x-www-form-urlencoded body.
  printf '%s' "$BODY" | tr '&' '\n' | sed -n "s/^$1=//p" | head -n 1 | awk '
    BEGIN { for (i = 0; i < 256; i++) hex[sprintf("%02X", i)] = sprintf("%c", i) }
    {
      gsub(/\+/, " ")
      out = ""
      while (match($0, /%[0-9A-Fa-f][0-9A-Fa-f]/)) {
        out = out substr($0, 1, RSTART - 1) hex[toupper(substr($0, RSTART + 1, 2))]
        $0 = substr($0, RSTART + 3)
      }
      printf "%s", out $0
    }'
}

message=""
error=""

if [ "${REQUEST_METHOD:-GET}" = "POST" ]; then
  BODY=$(head -c "${CONTENT_LENGTH:-0}")
  endpoint=$(form_value endpoint | sed 's#/*$##')
  id=$(form_value id)
  secret=$(form_value secret)
  [ -z "$secret" ] && secret=$(field secret)

  origin_host="${HTTP_ORIGIN#*://}"
  if [ -n "${HTTP_ORIGIN:-}" ] && [ "$origin_host" != "${HTTP_HOST:-}" ] \
    && [ "$origin_host" != "${HTTP_X_FORWARDED_HOST:-}" ]; then
    error="This request came from another site and was ignored."
  elif ! printf '%s' "$endpoint" | grep -Eq '^https?://[A-Za-z0-9.-]+(:[0-9]+)?$'; then
    error="Enter the Pangolin address, for example https://pangolin.example.com"
  elif ! printf '%s' "$id" | grep -Eq '^[A-Za-z0-9_-]{1,128}$'; then
    error="The ID can only contain letters, numbers, - and _."
  elif ! printf '%s' "$secret" | grep -Eq '^[A-Za-z0-9_-]{1,256}$'; then
    error="The secret can only contain letters, numbers, - and _."
  else
    umask 077
    printf '{\n  "endpoint": "%s",\n  "id": "%s",\n  "secret": "%s"\n}\n' \
      "$endpoint" "$id" "$secret" > "$SITE.tmp" && mv "$SITE.tmp" "$SITE"
    message="Saved. Newt is connecting to $endpoint."
  fi
fi

endpoint=$(field endpoint)
id=$(field id)
if [ -f "$HEALTH" ]; then
  status='<span class="ok">Connected</span>'
elif [ -s "$SITE" ]; then
  status='<span class="wait">Not connected yet</span>'
else
  status='<span class="wait">Not set up</span>'
fi
secret_hint="Paste the secret from Pangolin"
[ -s "$SITE" ] && secret_hint="Leave empty to keep the saved secret"

printf 'Content-Type: text/html; charset=utf-8\r\n'
printf 'Cache-Control: no-store\r\n'
printf 'X-Frame-Options: SAMEORIGIN\r\n\r\n'
cat <<EOF
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Newt</title>
<style>
  :root { color-scheme: light dark; --bg: #f6f7f9; --card: #fff; --text: #1d2330; --muted: #5f6b7a; --line: #d8dde4; --accent: #f36a21; }
  @media (prefers-color-scheme: dark) { :root { --bg: #14161a; --card: #1e2127; --text: #e7eaee; --muted: #9aa4b1; --line: #343943; } }
  * { box-sizing: border-box; }
  body { margin: 0; padding: 32px 16px; background: var(--bg); color: var(--text); font: 15px/1.5 system-ui, sans-serif; }
  main { max-width: 520px; margin: 0 auto; background: var(--card); border: 1px solid var(--line); border-radius: 12px; padding: 24px; }
  h1 { margin: 0 0 4px; font-size: 22px; }
  p { margin: 0 0 16px; color: var(--muted); }
  label { display: block; margin: 16px 0 6px; font-weight: 600; }
  input { width: 100%; padding: 10px 12px; border: 1px solid var(--line); border-radius: 8px; background: transparent; color: inherit; font: inherit; }
  button { margin-top: 20px; padding: 10px 18px; border: 0; border-radius: 8px; background: var(--accent); color: #fff; font: inherit; font-weight: 600; cursor: pointer; }
  .status { margin: 16px 0 0; }
  .ok { color: #2f9e44; font-weight: 600; }
  .wait { color: var(--muted); font-weight: 600; }
  .note { margin-top: 16px; padding: 10px 12px; border-radius: 8px; border: 1px solid var(--line); }
  .error { border-color: #e03131; color: #e03131; }
</style>
</head>
<body>
<main>
  <h1>Newt</h1>
  <p>Connects this Umbrel to your Pangolin server. In Pangolin, create a site of type Newt and copy its details here.</p>
  <div class="status">Status: $status</div>
EOF
[ -n "$message" ] && printf '  <div class="note">%s</div>\n' "$message"
[ -n "$error" ] && printf '  <div class="note error">%s</div>\n' "$error"
cat <<EOF
  <form method="post">
    <label for="endpoint">Pangolin address</label>
    <input id="endpoint" name="endpoint" type="url" required placeholder="https://pangolin.example.com" value="$endpoint">
    <label for="id">Site ID</label>
    <input id="id" name="id" required autocomplete="off" value="$id">
    <label for="secret">Site secret</label>
    <input id="secret" name="secret" type="password" autocomplete="off" placeholder="$secret_hint">
    <button type="submit">Save and connect</button>
  </form>
  <p class="note">In Pangolin resources, use <b>localhost</b> as the target address to reach apps on this Umbrel, for example localhost:25565 for Minecraft.</p>
</main>
</body>
</html>
EOF
