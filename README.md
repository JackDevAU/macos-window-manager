# niri-mac

A [niri](https://github.com/YaLTeR/niri)-style scrollable-tiling window manager
for macOS, written in Odin. Windows live in a horizontal strip of columns you
scroll through, instead of a grid that reshuffles every time you open something.
It moves real windows through the public Accessibility API, with no SIP changes.
The only private API it touches is `_AXUIElementGetWindow` (long stable, also
used by yabai) to map an AX window to its CGWindowID for ScreenCaptureKit.

## Build

Needs the Odin compiler (`brew install odin`), the Xcode command-line tools,
and [`just`](https://github.com/casey/just) (`brew install just`) as the task
runner.

```sh
just build          # compiles the AppKit shim + the Odin app -> ./wm
just check          # type-check without producing a binary
just test           # run the pure layout unit tests
just --list         # see all recipes
```

`just build` just runs `./build.sh`, so you can call that directly if you'd
rather not install `just`.

### Environment variables

- **`WM_CODESIGN_ID`** (optional): an `Apple Development: ...` signing identity
  used to sign `./wm` after each build. macOS ties Accessibility / Input
  Monitoring grants to the signature, and ad-hoc signatures change every build
  (revoking the grants), so setting a stable identity means you only grant the
  permissions once. Find yours with `security find-identity -p codesigning`;
  leave it unset to skip signing.

  ```sh
  WM_CODESIGN_ID="Apple Development: you@example.com (TEAMID)" just build
  ```

## Use

```sh
just daemon         # run the daemon in the foreground; starts tiling immediately
./wm daemon Safari  # manage only one app (safe for a live test next to your current WM)
just daemon-bg      # run detached (survives closing the terminal); logs to /tmp/niri-mac.log
just logs           # follow the detached/service daemon's output
```

To have it start at login, `just service-install` writes a LaunchAgent (remove
it with `just service-uninstall`). Under launchd the daemon runs as the `wm`
binary itself, so grant `wm` (not your terminal) the two permissions.

Grant the two permissions macOS prompts for on first run (both under System
Settings > Privacy & Security):

- **Accessibility**: to move and resize windows.
- **Input Monitoring**: for the global hotkeys.

Grant them to whatever runs `wm` (your terminal in development, or the `wm`
binary itself when run headless). **Disable any other window manager first** or
they'll fight. Pause tiling any time with `Alt+T` (or `wm live off`); stop the
daemon and restore windows with `wm stop`. Run `wm help` for the full list of
CLI commands.

## Hotkeys

The modifier is **Alt** (Option).

| Keys | Action |
| --- | --- |
| `Alt + h/j/k/l` | focus left / down / up / right |
| `Alt + Shift + h/l` | move column left / right |
| `Alt + Shift + j/k` | focus next / prev monitor |
| `Alt + Ctrl + j/k` | move focused window to next / prev monitor |
| `Alt + r` | cycle column width (1/3, 1/2, 2/3) |
| `Alt + m` | maximize column width |
| `Alt + z` | fullscreen: one window per screen (toggle) |
| `Alt + g` | toggle grid / columns |
| `Alt + f` | float / unfloat the focused window |
| `Alt + , / .` | consume / expel within a column |
| `Alt + Shift + ,` | dock window with its same-app siblings |
| `Alt + 1-9` | focus window n |
| `Alt + Shift + 1-9` | move focused window to slot n |
| `Ctrl + 1-9` | switch to workspace n |
| `Ctrl + Shift + 1-9` | move focused window to workspace n |
| `Alt + t` | pause / resume tiling |
| `Alt + s` | open the settings window |
| `Alt + p` | mirror the focused window to the share Stage |
| `Cmd + Tab` | native macOS switcher (the WM follows your pick) |
