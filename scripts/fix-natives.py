#!/usr/bin/env python3
"""Replace Windows PE native addons with Linux ELF binaries.

Public modules are taken from npm / GitHub prebuilds that match the
versions vendored in the official Windows payload. Private Cursor
modules are compiled from native/ in this repository.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import tarfile
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DEPS: Path | None = None

# Private Windows/macOS-only addons whose JavaScript callers fall back
# gracefully when the exports are missing, so an empty N-API stub suffices.
SAND_STUB_ADDONS = (
    "sand-address-lookup",
    "sand-card-text-recognition",
    "sand-devicecheck",
    "sand-notification-settings",
    "sand-window-capture",
)


def is_pe(path: Path) -> bool:
    try:
        with path.open("rb") as handle:
            return handle.read(2) == b"MZ"
    except OSError:
        return False


def run(cmd: list[str], cwd: Path | None = None) -> None:
    subprocess.check_call(cmd, cwd=cwd)


def npm_pack_extract(spec: str, dest: Path) -> Path:
    dest.mkdir(parents=True, exist_ok=True)
    tmp = Path(tempfile.mkdtemp(prefix="gb-npm-"))
    run(["npm", "pack", "--ignore-scripts", "--silent", spec], cwd=tmp)
    tgz = next(tmp.glob("*.tgz"))
    with tarfile.open(tgz, "r:gz") as archive:
        archive.extractall(tmp / "ex")
    pkg = tmp / "ex" / "package"
    if not pkg.is_dir():
        raise RuntimeError(f"npm pack {spec} did not contain package/")
    return pkg


def download(url: str, dest: Path) -> None:
    dest.parent.mkdir(parents=True, exist_ok=True)
    run(["curl", "-fL", "--retry", "3", "-A", "grok-bot-linux", "-o", str(dest), url])


def compile_native(src: Path, dest: Path, name: str) -> None:
    dest.parent.mkdir(parents=True, exist_ok=True)
    include = os.environ.get("GROKBOT_NODE_INCLUDE", "")
    if not include or not Path(include, "node_api.h").is_file():
        raise RuntimeError("GROKBOT_NODE_INCLUDE must point at node_api.h")
    compiler = "g++" if src.suffix in {".cc", ".cpp", ".cxx"} else "gcc"
    run(
        [
            compiler,
            "-shared",
            "-fPIC",
            "-O2",
            "-s",
            f"-I{include}",
            str(src),
            "-o",
            str(dest),
            f"-DNODE_GYP_MODULE_NAME={name}",
        ]
    )


def copy_linux_prebuild(extracted_pkg: Path, dest_dir: Path) -> Path:
    candidates = list(extracted_pkg.glob("prebuilds/linux-x64/*.node"))
    candidates += list(extracted_pkg.glob("**/*.linux-x64-gnu.node"))
    if not candidates:
        raise RuntimeError(f"no linux-x64 .node in {extracted_pkg}")
    src = candidates[0]
    dest_dir.mkdir(parents=True, exist_ok=True)
    dest = dest_dir / src.name
    shutil.copy2(src, dest)
    return dest


def present(rel: str) -> bool:
    assert DEPS is not None
    return (DEPS / rel).exists()


def main() -> None:
    global DEPS
    unpacked = Path(os.environ["GROKBOT_UNPACKED"])
    DEPS = unpacked / "dist" / "deps"
    if not DEPS.is_dir():
        raise SystemExit(f"missing {DEPS}")

    tmp = Path(tempfile.mkdtemp(prefix="gb-native-"))
    native = ROOT / "native"

    if present("better-sqlite3"):
        tgz = tmp / "bs.tar.gz"
        download(
            "https://github.com/WiseLibs/better-sqlite3/releases/download/"
            "v12.11.1/better-sqlite3-v12.11.1-electron-v146-linux-x64.tar.gz",
            tgz,
        )
        with tarfile.open(tgz, "r:gz") as archive:
            archive.extractall(tmp / "ex")
        node = next((tmp / "ex").rglob("better_sqlite3.node"))
        dest = DEPS / "better-sqlite3" / "build" / "Release" / "better_sqlite3.node"
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(node, dest)
        print("better-sqlite3:", dest)
    else:
        print("skip better-sqlite3 (not in payload)")

    if present("tree-sitter"):
        ts_pkg = npm_pack_extract("tree-sitter@0.21.1", tmp / "tree-sitter")
        ts_dir = DEPS / "tree-sitter"
        shutil.rmtree(ts_dir / "build", ignore_errors=True)
        copy_linux_prebuild(ts_pkg, ts_dir / "prebuilds" / "linux-x64")
        print("tree-sitter linux prebuild installed")
    else:
        print("skip tree-sitter (not in payload)")

    if present("tree-sitter-bash"):
        tsb_pkg = npm_pack_extract("tree-sitter-bash@0.21.0", tmp / "tree-sitter-bash")
        tsb_dir = DEPS / "tree-sitter-bash"
        shutil.rmtree(tsb_dir / "build", ignore_errors=True)
        copy_linux_prebuild(tsb_pkg, tsb_dir / "prebuilds" / "linux-x64")
        print("tree-sitter-bash linux prebuild installed")
    else:
        print("skip tree-sitter-bash (not in payload)")

    if present("whichlang-node"):
        wl_pkg = npm_pack_extract(
            "whichlang-node-linux-x64-gnu@0.2.1", tmp / "whichlang"
        )
        wl_node = next(wl_pkg.glob("*.linux-x64-gnu.node"))
        dest_dir = DEPS / "whichlang-node"
        dest_dir.mkdir(parents=True, exist_ok=True)
        shutil.copy2(wl_node, dest_dir / wl_node.name)
        print("whichlang-node:", wl_node.name)
    else:
        print("skip whichlang-node (not in payload)")

    if present("cursor-proclist"):
        compile_native(
            native / "cursor_proclist.c",
            DEPS / "cursor-proclist" / "build" / "Release" / "cursor_proclist.node",
            "cursor_proclist",
        )
        print("cursor_proclist linux /proc addon")
    else:
        print("skip cursor-proclist (not in payload)")

    if present("@anysphere/tree-chunk-napi"):
        compile_native(
            native / "napi_stub.c",
            DEPS / "@anysphere" / "tree-chunk-napi" / "tree-chunk-napi.linux-x64-gnu.node",
            "tree_chunk_napi",
        )
        print("tree-chunk-napi stub")
    else:
        print("skip tree-chunk-napi (not in payload)")

    for addon in SAND_STUB_ADDONS:
        if not present(addon):
            print(f"skip {addon} (not in payload)")
            continue
        name = addon.replace("-", "_")
        compile_native(
            native / "napi_stub.c",
            DEPS / addon / "build" / "Release" / f"{name}.node",
            name,
        )
        print(f"{addon} stub")

    live_pe: list[str] = []
    for path in DEPS.rglob("*.node"):
        if not is_pe(path):
            continue
        rel = str(path.relative_to(DEPS))
        if "/prebuilds/win32-" in f"/{rel}" or ".win32-" in path.name:
            continue
        live_pe.append(rel)
    if live_pe:
        raise SystemExit("Windows .node still loadable on Linux:\n" + "\n".join(live_pe))
    print("native fix ok")


if __name__ == "__main__":
    main()
