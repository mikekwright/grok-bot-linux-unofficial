# Grok Bot for Linux

Unofficial Ubuntu/Linux build of the **Grok Bot** desktop app.

Cursor ships Grok Bot for macOS and Windows only. This repo does the same
thing the [Codex Mac-to-Linux port](https://github.com/ilysenko/codex-desktop-linux)
did: take the official Electron app, put it on a Linux Electron runtime,
and replace the Windows-only native addons.

It is **not** an xAI or Cursor product. Linux is unsupported by them.

## What you get

The official Grok Bot UI — bots, the shared computer, sign-in with your
Cursor account — running as a native Linux app. No Wine.

The latest stable upstream release is resolved dynamically through Cursor's
update service. The current Linux runtime is **Electron 42.1.0** (x86_64).

## Ubuntu / Debian

```bash
sudo apt install p7zip-full curl unzip build-essential python3 \
  libfuse2 fakeroot
# Node.js 20+ (Ubuntu 24.04: sudo apt install nodejs npm  is too old;
# use https://github.com/nvm-sh/nvm or NodeSource)

git clone <this-repo> grok-bot-linux
cd grok-bot-linux
make update

grok-bot
```

`make update` downloads, rebuilds, validates, and installs only when Cursor
has published a newer stable version. The final package installation uses the
normal graphical administrator prompt (or `sudo` when no graphical session is
available). It builds only the `.deb`; `make build` remains the command for all
distribution formats.

Or skip the package and run the tree directly:

```bash
make build
version="$(make -s detect)"
"./dist/Grok_Bot_${version}_linux_x64/grok-bot" \
  --no-sandbox --ozone-platform-hint=auto
```

AppImage (needs FUSE 2):

```bash
chmod +x dist/Grok_Bot_*_x86_64.AppImage
./dist/Grok_Bot_*_x86_64.AppImage
```

Sign in with the same Cursor / SuperGrok account you use on the Mac app.
Bots live on the cloud computer; this build is the remote control.

## Nix / NixOS

The repo is a flake. Unlike `make build`, the Nix build is fully pinned by
`upstream.json` (upstream version, installer URL, and SRI hash), so it is
reproducible and runs entirely inside the Nix sandbox. The runtime is the
nixpkgs `electron_42` package instead of the GitHub zip.

```bash
nix run .                 # build and launch from a checkout
nix profile install .     # or install it
```

In a NixOS configuration:

```nix
{
  inputs.grok-bot.url = "github:<your-user>/<your-fork>";

  # then either take the package directly:
  environment.systemPackages = [
    inputs.grok-bot.packages.x86_64-linux.default
  ];

  # or use the overlay (adds pkgs.grok-bot):
  nixpkgs.overlays = [ inputs.grok-bot.overlays.default ];
}
```

The package is marked `unfree` (it repacks the proprietary upstream app),
so set `nixpkgs.config.allowUnfree = true` (or an `allowUnfreePredicate`)
when consuming it through the overlay.

Refresh the pin after Cursor publishes a new version:

```bash
make pin        # queries Cursor's update API, rewrites upstream.json
nix build       # rebuilds against the new pin
```

## Keeping a fork current

`.github/workflows/update-upstream.yml` runs `scripts/update-pin.sh` on a
daily schedule (and on manual dispatch). When Cursor publishes a new
stable version it rewrites `upstream.json`, validates that the pinned
release builds with `nix build .#grok-bot`, and commits the new pin back
to the repo. Fork the repo, enable Actions, and the flake input in your
NixOS config picks up each new version on your next `nix flake update`.

## Other distros

The tarball in `dist/` is a self-contained Electron tree. On Fedora /
Arch, install GTK3, NSS, ALSA, and Mesa, then:

```bash
tar -xzf dist/Grok_Bot_*_linux_x64.tar.gz
./Grok_Bot_*_linux_x64/grok-bot --no-sandbox --ozone-platform-hint=auto
```

## Build options

| Command | Result |
|---|---|
| `make detect` | Newest stable version from Cursor's update API |
| `make build` | Tarball + `.deb` + AppImage in `dist/` |
| `make update` | Build, validate, and install only when needed |
| `./scripts/update.sh --check` | Compare installed and latest versions |
| `./scripts/build.sh X.Y.Z` | Pin a specific upstream version |
| `./scripts/build.sh --exe ~/Downloads/Grok_Bot_X.Y.Z_Setup.exe` | Use an installer you already downloaded |
| `make install-updater` | Add `grok-bot-update` to `~/.local/bin` |
| `make pin` | Refresh `upstream.json` for the Nix build |
| `nix build .#grok-bot` | Sandboxed, fully pinned Nix build |

If Chromium's sandbox cannot take setuid (containers, some Ubuntu
defaults), the `/usr/bin/grok-bot` wrapper adds `--no-sandbox`. Extra
Electron flags go in `~/.config/grok-bot/electron-flags.conf`, one per
line.

NVIDIA + black window: add `--ozone-platform=x11` to that file.

## Updates

The in-app updater does not install this unofficial Linux build. Install the
one-command updater once from the repository:

```bash
make install-updater
```

After that, update from any directory with:

```bash
grok-bot-update
```

Close Grok Bot before installing an available update. Routine upstream
updates write only ignored files under `.cache/` and `dist/`; they do not edit
the checkout or require a Git commit. Repository changes are needed only when
Cursor changes the app packaging, Electron ABI, or native dependencies.

The updater retains the installed `.deb` and at most one previous `.deb` for
rollback, and removes superseded cached upstream installers. Cursor's update
response currently does not provide a checksum, so the installer cannot be
cryptographically pinned: the updater instead requires HTTPS, allow-lists the
exact download host and path, and validates the resulting Debian package's
identity and required contents before installation.

## How this compares to the Mac app

| | Official Mac app | This Linux build |
|---|---|---|
| UI / bots / cloud computer | yes | same `app.asar` |
| Sign-in | Cursor account | same |
| Native addons | Mach-O | rebuilt or replaced for Linux |
| Auto-update | official | rebuild from the new Windows installer |
| Support | Cursor | none (community) |

The Mac `.dmg` is not used here. Extracting it on Linux is awkward, and
its native modules are still the wrong ABI. The Windows NSIS installer
unpacks with `7z` and is the source every working community port uses.
Details: [docs/how-it-works.md](docs/how-it-works.md).

## Requirements

- x86_64 Linux, glibc 2.34+ (Ubuntu 22.04 or newer)
- Eligible Grok Bot plan (same as the official apps)
- Build machine: `p7zip-full`, `curl`, `unzip`, `g++`, `python3`, Node 20+

This repository never commits the official installer, `app.asar`, or
built binaries. Those are produced on your machine.

## License

Scripts and Linux-native sources in this repo: [MIT](LICENSE).

Grok Bot belongs to xAI / Cursor. Electron belongs to the Electron
project. See [NOTICE.md](NOTICE.md).
