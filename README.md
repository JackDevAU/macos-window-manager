# niri-mac

A niri-style scrollable-tiling window manager for macOS, written in Odin, using
only the **public Accessibility API** (no SIP changes, no private APIs).

macOS won't let you replace its compositor, so this is a window *manager* that
repositions real windows via AX — the same approach as AeroSpace, but aiming at
niri's scrollable-column model. See [`initial-plan.md`](initial-plan.md) for the
full feasibility study and architecture.

## Status

Built and verified (milestones M0–M5):

- **Read** — enumerate every window (CoreGraphics + AX), with titles/roles/frames.
- **Write** — move / resize / raise / maximize windows via AX.
- **Direct ops** — Rectangle/Magnet-style snap, grid, and cross-monitor moves on
  the focused window (CLI-triggered; bind to keys with your own tool).
- **Scrollable-strip engine** — niri's model as a pure, unit-tested package
  (`layout/`): columns on an infinite strip, open-without-resize, minimal-scroll,
  width presets, vertical stacking, consume/expel. Visualize with `./wm strip-demo`.
- **Daemon** — `wm daemon` holds the strip and listens on a unix socket; `wm <cmd>`
  drives it. It **starts tiling immediately**; `wm live off` (or `Alt+T`) pauses the
  effector into a dry-run that only logs the layout it would apply.

Still to come: AX observers for live add/remove, emulated workspaces, and
(optionally) built-in global hotkeys. See the plan.

## Build

```sh
./build.sh          # compiles the AppKit shim + the Odin app -> ./wm
```

Requires the Odin compiler (`brew install odin`) and the Xcode command-line
tools. The process needs **Accessibility** permission (System Settings →
Privacy & Security → Accessibility) — granting it to your terminal lets `./wm`
inherit the permission during development.

## Usage

```
./wm list                      # enumerate all on-screen windows (CGWindowList + AX)
./wm focused                   # show the focused window + its display
./wm displays                  # list displays and usable (visibleFrame) areas

./wm snap <preset>             # snap the focused window within its display
./wm maximize                  # = snap maximize
./wm center                    # = snap center (60%)
./wm move-monitor <next|prev>  # move the focused window to another display

./wm poke [App]                # demo: move/resize/maximize/park/restore a window
./wm strip-demo                # visualize the scrollable-strip engine (moves nothing)
```

### daemon (scrollable tiling)

```sh
./wm daemon            # run the daemon; starts TILING immediately
./wm sync              # (re)build the strip from current standard windows
./wm state             # show the strip + the layout the effector would apply
./wm focus-left | focus-right | focus-up | focus-down
./wm move-left | move-right        # move the focused column
./wm width                          # cycle focused column width (1/3 1/2 2/3)
./wm mode columns | monocle | grid  # layout: scrollable columns / one window per screen / grid
./wm consume | expel                # merge/split windows within a column
./wm focus-monitor <next|prev>      # focus the next/prev display
./wm move-to-monitor <next|prev>    # send focused window to the next/prev display
./wm workspace <n>                  # switch workspace (per-monitor; others hidden)
./wm move-to-workspace <n>          # send focused window to workspace n
./wm hide-mode offscreen | minimize # how off-view windows are hidden (default offscreen)
./wm live on | off                  # on = tile real windows (default); off = dry-run
./wm stop                           # stop the daemon
```

### Running headless

The daemon is a server (unix socket at `/tmp/niri-mac.sock`); every `wm <cmd>` is
a client, so you "attach" just by running a command from any shell — no terminal
needs to stay open.

```sh
just daemon-bg        # detach the daemon (survives closing the terminal)
just service-install  # or: install a LaunchAgent so it starts headless at login
just logs             # follow its output (tail /tmp/niri-mac.log)
wm state              # attach: inspect the current strip from anywhere
wm stop               # stop it
just service-uninstall
```

Under `launchd`/detached the daemon runs as the `wm` binary directly (not your
terminal), so grant **`wm` itself** Accessibility + Input Monitoring if AX moves
or hotkeys don't work — those permissions are per-binary.

The daemon **auto-tracks** windows: it reconciles against the live window set on
every command and on a background tick, so opening/closing windows updates the
strip with no manual `sync`. When tiling is on, new windows **auto-tile**.
Windows are partitioned across emulated **workspaces** (not native Spaces); only
the focused workspace is laid out.

**Multi-monitor:** each physical display is its own independent tiling area (niri's
per-output model) — windows tile only within the display they're on, never stretched
across both. A new window is homed on whichever display it opened on. Each monitor
has its own workspaces. Move focus or windows between displays with the hotkeys below
(or `wm focus-monitor` / `wm move-to-monitor`). Displays are ordered left→right, and
plugging/unplugging one re-tiles automatically. **Each display has its own status
bar** listing the windows on that display, so you can see at a glance what's where;
a dot (●) on a bar marks the monitor that currently has focus.

### Global hotkeys (built-in)

The daemon installs a global keyboard tap. **Requires Input Monitoring
permission** (System Settings → Privacy & Security → Input Monitoring → enable
your terminal) — this is separate from Accessibility. The daemon prints whether
hotkeys are active on startup. Default keymap (Alt = the modifier):

| key | action | key | action |
|---|---|---|---|
| `Alt+H` / `Alt+L` | focus left / right | `Alt+Shift+H/L` | move column left / right |
| `Alt+J` / `Alt+K` | focus down / up (within column) | `Alt+R` | cycle column width (⅓ ½ ⅔) |
| `Alt+Shift+J/K` | focus next / prev monitor | `Alt+Ctrl+J/K` | move window to next / prev monitor |
| `Alt+M` | maximize column (full width, toggle) | `Alt+T` | toggle tiling on/off |
| `Alt+Z` | fullscreen: one window per screen (toggle) | `Alt+G` | toggle grid / columns |
| `Alt+,` / `Alt+.` | consume / expel window | | |
| `Alt+1`…`Alt+9` | focus the n-th window | `Alt+Shift+1`…`9` | move focused window to slot n |
| `Cmd+Tab` / `Cmd+Shift+Tab` | switch to next / previous window | | |

Focus navigation (arrows, `Alt+1-9`, `Cmd+Tab`) **raises and activates the real
window** (gives it keyboard focus), not just the focus ring. `Cmd+Tab` overrides
the system app switcher — whether it fully suppresses the macOS overlay can vary.

Workspaces are on the CLI for now: `wm workspace <n>` / `wm move-to-workspace <n>`.

Only Alt-modified keys are inspected; everything else passes through untouched
(normal typing is never read). `Alt+T` toggles live tiling; turning it off
un-minimizes any windows the tiler had hidden.

### Focus ring

The daemon draws a blue border around the focused window (a transparent,
click-through overlay), drawn at the window's actual position and following focus
as you navigate.

The daemon **starts tiling immediately** and arranges all managed windows into
the strip — **disable any other window manager first**, or they'll fight. Use
`wm live off` (or `Alt+T`) to pause into a dry-run that only logs the layout.

### snap presets

| preset | meaning | | preset | meaning |
|---|---|---|---|---|
| `maximize` | fill display | | `tl` `tr` `bl` `br` | quarters |
| `center` | centered 60% | | `l3` `c3` `r3` | thirds |
| `left` `right` | halves | | `l23` `r23` | two-thirds (left/right) |
| `top` `bottom` | halves | | | |

### Binding to keys

These are one-shot commands (like `yabai -m ...`), so bind them with any hotkey
tool. Example [skhd](https://github.com/koekeishiya/skhd):

```
alt - h : /path/to/wm snap left
alt - l : /path/to/wm snap right
alt - f : /path/to/wm maximize
alt - n : /path/to/wm move-monitor next
```

## Layout

- `main.odin` — CLI entry + command implementations
- `ipc.odin` — unix-domain-socket server/client (daemon IPC)
- `daemon.odin` — the daemon: holds the strip + window registry, applies the effector
- `macos/` — bindings: `macos.odin` (CF/AX/CG), `displays.odin` (displays +
  focused window), `manage.odin` (window enumeration + minimize), `screens.m`
  (tiny AppKit shim for `visibleFrame` + frontmost pid)
- `layout/` — pure, unit-tested engine: snap presets, cross-monitor remap, and
  the scrollable strip (`strip.odin`); run with `odin test layout`
