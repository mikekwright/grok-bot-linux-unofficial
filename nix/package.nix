# Nix port of scripts/build.sh: extract the official Windows installer,
# fuse the app with the nixpkgs Electron runtime, and replace Windows-only
# native addons with Linux builds. Fully pinned by ../upstream.json, so the
# whole build runs inside the Nix sandbox with no impure downloads.
{ lib
, stdenv
, fetchurl
, p7zip
, asar
, python3
, nodejs
, makeWrapper
, wrapGAppsHook3
, patchelf
, glib
, gtk3
, gsettings-desktop-schemas
, dconf
, librsvg
, electron_42
, upstream
}:

let
  electronDist = "${electron_42}/libexec/electron";

  # Linux replacements for the native addons vendored in the official
  # payload. Versions must match scripts/fix-natives.py. The better-sqlite3
  # prebuild is built against the Electron 42 ABI (electron-v146), so it is
  # coupled to the electron_42 runtime above.
  betterSqlite3Prebuild = fetchurl {
    url = "https://github.com/WiseLibs/better-sqlite3/releases/download/v12.11.1/better-sqlite3-v12.11.1-electron-v146-linux-x64.tar.gz";
    hash = "sha256-4gIa7tgN5PFSElJeMFZXVqqueQ5o4yKd9tE0X0OAMiE=";
  };
  treeSitterPkg = fetchurl {
    url = "https://registry.npmjs.org/tree-sitter/-/tree-sitter-0.21.1.tgz";
    hash = "sha256-Sdjt9rNM1xmj5EoM4VQhH5lgOe7mtqSyl8PoT3ZtbXA=";
  };
  treeSitterBashPkg = fetchurl {
    url = "https://registry.npmjs.org/tree-sitter-bash/-/tree-sitter-bash-0.21.0.tgz";
    hash = "sha256-I9viz05KMQLRhYpgsAYjhEp5Y4ei0VN0ZS2ZbtsXPjQ=";
  };
  whichlangPkg = fetchurl {
    url = "https://registry.npmjs.org/whichlang-node-linux-x64-gnu/-/whichlang-node-linux-x64-gnu-0.2.1.tgz";
    hash = "sha256-HFbx2J7RhXK2LJhGHOj1nPxnWHQhi3IQNIIuX4+FpWE=";
  };
in
stdenv.mkDerivation {
  pname = "grok-bot";
  version = upstream.version;

  src = fetchurl {
    url = upstream.url;
    hash = upstream.hash;
  };

  nativeBuildInputs = [ p7zip asar python3 nodejs makeWrapper wrapGAppsHook3 patchelf ];
  buildInputs = [ glib gtk3 gsettings-desktop-schemas dconf librsvg ];

  dontWrapGApps = true;
  dontStrip = true;
  dontPatchELF = true;

  sourceRoot = ".";
  unpackPhase = ''
    runHook preUnpack

    7z x -y $src -onsis >/dev/null
    payload="$(find nsis -type f \( -name 'app-64.7z' -o -name 'app-32.7z' \) | head -1)"
    [ -n "$payload" ] || { echo "app-64.7z missing from NSIS payload" >&2; exit 1; }
    7z x -y "$payload" -owinapp >/dev/null

    runHook postUnpack
  '';

  buildPhase = ''
    runHook preBuild

    if [ ! -f winapp/resources/app.asar ] && [ -f winapp/app.asar ]; then
      mkdir -p winapp/resources
      mv winapp/app.asar winapp/resources/app.asar
      [ -d winapp/app.asar.unpacked ] && mv winapp/app.asar.unpacked winapp/resources/
    fi
    [ -f winapp/resources/app.asar ] || { echo "resources/app.asar missing" >&2; exit 1; }

    mkdir -p stage/resources
    cp winapp/resources/app.asar stage/resources/app.asar
    if [ -d winapp/resources/app.asar.unpacked ]; then
      cp -r winapp/resources/app.asar.unpacked stage/resources/
    fi
    chmod -R u+w stage

    asar extract stage/resources/app.asar asar-tmp
    chmod -R u+w asar-tmp

    deps=stage/resources/app.asar.unpacked/dist/deps
    [ -d "$deps" ] || { echo "missing $deps" >&2; exit 1; }

    if [ -d "$deps/better-sqlite3" ]; then
      mkdir ex-bs
      tar -xzf ${betterSqlite3Prebuild} -C ex-bs
      node="$(find ex-bs -name better_sqlite3.node | head -1)"
      install -Dm755 "$node" "$deps/better-sqlite3/build/Release/better_sqlite3.node"
      echo "better-sqlite3 linux prebuild installed"
    else
      echo "skip better-sqlite3 (not in payload)"
    fi

    if [ -d "$deps/tree-sitter" ]; then
      mkdir ex-ts
      tar -xzf ${treeSitterPkg} -C ex-ts
      rm -rf "$deps/tree-sitter/build"
      mkdir -p "$deps/tree-sitter/prebuilds/linux-x64"
      install -m755 ex-ts/package/prebuilds/linux-x64/*.node "$deps/tree-sitter/prebuilds/linux-x64/"
      echo "tree-sitter linux prebuild installed"
    else
      echo "skip tree-sitter (not in payload)"
    fi

    if [ -d "$deps/tree-sitter-bash" ]; then
      mkdir ex-tsb
      tar -xzf ${treeSitterBashPkg} -C ex-tsb
      rm -rf "$deps/tree-sitter-bash/build"
      mkdir -p "$deps/tree-sitter-bash/prebuilds/linux-x64"
      install -m755 ex-tsb/package/prebuilds/linux-x64/*.node "$deps/tree-sitter-bash/prebuilds/linux-x64/"
      echo "tree-sitter-bash linux prebuild installed"
    else
      echo "skip tree-sitter-bash (not in payload)"
    fi

    if [ -d "$deps/whichlang-node" ]; then
      mkdir ex-wl
      tar -xzf ${whichlangPkg} -C ex-wl
      install -m755 ex-wl/package/*.linux-x64-gnu.node "$deps/whichlang-node/"
      echo "whichlang-node linux prebuild installed"
    else
      echo "skip whichlang-node (not in payload)"
    fi

    if [ -d "$deps/cursor-proclist" ]; then
      mkdir -p "$deps/cursor-proclist/build/Release"
      $CC -shared -fPIC -O2 -I${nodejs}/include/node \
        ${../native/cursor_proclist.c} \
        -o "$deps/cursor-proclist/build/Release/cursor_proclist.node" \
        -DNODE_GYP_MODULE_NAME=cursor_proclist
      echo "cursor_proclist linux /proc addon"
    else
      echo "skip cursor-proclist (not in payload)"
    fi

    if [ -d "$deps/@anysphere/tree-chunk-napi" ]; then
      $CC -shared -fPIC -O2 -I${nodejs}/include/node \
        ${../native/napi_stub.c} \
        -o "$deps/@anysphere/tree-chunk-napi/tree-chunk-napi.linux-x64-gnu.node" \
        -DNODE_GYP_MODULE_NAME=tree_chunk_napi
      echo "tree-chunk-napi stub"
    else
      echo "skip tree-chunk-napi (not in payload)"
    fi

    # Prebuilt C++ addons expect a global libstdc++, which NixOS does not
    # have; give every Linux .node an explicit rpath into the nix store.
    find "$deps" -name '*.node' -type f | while read -r node; do
      if [ "$(head -c4 "$node" | tail -c3)" = "ELF" ]; then
        patchelf --set-rpath "${lib.makeLibraryPath [ stdenv.cc.cc.lib ]}" "$node"
      fi
    done

    python3 - "$deps" <<'PY'
    import sys
    from pathlib import Path

    deps = Path(sys.argv[1])
    bad = []
    for path in deps.rglob("*.node"):
        rel = str(path.relative_to(deps))
        if "/prebuilds/win32-" in f"/{rel}" or ".win32-" in path.name:
            continue
        if path.read_bytes()[:2] == b"MZ":
            bad.append(rel)
    if bad:
        sys.exit("Windows .node still loadable on Linux:\n" + "\n".join(bad))
    print("native fix ok")
    PY

    python3 - asar-tmp ${../packaging/linux-entry.cjs} <<'PY'
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

    rm -rf asar-tmp/dist/deps
    mkdir -p asar-tmp/dist
    cp -r "$deps" asar-tmp/dist/deps
    asar pack asar-tmp stage/resources/app.asar

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    appdir=$out/lib/grok-bot
    mkdir -p "$appdir/resources"

    for entry in ${electronDist}/*; do
      case "$(basename "$entry")" in
        electron|resources) ;;
        *) ln -s "$entry" "$appdir/" ;;
      esac
    done
    # The binary itself is copied (not symlinked) so /proc/self/exe stays
    # inside $appdir and Electron resolves resources/app.asar next to it,
    # keeping app.isPackaged and process.resourcesPath correct.
    install -m755 ${electronDist}/electron "$appdir/grok-bot"

    cp stage/resources/app.asar "$appdir/resources/app.asar"
    if [ -d stage/resources/app.asar.unpacked ]; then
      cp -r stage/resources/app.asar.unpacked "$appdir/resources/"
    fi
    chmod -R u+w,go+rX-w "$appdir/resources"

    icon="$(find asar-tmp -name 'app-icon*.png' | head -1 || true)"
    if [ -n "$icon" ]; then
      install -Dm644 "$icon" "$out/share/icons/hicolor/256x256/apps/grok-bot.png"
      install -Dm644 "$icon" "$appdir/grok-bot.png"
    fi
    install -Dm644 ${../packaging/grok-bot.desktop} \
      "$out/share/applications/grok-bot.desktop"

    runHook postInstall
  '';

  postFixup = ''
    makeWrapper "$out/lib/grok-bot/grok-bot" "$out/bin/grok-bot" \
      "''${gappsWrapperArgs[@]}" \
      --set-default CHROME_DEVEL_SANDBOX "${electronDist}/chrome-sandbox" \
      --add-flags "--class=grok-bot" \
      --add-flags "\''${NIXOS_OZONE_WL:+\''${WAYLAND_DISPLAY:+--ozone-platform-hint=auto}}"
  '';

  meta = {
    description = "Unofficial Linux build of the Grok Bot desktop app";
    homepage = "https://github.com/jakob-bu/grok-bot-linux-unofficial";
    license = lib.licenses.unfree;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    platforms = [ "x86_64-linux" ];
    mainProgram = "grok-bot";
  };
}
