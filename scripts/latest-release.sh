#!/usr/bin/env bash
# Print the newest stable upstream release as: <version><tab><installer-url>
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CACHE="${ROOT}/.cache"
MACHINE_ID_FILE="${CACHE}/update-machine-id"

for cmd in curl python3; do
  command -v "$cmd" >/dev/null || {
    echo "error: missing required command: $cmd" >&2
    exit 1
  }
done

MACHINE_ID=""
if [[ -f "$MACHINE_ID_FILE" ]]; then
  MACHINE_ID="$(tr -d '[:space:]' < "$MACHINE_ID_FILE")"
fi
if [[ ! "$MACHINE_ID" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$ ]]; then
  MACHINE_ID="$(python3 -c 'import uuid; print(uuid.uuid4())')"
  mkdir -p "$CACHE"
  umask 077
  printf '%s\n' "$MACHINE_ID" > "$MACHINE_ID_FILE"
fi
chmod 0600 "$MACHINE_ID_FILE"

UPDATE_URL="https://api2.cursor.sh/updates/api/update/win32-x64-user/sand/0.0.0/${MACHINE_ID}/stable"

curl -fsSL --retry 3 --connect-timeout 10 --max-time 30 \
  -H 'cache-control: no-cache' "$UPDATE_URL" |
  python3 -c '
import json
import re
import sys
from urllib.parse import urlparse

try:
    release = json.load(sys.stdin)
except (json.JSONDecodeError, OSError) as exc:
    raise SystemExit(f"error: malformed update response: {exc}")

version = release.get("version")
url = release.get("url")
if not isinstance(version, str) or not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version):
    raise SystemExit("error: update response has an invalid version")
if not isinstance(url, str):
    raise SystemExit("error: update response has no installer URL")

parsed = urlparse(url)
expected_path = (
    f"/grokbot/stable/win32-x64/{version}/"
    f"Grok_Bot_{version}_Setup.exe"
)
if parsed.scheme != "https" or parsed.hostname != "downloads.cursor.com":
    raise SystemExit("error: update response points to an untrusted host")
if parsed.path != expected_path or parsed.query or parsed.fragment:
    raise SystemExit("error: update response has an unexpected installer path")

print(f"{version}\t{url}")
'
