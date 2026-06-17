#!/bin/bash
# xui-pull-outbound.sh — fetch one outbound's JSON from a URL (e.g. a GitHub
# raw link), upsert it into the 3x-ui Xray config by tag, then reload.
#
# Usage:
#   ./xui-pull-outbound.sh <url> [match-tag]
#
#   <url>         any URL serving the raw outbound JSON, e.g.
#                 https://raw.githubusercontent.com/you/repo/main/outbound.json
#   [match-tag]   which existing outbound's tag to overwrite. If omitted,
#                 uses the "tag" field inside the fetched JSON itself.
#                 If no outbound currently has that tag, it's appended.
#
# Env:
#   XUI_DB=/path/to/x-ui.db                       (default: /etc/x-ui/x-ui.db)
#   AUTH_HEADER="Authorization: Bearer <token>"   (for private repos)
#   NO_RELOAD=1                                    (skip the restart at the end)

set -euo pipefail

URL="${1:-}"
MATCH_TAG="${2:-}"
DB="${XUI_DB:-/etc/x-ui/x-ui.db}"

[[ -n "$URL" ]] || { echo "Usage: $0 <url> [match-tag]"; exit 1; }

for dep in curl sqlite3 jq; do
  command -v "$dep" >/dev/null 2>&1 || { echo "Missing '$dep'. Install with: apt install -y $dep"; exit 1; }
done

[[ -f "$DB" ]] || { echo "DB not found at $DB (set XUI_DB=... if it's elsewhere)"; exit 1; }

CURL_ARGS=(-fsSL)
[[ -n "${AUTH_HEADER:-}" ]] && CURL_ARGS+=(-H "$AUTH_HEADER")

NEW_OUTBOUND=$(curl "${CURL_ARGS[@]}" "$URL") || { echo "Failed to fetch $URL"; exit 1; }
jq -e 'type == "object"' >/dev/null 2>&1 <<< "$NEW_OUTBOUND" || { echo "Fetched content isn't a JSON object"; exit 1; }

if [[ -z "$MATCH_TAG" ]]; then
  MATCH_TAG=$(jq -r '.tag // empty' <<< "$NEW_OUTBOUND")
  [[ -n "$MATCH_TAG" ]] || { echo "Fetched JSON has no 'tag' field — pass [match-tag] explicitly"; exit 1; }
fi

CURRENT=$(sqlite3 -cmd ".timeout 5000" "$DB" "SELECT value FROM settings WHERE key='xraySetting';")
[[ -n "$CURRENT" ]] || { echo "No 'xraySetting' row found in $DB"; exit 1; }

UPDATED=$(jq --argjson newOb "$NEW_OUTBOUND" --arg tag "$MATCH_TAG" '
  .outbounds = (
    (.outbounds // []) as $obs
    | if any($obs[]; .tag == $tag)
      then [$obs[] | if .tag == $tag then $newOb else . end]
      else $obs + [$newOb]
      end
  )' <<< "$CURRENT")

jq -e . >/dev/null 2>&1 <<< "$UPDATED" || { echo "Internal error: result wasn't valid JSON, aborting before write"; exit 1; }

BACKUP="${DB}.bak.$(date +%Y%m%d%H%M%S)"
cp -p "$DB" "$BACKUP"

ESCAPED=$(sed "s/'/''/g" <<< "$UPDATED")
sqlite3 -cmd ".timeout 5000" "$DB" "UPDATE settings SET value = '$ESCAPED' WHERE key='xraySetting';"

echo "Outbound '$MATCH_TAG' updated from $URL (backup: $BACKUP)"

if [[ "${NO_RELOAD:-0}" == "1" ]]; then
  echo "NO_RELOAD set — skipping restart. Apply later with: systemctl restart x-ui"
  exit 0
fi

systemctl restart x-ui
sleep 1
if systemctl is-active --quiet x-ui; then
  echo "x-ui restarted and active (this also restarts its managed Xray-core process)."
else
  echo "WARNING: x-ui did not come back up — check: journalctl -u x-ui -n 50"
  exit 1
fi

if systemctl list-unit-files 2>/dev/null | grep -q '^xray\.service'; then
  systemctl restart xray
  if systemctl is-active --quiet xray; then
    echo "Standalone xray.service also restarted."
  else
    echo "WARNING: standalone xray.service did not come back up — check: journalctl -u xray -n 50"
  fi
fi
