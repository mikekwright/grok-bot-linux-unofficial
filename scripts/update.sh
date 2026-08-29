#!/usr/bin/env bash
# Build and install the newest stable Grok Bot release without modifying Git.
set -euo pipefail

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
ROOT="$(cd "$(dirname "$SCRIPT_PATH")/.." && pwd)"

usage() {
  cat <<EOF
Usage: $(basename "$0") [--check]

Without options, detect, build, validate, and install the newest stable
Grok Bot release. --check only compares the installed and newest versions.
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

for cmd in awk dpkg dpkg-deb dpkg-query find flock pgrep sort; do
  command -v "$cmd" >/dev/null || {
    echo "error: missing required command: $cmd" >&2
    exit 1
  }
done

CACHE="${ROOT}/.cache"
DIST="${ROOT}/dist"
mkdir -p "$CACHE"
exec 9>"${CACHE}/update.lock"
chmod 0600 "${CACHE}/update.lock"
if ! flock -n 9; then
  echo "error: another Grok Bot update is already running" >&2
  exit 1
fi

prune_old_debs() {
  local -a debs
  local oldest
  [[ -d "$DIST" ]] || return 0
  mapfile -t debs < <(
    find "$DIST" -maxdepth 1 -type f \
      -regextype posix-extended \
      -regex '.*/grok-bot_[0-9]+\.[0-9]+\.[0-9]+_amd64\.deb' \
      -print | sort -V
  )
  while [[ "${#debs[@]}" -gt 2 ]]; do
    oldest="${debs[0]}"
    echo "Removing superseded rollback package: ${oldest}"
    find "$oldest" -maxdepth 0 -type f -delete
    debs=("${debs[@]:1}")
  done
}

prune_installer_cache() {
  local current_version="$1"
  local installer name
  while IFS= read -r -d '' installer; do
    name="$(basename "$installer")"
    if [[ "$name" =~ ^Grok_Bot_([0-9]+\.[0-9]+\.[0-9]+)_Setup\.exe$ ]] && \
        [[ "${BASH_REMATCH[1]}" != "$current_version" ]]; then
      echo "Removing superseded cached installer: ${installer}"
      find "$installer" -maxdepth 0 -type f -delete
    fi
  done < <(find "$CACHE" -maxdepth 1 -type f \
    -name 'Grok_Bot_*_Setup.exe' -print0)
}

prune_release_artifacts() {
  prune_old_debs
  prune_installer_cache "$1"
}

IFS=$'\t' read -r LATEST_VERSION INSTALLER_URL \
  < <("${ROOT}/scripts/latest-release.sh")
[[ -n "$LATEST_VERSION" && -n "$INSTALLER_URL" ]] || {
  echo "error: could not resolve the latest upstream release" >&2
  exit 1
}

INSTALLED_VERSION=""
if installed_line="$(dpkg-query -W -f='${db:Status-Abbrev}\t${Version}\n' \
    grok-bot 2>/dev/null)"; then
  read -r status INSTALLED_VERSION <<<"$installed_line"
  [[ "$status" == "ii"* ]] || INSTALLED_VERSION=""
fi

echo "Installed : ${INSTALLED_VERSION:-not installed}"
echo "Available : ${LATEST_VERSION}"

if [[ -n "$INSTALLED_VERSION" ]] && \
    dpkg --compare-versions "$INSTALLED_VERSION" ge "$LATEST_VERSION"; then
  if [[ "$CHECK_ONLY" -eq 0 ]]; then
    prune_release_artifacts "$LATEST_VERSION"
  fi
  echo "Grok Bot is already up to date."
  exit 0
fi

if [[ "$CHECK_ONLY" -eq 1 ]]; then
  echo "An update is available."
  exit 0
fi

if pgrep -x grok-bot >/dev/null 2>&1; then
  echo "error: Grok Bot is running. Close it, then run this command again." >&2
  exit 1
fi

echo "Preparing Grok Bot ${LATEST_VERSION} from ${INSTALLER_URL}"
DEB="${ROOT}/dist/grok-bot_${LATEST_VERSION}_amd64.deb"
if [[ ! -f "$DEB" ]]; then
  "${ROOT}/scripts/build.sh" --deb-only "$LATEST_VERSION"
else
  echo "Using existing build: ${DEB}"
fi

PACKAGE_NAME="$(dpkg-deb -f "$DEB" Package)"
PACKAGE_VERSION="$(dpkg-deb -f "$DEB" Version)"
PACKAGE_ARCH="$(dpkg-deb -f "$DEB" Architecture)"
if [[ "$PACKAGE_NAME" != "grok-bot" || \
      "$PACKAGE_VERSION" != "$LATEST_VERSION" || \
      "$PACKAGE_ARCH" != "amd64" ]]; then
  echo "error: generated package metadata does not match the requested release" >&2
  exit 1
fi
package_contents="$(dpkg-deb --contents "$DEB")"
for required_path in \
    './opt/grok-bot/grok-bot' \
    './opt/grok-bot/resources/app.asar' \
    './usr/bin/grok-bot'; do
  awk -v path="$required_path" \
    '$NF == path { found = 1 } END { exit !found }' \
    <<<"$package_contents" || {
    echo "error: generated package does not contain ${required_path}" >&2
    exit 1
  }
done

echo "Package validation passed. Administrator approval is required to install it."
if [[ "$EUID" -eq 0 ]]; then
  apt-get install -y "$DEB"
elif command -v pkexec >/dev/null && \
    [[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]]; then
  pkexec apt-get install -y "$DEB"
elif command -v sudo >/dev/null; then
  sudo apt-get install -y "$DEB"
else
  echo "error: pkexec or sudo is required to install the package" >&2
  exit 1
fi

ACTUAL_VERSION="$(dpkg-query -W -f='${Version}' grok-bot)"
if [[ "$ACTUAL_VERSION" != "$LATEST_VERSION" ]]; then
  echo "error: installed version is ${ACTUAL_VERSION}, expected ${LATEST_VERSION}" >&2
  exit 1
fi

prune_release_artifacts "$LATEST_VERSION"
echo "Updated Grok Bot to ${ACTUAL_VERSION}. Launch it with: grok-bot"
