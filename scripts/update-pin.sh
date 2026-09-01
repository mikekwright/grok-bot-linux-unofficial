#!/usr/bin/env bash
# Refresh upstream.json with the newest stable upstream release.
set -euo pipefail

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
ROOT="$(cd "$(dirname "$SCRIPT_PATH")/.." && pwd)"
PIN="${ROOT}/upstream.json"

usage() {
  cat <<EOF
Usage: $(basename "$0") [--check]

Queries Cursor's update API and rewrites upstream.json with the newest
stable version, installer URL, and SRI hash. The Nix build (flake.nix)
consumes this pin.

--check only compares versions: exit 0 when up to date, 10 when a
newer release exists.
EOF
}

CHECK_ONLY=0
case "${1:-}" in
  "") ;;
  --check) CHECK_ONLY=1 ;;
  -h|--help) usage; exit 0 ;;
  *) echo "error: unknown option: $1" >&2; usage >&2; exit 1 ;;
esac
[[ $# -le 1 ]] || { usage >&2; exit 1; }

for cmd in curl python3; do
  command -v "$cmd" >/dev/null || {
    echo "error: missing required command: $cmd" >&2
    exit 1
  }
done

IFS=$'\t' read -r LATEST_VERSION INSTALLER_URL \
  < <("${ROOT}/scripts/latest-release.sh")
[[ -n "$LATEST_VERSION" && -n "$INSTALLER_URL" ]] || {
  echo "error: could not resolve the latest upstream release" >&2
  exit 1
}

PINNED_VERSION=""
if [[ -f "$PIN" ]]; then
  PINNED_VERSION="$(python3 -c '
import json, sys
print(json.load(open(sys.argv[1])).get("version", ""))
' "$PIN")"
fi

echo "Pinned    : ${PINNED_VERSION:-none}"
echo "Available : ${LATEST_VERSION}"

if [[ "$PINNED_VERSION" == "$LATEST_VERSION" ]]; then
  echo "upstream.json is already up to date."
  exit 0
fi

if [[ "$CHECK_ONLY" -eq 1 ]]; then
  echo "A newer upstream release is available."
  exit 10
fi

echo "Hashing ${INSTALLER_URL}"
if command -v nix >/dev/null; then
  HASH="$(nix store prefetch-file --json "$INSTALLER_URL" |
    python3 -c 'import json, sys; print(json.load(sys.stdin)["hash"])')"
else
  TMP="$(mktemp -t grokbot-pin-XXXXXX)"
  trap 'rm -f "$TMP"' EXIT
  curl -fL --retry 3 -A 'Mozilla/5.0' -o "$TMP" "$INSTALLER_URL"
  HASH="sha256-$(sha256sum "$TMP" | cut -d' ' -f1 | xxd -r -p | base64 -w0)"
fi
[[ "$HASH" =~ ^sha256-[A-Za-z0-9+/]{43}=$ ]] || {
  echo "error: computed hash looks malformed: $HASH" >&2
  exit 1
}

python3 - "$PIN" "$LATEST_VERSION" "$INSTALLER_URL" "$HASH" <<'PY'
import json, sys
path, version, url, digest = sys.argv[1:5]
with open(path, "w") as handle:
    json.dump({"version": version, "url": url, "hash": digest}, handle, indent=2)
    handle.write("\n")
PY

echo "Pinned Grok Bot ${LATEST_VERSION} in upstream.json"
