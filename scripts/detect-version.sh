#!/usr/bin/env bash
# Print the newest stable Grok Bot version reported by Cursor's updater API.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
"${ROOT}/scripts/latest-release.sh" | cut -f1
