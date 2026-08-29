#!/usr/bin/env bash
# Rebuild the official Grok Bot Windows installer as a native Linux app.
#
# Usage:
#   scripts/build.sh                 # latest CDN version
#   scripts/build.sh --deb-only      # only the Ubuntu/Debian package
#   scripts/build.sh X.Y.Z
#   scripts/build.sh --exe /path/to/Grok_Bot_X.Y.Z_Setup.exe
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST="${ROOT}/dist"
CACHE="${ROOT}/.cache"
ELECTRON_VERSION="${ELECTRON_VERSION:-42.1.0}"

usage() {
  cat <<EOF
Usage: $(basename "$0") [--deb-only] [--exe /path/to/Grok_Bot_X.Y.Z_Setup.exe] [X.Y.Z]

Downloads the official Windows installer (or uses --exe), extracts the
Electron app without Wine, fuses it with Electron ${ELECTRON_VERSION} for
Linux, replaces Windows native addons, and writes:

  dist/Grok_Bot_<ver>_linux_x64/          runnable tree
  dist/Grok_Bot_<ver>_linux_x64.tar.gz
  dist/grok-bot_<ver>_amd64.deb
  dist/Grok_Bot_<ver>_x86_64.AppImage     (if mksquashfs is available)

With --deb-only, only dist/grok-bot_<ver>_amd64.deb is written.
EOF
}

EXE=""
VERSION=""
DEB_ONLY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --deb-only) DEB_ONLY=1; shift ;;
    --exe) EXE="${2:?}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "unknown option $1" >&2; usage >&2; exit 1 ;;
    *) VERSION="$1"; shift ;;
  esac
done

if [[ -n "$EXE" ]]; then
  EXE="$(readlink -f "$EXE")"
  [[ -f "$EXE" ]] || { echo "not found: $EXE" >&2; exit 1; }
  if [[ -z "$VERSION" && "$EXE" =~ Grok_Bot_([0-9]+\.[0-9]+\.[0-9]+)_Setup\.exe$ ]]; then
    VERSION="${BASH_REMATCH[1]}"
  fi
fi

if [[ -z "$VERSION" ]]; then
  VERSION="$("${ROOT}/scripts/detect-version.sh")"
fi

if [[ -z "$EXE" ]]; then
  mkdir -p "$CACHE"
  EXE="${CACHE}/Grok_Bot_${VERSION}_Setup.exe"
  if [[ ! -f "$EXE" ]]; then
    url="https://downloads.cursor.com/grokbot/stable/win32-x64/${VERSION}/Grok_Bot_${VERSION}_Setup.exe"
    echo "Downloading ${url}"
    curl -fL --retry 3 -A 'Mozilla/5.0' -o "${EXE}.partial" "$url"
    mv "${EXE}.partial" "$EXE"
  fi
fi

find_node_include() {
  local cand
  if [[ -n "${GROKBOT_NODE_INCLUDE:-}" && -f "${GROKBOT_NODE_INCLUDE}/node_api.h" ]]; then
    printf '%s\n' "$GROKBOT_NODE_INCLUDE"
    return 0
  fi
  if [[ -f "${HOME}/.nvm/nvm.sh" ]]; then
    # shellcheck disable=SC1091
    source "${HOME}/.nvm/nvm.sh"
  fi
  cand="$(dirname "$(find "${HOME}/.nvm/versions/node" /usr/include /usr/local/include \
    -name node_api.h 2>/dev/null | sort | tail -1)")"
  if [[ -f "${cand}/node_api.h" ]]; then
    printf '%s\n' "$cand"
    return 0
  fi
  return 1
}

NODE_INCLUDE="$(find_node_include)" || {
  echo "node_api.h not found. Install Node.js headers (nodejs / nvm)." >&2
  exit 1
}
export GROKBOT_NODE_INCLUDE="$NODE_INCLUDE"

for cmd in curl unzip node npm npx g++ python3; do
  command -v "$cmd" >/dev/null || { echo "missing required command: $cmd" >&2; exit 1; }
done
if ! command -v 7z >/dev/null && ! command -v 7za >/dev/null; then
  echo "missing p7zip-full (7z)" >&2
  exit 1
fi
SEVEN_ZIP="7z"
command -v 7z >/dev/null || SEVEN_ZIP="7za"

WORKDIR="$(mktemp -d -t grokbot-build-XXXXXX)"
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

echo "Windows installer : $EXE"
echo "Grok Bot version  : $VERSION"
echo "Electron          : $ELECTRON_VERSION"
echo "node_api.h        : $NODE_INCLUDE"
echo "Workdir           : $WORKDIR"

NSIS="${WORKDIR}/nsis"
APP="${WORKDIR}/winapp"
mkdir -p "$NSIS" "$APP"
( cd "$NSIS" && "$SEVEN_ZIP" x -y "$EXE" >/dev/null )
PAYLOAD="$(find "$NSIS" -type f \( -name 'app-64.7z' -o -name 'app-32.7z' \) | head -1)"
[[ -n "$PAYLOAD" ]] || { echo "app-64.7z missing from NSIS payload" >&2; exit 1; }
"$SEVEN_ZIP" x -y "$PAYLOAD" -o"$APP" >/dev/null
ASAR="${APP}/resources/app.asar"
if [[ ! -f "$ASAR" && -f "${APP}/app.asar" ]]; then
  mkdir -p "${APP}/resources"
  mv "${APP}/app.asar" "$ASAR"
  [[ -d "${APP}/app.asar.unpacked" ]] && mv "${APP}/app.asar.unpacked" "${APP}/resources/app.asar.unpacked"
fi
[[ -f "$ASAR" ]] || { echo "resources/app.asar missing" >&2; exit 1; }

EL_ZIP="${CACHE}/electron-v${ELECTRON_VERSION}-linux-x64.zip"
mkdir -p "$CACHE"
if [[ ! -f "$EL_ZIP" ]]; then
  curl -fL --retry 3 -o "${EL_ZIP}.partial" \
    "https://github.com/electron/electron/releases/download/v${ELECTRON_VERSION}/electron-v${ELECTRON_VERSION}-linux-x64.zip"
  mv "${EL_ZIP}.partial" "$EL_ZIP"
fi
EL="${WORKDIR}/electron"
mkdir -p "$EL"
unzip -q "$EL_ZIP" -d "$EL"

STAGE="${WORKDIR}/Grok_Bot_${VERSION}_linux_x64"
mkdir -p "${STAGE}/resources"
cp "$EL/electron" "${STAGE}/grok-bot"
chmod 755 "${STAGE}/grok-bot"
for f in chrome-sandbox chrome_crashpad_handler libEGL.so libGLESv2.so libffmpeg.so \
         libvk_swiftshader.so libvulkan.so.1 vk_swiftshader_icd.json \
         icudtl.dat snapshot_blob.bin v8_context_snapshot.bin \
         chrome_100_percent.pak chrome_200_percent.pak resources.pak \
         LICENSE.electron.txt LICENSES.chromium.html; do
  [[ -e "$EL/$f" ]] && cp -a "$EL/$f" "$STAGE/"
done
[[ -d "$EL/locales" ]] && cp -a "$EL/locales" "$STAGE/"
chmod 755 "${STAGE}/chrome_crashpad_handler" 2>/dev/null || true
chmod 4755 "${STAGE}/chrome-sandbox" 2>/dev/null || chmod 755 "${STAGE}/chrome-sandbox"

cp -a "$ASAR" "${STAGE}/resources/app.asar"
if [[ -d "${APP}/resources/app.asar.unpacked" ]]; then
  cp -a "${APP}/resources/app.asar.unpacked" "${STAGE}/resources/"
fi
find "${STAGE}/resources" -type d -exec chmod 755 {} +
find "${STAGE}/resources" -type f -exec chmod 644 {} +
find "${STAGE}" -type f \( -name '*.node' -o -name '*.so' -o -name '*.so.*' \) -exec chmod 755 {} +

ASAR_TMP="${WORKDIR}/asar-unpacked"
npx --yes @electron/asar extract "${STAGE}/resources/app.asar" "$ASAR_TMP"

export GROKBOT_UNPACKED="${STAGE}/resources/app.asar.unpacked"
python3 "${ROOT}/scripts/fix-natives.py"

python3 - "$ASAR_TMP" "${ROOT}/packaging/linux-entry.cjs" <<'PY'
import json, shutil, sys
from pathlib import Path
asar = Path(sys.argv[1])
wrapper = Path(sys.argv[2])
pkg_path = asar / "package.json"
pkg = json.loads(pkg_path.read_text())
pkg["desktopName"] = "grok-bot.desktop"
pkg["main"] = "linux-entry.cjs"
pkg_path.write_text(json.dumps(pkg, indent=2) + "\n")
shutil.copy2(wrapper, asar / "linux-entry.cjs")
print("desktop identity: main=linux-entry.cjs")
PY

if [[ -d "${STAGE}/resources/app.asar.unpacked/dist/deps" ]]; then
  rm -rf "${ASAR_TMP}/dist/deps"
  mkdir -p "${ASAR_TMP}/dist"
  cp -a "${STAGE}/resources/app.asar.unpacked/dist/deps" "${ASAR_TMP}/dist/deps"
fi
npx --yes @electron/asar pack "$ASAR_TMP" "${STAGE}/resources/app.asar"

ICON="$(find "$ASAR_TMP" "${STAGE}/resources" -name 'app-icon*.png' 2>/dev/null | head -1 || true)"
if [[ -n "${ICON}" && -f "$ICON" ]]; then
  cp "$ICON" "${STAGE}/grok-bot.png"
fi

find "${STAGE}" -type d -exec chmod 755 {} +
find "${STAGE}" -type f -exec chmod 644 {} +
chmod 755 "${STAGE}/grok-bot"
[[ -f "${STAGE}/chrome-sandbox" ]] && chmod 4755 "${STAGE}/chrome-sandbox" || true
[[ -f "${STAGE}/chrome_crashpad_handler" ]] && chmod 755 "${STAGE}/chrome_crashpad_handler"
find "${STAGE}" -type f \( -name '*.node' -o -name '*.so' -o -name '*.so.*' \) -exec chmod 755 {} +

mkdir -p "$DIST"
if [[ "$DEB_ONLY" -eq 1 ]]; then
  "${ROOT}/scripts/package-deb.sh" "$STAGE" "$VERSION" "$DIST"
else
  rm -rf "${DIST}/Grok_Bot_${VERSION}_linux_x64"
  cp -a "$STAGE" "${DIST}/Grok_Bot_${VERSION}_linux_x64"

  TARBALL="${DIST}/Grok_Bot_${VERSION}_linux_x64.tar.gz"
  tar -C "$DIST" -czf "$TARBALL" "Grok_Bot_${VERSION}_linux_x64"
  echo "tarball $TARBALL"

  "${ROOT}/scripts/package-deb.sh" \
    "${DIST}/Grok_Bot_${VERSION}_linux_x64" "$VERSION" "$DIST"
fi

if [[ "$DEB_ONLY" -eq 0 ]] && command -v mksquashfs >/dev/null; then
  APPDIR="${WORKDIR}/AppDir"
  mkdir -p "${APPDIR}/usr/bin" "${APPDIR}/usr/share/applications"
  cp -a "${STAGE}/." "${APPDIR}/usr/bin/"
  if [[ -f "${STAGE}/grok-bot.png" ]]; then
    cp "${STAGE}/grok-bot.png" "${APPDIR}/grok-bot.png"
    cp "${STAGE}/grok-bot.png" "${APPDIR}/.DirIcon"
    for size in 16 22 24 32 48 64 128 256; do
      mkdir -p "${APPDIR}/usr/share/icons/hicolor/${size}x${size}/apps"
      cp "${STAGE}/grok-bot.png" "${APPDIR}/usr/share/icons/hicolor/${size}x${size}/apps/grok-bot.png"
    done
  fi
  cat > "${APPDIR}/grok-bot.desktop" <<EOF
[Desktop Entry]
Name=Grok Bot
Comment=Grok Bot (unofficial Linux build)
Exec=grok-bot --no-sandbox --class=grok-bot
Icon=grok-bot
Type=Application
Categories=Network;
Terminal=false
StartupNotify=true
StartupWMClass=grok-bot
X-AppImage-Version=${VERSION}
EOF
  cp "${APPDIR}/grok-bot.desktop" "${APPDIR}/usr/share/applications/"
  install -m 0755 "${ROOT}/packaging/AppRun" "${APPDIR}/AppRun"

  TOOL="${CACHE}/appimagetool"
  if [[ ! -x "$TOOL" ]]; then
    curl -fL --retry 3 -o "$TOOL" \
      "https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-x86_64.AppImage"
    chmod +x "$TOOL"
  fi
  APPIMAGE="${DIST}/Grok_Bot_${VERSION}_x86_64.AppImage"
  if ARCH=x86_64 "$TOOL" --appimage-extract-and-run "$APPDIR" "$APPIMAGE"; then
    chmod +x "$APPIMAGE"
    echo "appimage $APPIMAGE"
  else
    echo "warn: AppImage step failed; tarball and .deb are still in dist/" >&2
  fi
fi

echo "done ${VERSION}"
ls -lh "$DIST"
