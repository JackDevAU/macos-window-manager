# Multi-monitor support — plan

Status: **M9a + M9b done** (2026-06-26). The daemon now holds `g.monitors`
(one `Monitor` per display, each with its own viewport + workspaces + strip),
assigns each window to the display it sits on, and tiles every monitor into its
own viewport — no more stretching across displays. `Alt+Shift+J/K` focuses the
next/prev monitor; `Alt+Ctrl+J/K` (or `wm move-to-monitor next|prev`) moves the
focused window between displays. Each display has its own status bar
(M9c) listing the windows on it, with a dot marking the focused monitor. Display
add/remove triggers a `full_resync` (rebuild monitors + re-adopt windows), so
nothing is stranded — a cheap stand-in for M9d. **Still deferred:** the focus ring
following the active monitor (cosmetic) and proper per-window hotplug re-homing (M9d).

## Concepts (keep these distinct)

- **Monitor** = a physical display (`CGDirectDisplayID`).
- **Workspace** = a virtual desktop (a `Strip`); switching hides the others. Today
  workspaces are global and live on the one display.
- These are orthogonal. niri's model is **per-output (per-monitor) workspaces**:
  each monitor owns its own set of workspaces/strip. That's the target model.

## What already exists to build on

- `mac.active_displays(buf)` → all `CGDirectDisplayID`s.
- `mac.visible_frame(display_id)` → usable rect per display (NSScreen shim).
- `mac.display_for_point(px, py)` → which display contains a point.
- `move-monitor next|prev` (main.odin) + the pure `remap` geometry in `layout/`
  (unit-tested) — moves a window's frame from one display's visibleFrame to
  another's. Never run live.
- `mac.wm_menu_bar_height()` — only the main display has the menu bar.

## Target architecture

Introduce a per-monitor container and make the daemon iterate monitors instead
of assuming one viewport.

```odin
Monitor :: struct {
    display_id: u32,
    viewport:   layout.Rect,   // this display's usable area (below its bar)
    bar_rect:   layout.Rect,
    workspaces: [dynamic]Workspace, // per-monitor (niri model)
    focused_ws: int,
}
```

Daemon changes:
- `g.monitors: [dynamic]Monitor` + `g.focused_monitor: int` replace the single
  `viewport`/`bar_rect`/`workspaces`/`focused_ws`.
- `Managed.display_id` (or `monitor_idx`) records which monitor a window is on.
- **Rebuild monitors** on startup and on display hotplug (see below): for each
  active display, compute `visible_frame` → `Monitor`. The main display reserves
  the menu-bar strip (existing logic); secondary displays have no menu bar.
- **Assign windows to monitors** in `reconcile()`: a new window's monitor =
  `display_for_point(center of its frame)`. Add it to that monitor's focused
  workspace strip (not a single global strip).
- **Effector** runs `compute_layout` per monitor with that monitor's viewport,
  applying frames; off-screen hide logic is per-monitor.

## Bars

One bar per display (each pinned to its own display's top), built from that
monitor's strip. The status cluster (clock/wifi/battery) can stay on the main
display's bar only, or repeat — decide later. `wm_bar_set` already takes an
explicit `x,y,w,h`, so per-display bars need N bar windows (generalize the single
`gBar` in screens.m into an array keyed by display).

## Focus model + hotkeys

- Focus = `(focused_monitor, that monitor's focused_ws/col/tile)`.
- **`Alt+Shift+J` / `Alt+Shift+K`** = focus next / previous monitor (decision:
  these are free today — Shift is ignored on J/K). Wrap around. On switch, raise
  that monitor's focused window + move the ring there.
  - Plain `Alt+J/K` stays in-column up/down; `Alt+H/L` stays column left/right;
    `Alt+Shift+H/L` stays move-column. No conflicts.
- **Move focused window to next/prev monitor**: separate chord — proposed
  `Alt+Ctrl+J/K` (or reuse the existing `move-monitor next|prev` command). Uses
  the `remap` geometry to translate the frame, reassigns `Managed.monitor`, drops
  it into the target monitor's strip, re-tiles both.
- `Alt+1–9` window-focus and `wm workspace N` stay within the focused monitor.

## Display hotplug

- Register a `CGDisplayReconfigurationCallback` (or poll `active_displays` on the
  reconcile timer) to detect add/remove.
- On **add**: build a new `Monitor`, re-home windows now sitting on it.
- On **remove**: move its windows/strip onto the focused (or main) monitor so
  nothing is stranded off-screen.

## Suggested increments

- **M9a** ✅ — multiple `Monitor`s, per-display viewport + window→monitor assignment,
  tile each display independently.
- **M9b** ✅ — `Alt+Shift+J/K` monitor focus + `Alt+Ctrl+J/K` move-window-to-monitor.
- **M9c** ✅ — per-display bars (each lists its own windows, focused monitor dotted).
  *(focus ring following the active monitor still deferred — cosmetic.)*
- **M9d** — hotplug handling. *(partial: display-count change triggers full_resync;
  proper per-window re-homing on add/remove still TODO.)*

## Open questions

- Per-monitor workspaces (niri model) vs one global workspace set shown on the
  focused monitor? Plan assumes per-monitor.
- One status cluster (main bar) or repeated on every bar?
- Window-move-to-monitor chord: `Alt+Ctrl+J/K` vs keeping it CLI-only.
- Mixed-DPI / scaling across displays (frames are in global CG points — should be
  fine, but verify on a Retina + non-Retina mix).
