#!/usr/bin/env bash
# Backward-compatible entry point for the canonical updater.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec "${ROOT}/scripts/update.sh" "$@"
