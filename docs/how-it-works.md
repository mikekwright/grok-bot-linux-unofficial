# How the Linux port works

Grok Bot is an Electron app. Official downloads exist for Windows and
macOS. A first-party Linux `.deb` existed briefly on Cursor's CDN and was
withdrawn; staff have said Linux is unsupported.

The same approach that [codex-desktop-linux](https://github.com/ilysenko/codex-desktop-linux)
originally used for OpenAI's Mac app applies here, with one practical
difference: on Linux it is much easier to start from the **Windows NSIS
installer** than from a macOS `.dmg`.

## Why not the Mac app?

A Mac build is a valid source of `app.asar`, but:

- The `.dmg` is an Apple disk image. Extracting it on Linux needs extra
  tools and is brittle.
- Native addons inside the Mac app are Mach-O binaries. They cannot be
  `dlopen`'d on Linux, so they would still have to be replaced.
- The Windows installer is an NSIS self-extractor. `7z` unpacks it
  without Wine. The payload is `app-64.7z` → `resources/app.asar` plus
  `resources/app.asar.unpacked`.

So this project uses:

```
https://downloads.cursor.com/grokbot/stable/win32-x64/<ver>/Grok_Bot_<ver>_Setup.exe
```

The Mac Intel DMG is also public at
`.../darwin-x64/<ver>/Grok_Bot_<ver>_x64.dmg` if you want to compare
asar contents. It is not used by the build.

## Pipeline

1. **Detect version.** There is no public `latest.yml`. `scripts/detect-version.sh`
   HEAD-probes semver candidates on the CDN.
2. **Extract.** `7z x Setup.exe` then `7z x app-64.7z`.
3. **Runtime.** Download the official Electron Linux zip that matches the
   Windows exe. The version is read from the exe at build time (currently
   **42.11.x**, Chrome 148); `ELECTRON_VERSION` overrides it. Rename `electron` to
   `grok-bot` and copy Chromium helpers (`icudtl.dat`, `.pak`, `locales`,
   `chrome-sandbox`, …).
4. **Native modules.** Windows `.node` files are PE (`MZ`). Linux
   `dlopen` would crash. `scripts/fix-natives.py` replaces whatever the
   payload actually ships:
   - `tree-sitter` / `tree-sitter-bash` — public npm linux-x64 prebuilds
   - `cursor-proclist` — Linux `/proc` implementation in `native/`
   - `sand-*` private addons — empty N-API stubs so `require()` succeeds;
     their callers check the exports and fall back when they are missing
   - `@anysphere/jpeg-napi` — no Linux binary ships and the source is
     private, so it is left as is. JPEG rendition rendering is unavailable;
     everything else works.

   The payload's `runtime-deps-manifest.json` lists the required addons. An
   addon the port does not know stops the build and prints its name and
   exported functions.
5. **Repack `app.asar`** so packed and unpacked `dist/deps` stay in sync.
6. **Desktop identity.** A small CJS wrapper becomes `package.json` `main`
   so Wayland sees `grok-bot` / `grok-bot.desktop`.
7. **Package.** Tarball, Ubuntu/Debian `.deb` (`/opt/grok-bot`), and
   AppImage.

## What this does not do

- It does not crack sign-in or skip plan checks. You still authenticate
  with Cursor in a browser.
- It does not redistribute the official installer. Artifacts are built
  locally from a download you trigger.
- It cannot keep the in-app Windows/macOS auto-updater working. Rebuild
  when a new version appears on the CDN (`make detect && make build`).

## Related work

Community ports that independently arrived at the same Electron swap:

- [glorics/grok-bot-linux](https://github.com/glorics/grok-bot-linux)
- [Nichokas/grokbot-linux-port](https://github.com/Nichokas/grokbot-linux-port)
