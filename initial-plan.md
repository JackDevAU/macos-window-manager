# Feasibility & Architecture: a niri-style scrollable-tiling window manager for macOS, in Odin

## Context

You want niri's experience — windows arranged as **columns on an infinite horizontal strip you scroll through with the keyboard** — running on macOS, written in Odin, using **only the public Accessibility (AX) API (never disabling SIP)**.

The hard truth up front: **niri is a Wayland compositor — it *owns* rendering and window placement. macOS will not let you replace its compositor (WindowServer is closed).** So you cannot port niri or build "a compositor" on macOS. What you *can* build is a **window manager that simulates niri's scrollable-tiling model by repositioning real macOS windows via the Accessibility API** — exactly the mechanism AeroSpace, Amethyst, and (partly) yabai use. With the "public AX only, no SIP" constraint you've chosen the most durable path: this is precisely AeroSpace's design philosophy, but with niri's *scrollable-column* layout model instead of i3's BSP tiling.

**Verdict: feasible, with one unavoidable UX gap** — you cannot get niri's smooth GPU-composited slide animations. Repositioning is per-window IPC through AX and will be instant/coarse, not buttery. Everything else (scrollable columns, keyboard-driven focus scrolling, width presets, multi-monitor, emulated workspaces) is achievable. This plan is feasibility + architecture only; **no code will be written until you approve.**

## What "niri on macOS" actually means

| niri (Wayland compositor) | This project (macOS AX window manager) |
|---|---|
| Owns compositing & rendering | Repositions existing app windows via AX API |
| Literal infinite off-screen canvas | **Logical** infinite strip in memory; only visible columns mapped to on-screen rects, rest parked off-screen/hidden |
| GPU-animated scrolling | Instant (or coarse stepped) repositioning — no smooth slide |
| Per-monitor strips + vertical workspaces | Per-monitor strips + **emulated** workspaces (not native Spaces) |
| Full control of every surface | Best-effort; some apps resist move/resize/off-screen placement |

The signature interaction — keyboard scroll left/right between columns, new windows append a column to the right without resizing others, focus-follows-scroll — is fully reproducible. The *literal* infinite canvas is not; we approximate it (see below).

## The core technical idea: logical strip → visible viewport

niri's infinite strip cannot exist literally, because macOS apps clamp/ignore positions that put them fully off-screen, and you can't render off-screen surfaces you don't own. Instead:

1. Keep niri's model **in memory**: per-monitor `Strip` of `Column`s, each `Column` a vertical stack of `Tile`s (windows), plus a scroll offset / focused-column index.
2. On every change, a **pure `layout()` function** computes which columns fall inside the on-screen viewport and the exact rect for each visible window.
3. An **effector** applies those rects via AX (`kAXPositionAttribute` / `kAXSizeAttribute`), and **parks scrolled-out windows off-screen** (AeroSpace's trick for hidden workspaces — move to a far corner), with **minimize/hide as a fallback** for apps that refuse off-screen placement.
4. "Scrolling right" = recompute: visible columns shift left, the next column's window animates (or snaps) on-screen. The illusion of an infinite strip emerges from continuously re-mapping a small visible set.

This is the make-or-break mechanism and is de-risked early (Milestone 2).

## Direct window ops: sizing, grids, and cross-monitor (Rectangle/Magnet-style)

Alongside the managed scrollable strip, you want **fast, ad-hoc commands to resize windows and throw them across monitors** — maximize, halves, quarters/grid, thirds, center, grow/shrink, and "send to next display." These are a *thinner* layer than full tiling (just compute a rect, set the AX frame) and deliver value immediately, so they ship **before** the full strip engine.

**Commands (all keybind-driven, niri-style):**
- **Maximize / near-maximize / center** — fill the target display's `visibleFrame`, or a centered fraction of it.
- **Halves** — left/right/top/bottom 50%.
- **Quarters / grid** — corners; cycle a window through grid cells; configurable grid (2×2, 3×2, etc.).
- **Thirds** — cycle ⅓ / ½ / ⅔ widths (this is also niri's column-width preset, so the same operation serves both modes).
- **Grow / shrink** — nudge size in fixed steps from the focused edge.
- **Move to next/previous monitor** — reposition into the target display's frame, **preserving the window's relative rect** (same fractional position/size on the new display) or re-fitting to a chosen preset.
- **Move within strip / to another monitor's strip** — the tiling-mode equivalent (moves a column between per-monitor strips).

**Cross-monitor mechanics:** macOS uses one **global coordinate space** spanning all displays (origin at the main display's top-left; secondary displays sit at positive *or negative* offsets). "Send to next monitor" = enumerate displays via `CGGetActiveDisplayList` / `NSScreen`, take each display's `visibleFrame` (excludes menu bar / Dock), map the window's current fractional rect onto the destination display's frame, and `AXUIElementSetAttributeValue` position+size. Straightforward given M2's primitives + display geometry — the only subtleties are negative-offset displays and per-display scale factors.

**How these coexist with tiling (important design point):** a window is either **managed** (placed by the strip engine) or **floating** (free-placed by these direct ops). Direct snap/grid commands on a *floating* window behave exactly like Rectangle/Magnet. The same commands on a *managed* (tiled) window are interpreted by the layout engine as model edits — e.g. "½ width" sets that column's width preset, "send to next monitor" moves the column to the other display's strip — so one set of keybinds works consistently in both modes. A toggle (e.g. float/unfloat a window) switches a window between the two.

## macOS subsystems & APIs (all reachable from Odin)

The AX / CoreGraphics / Carbon / CoreFoundation APIs are **plain C** → bind with Odin `foreign import`. Only the app lifecycle (NSApplication/NSWorkspace/NSScreen) is Objective-C → use Odin's objc intrinsics or a tiny clang-compiled ObjC shim.

- **Accessibility permission**: `AXIsProcessTrustedWithOptions` (prompts the user). *C.*
- **Enumerate + manipulate windows**: `AXUIElementCreateApplication(pid)`, `AXUIElementCopyAttributeValue` / `AXUIElementSetAttributeValue` with `kAXWindowsAttribute`, `kAXPositionAttribute`, `kAXSizeAttribute`, `kAXFocusedAttribute`, `kAXMainAttribute`, `kAXMinimizedAttribute`, `kAXTitleAttribute`, `kAXRoleAttribute`, `kAXSubroleAttribute`; `AXValueCreate`/`AXValueGetValue` for `CGPoint`/`CGSize`; `AXUIElementPerformAction(win, kAXRaiseAction)`. *C.*
- **Window identity**: `CGWindowListCopyWindowInfo` (CoreGraphics) to enumerate on-screen windows, owner pid, layer, window ID. *C.* Matching AX windows ↔ CGWindowIDs is cleanest via the single private symbol `_AXUIElementGetWindow` — **this is the one private call AeroSpace tolerates.** Per your "public only" choice, the plan **defaults to a public-API matching heuristic** (pid + frame + title + z-order from CGWindowList) and treats `_AXUIElementGetWindow` as an *optional, clearly-isolated* fallback you can enable later. Flagged as a decision point.
- **Observe changes**: `AXObserverCreate` + `AXObserverAddNotification` for `kAXWindowCreatedNotification`, `kAXUIElementDestroyedNotification`, `kAXFocusedWindowChangedNotification`, `kAXWindowMoved`/`Resized`; integrates as a `CFRunLoopSource`. *C.*
- **Global hotkeys** (niri is keyboard-driven): start with Carbon `RegisterEventHotKey` (simplest, C). Upgrade to `CGEventTap` (`kCGHeadInsertEventTap`) if you want niri-style modifier-held chord interception (needs the AX permission we already hold). *C.*
- **Displays**: `CGGetActiveDisplayList` + `NSScreen.visibleFrame` (excludes menu bar). *C + objc.*
- **App lifecycle / focus**: `NSApplication` as an `LSUIElement` menu-bar agent (no Dock icon) hosting the run loop; `NSWorkspace` notifications for app launch/terminate; `NSRunningApplication.activate`. *objc (intrinsics or shim).*

## Odin interop strategy

- Odin has first-class **C FFI** → hand-write a small bindings package (~30 AX/CG/Carbon/CF functions + constants). This is more maintainable than depending on the partial generated `darwodin` bindings (harold-b), whose coverage is selective and may omit ApplicationServices/HIServices (AX). Use `vendor:darwin/Foundation` for NSString/CF convenience where helpful.
- Link the C frameworks via foreign import attributes / linker flags: `ApplicationServices`, `CoreGraphics`, `Carbon`, `CoreFoundation`, `AppKit`.
- **Objective-C lifecycle** (NSApplication delegate, menu-bar agent): Odin's `intrinsics.objc_send` + `@(objc_class=...)` work, but subclassing / app-delegate setup is fiddly (documented gotchas: "mark type must be of zero size", manual `objc_allocateClassPair`/`class_addMethod`). **Recommended escape hatch: a ~30-line clang-compiled ObjC/C shim** for NSApplication boot + run loop, called from Odin — this de-risks Milestone 0 and keeps the Odin side pure C-FFI.
- **CoreFoundation glue**: AX returns `CFTypeRef`/`CFArrayRef`/`AXValueRef`/`CFStringRef` → bind the handful of CF helpers needed (`CFRelease`, `CFArrayGetCount`/`GetValueAtIndex`, `CFStringGetCString`, `CFDictionaryGetValue`). Mind ownership/`CFRelease` to avoid leaks.

## Proposed architecture (layered)

1. **Platform bindings** (`macos/`): raw `foreign import` of CF/AX/CG/Carbon + objc/shim for AppKit. Thin Odin-friendly wrappers: `window_frame(win)`, `window_set_frame(win, rect)`, `app_windows(pid) -> []Window`, `focus(win)`.
2. **Window registry**: tracks managed windows (AX element, pid, app, current frame, identity key); reconciled from AX observer events + a periodic CGWindowList poll; honors an allow/deny list.
3. **Layout engine — the niri core** (`layout/`, *pure Odin, zero macOS deps, unit-tested*): `Strip` → `[]Column` → `[]Tile`; scroll offset / focused index; operations (insert window, focus L/R/U/D, move column, width presets ⅓/½/⅔, consume/expel into/out of column, center-on-focus). Also holds **floating** windows and the **direct-ops geometry math** — pure functions `rect_for_preset(window, display, preset)` (maximize / halves / quarters-grid / thirds / center / grow / shrink) and `rect_on_display(window, src_display, dst_display)` (cross-monitor remap, preserving fractional rect). Same preset functions serve both floating windows and managed column widths. Output: pure `layout(strips, displays, viewport) -> ([]WindowPlacement, []WindowToPark)`.
4. **Effector**: applies placements via the platform layer; parks off-view windows off-screen (minimize/hide fallback); **diffs against last-applied frames** to skip redundant AX writes (they're expensive).
5. **Input / keybinds**: register hotkeys → layout commands. Start with a hardcoded keymap; later a config file (niri uses KDL — a simple TOML/KDL-ish parser).
6. **App shell**: `LSUIElement` menu-bar agent; NSApplication run loop hosting CFRunLoop sources (AX observers, hotkeys, workspace notifications); Accessibility-permission bootstrap on first launch.

## Milestones (each independently demoable; de-risk the unknowns first)

- **M0 — Toolchain spike.** Install Odin; build a hello-world linking AppKit; confirm objc intrinsics (or the shim) work on your macOS + Odin version. *Proves the build path.*
- **M1 — Permission + read.** Request Accessibility trust; enumerate apps and their windows via AX; print titles/frames/roles. *Proves the read path.*
- **M2 — Manipulate + the big unknown.** Move/resize/raise/focus a chosen window; **test off-screen parking across canary apps (Safari, Terminal, a fixed-size dialog, an Electron app)** to learn real cooperation limits early. *De-risks the make-or-break mechanism before building on it.*
- **M3 — Direct window ops (early usable tool).** Display geometry via `CGGetActiveDisplayList`/`NSScreen.visibleFrame`; hotkeys → maximize / center / halves / quarters-grid / thirds-cycle / grow-shrink, and **move window to next/previous monitor** (preserving fractional rect). This is a working Rectangle/Magnet-style manager on its own, built purely on M2 primitives + the pure `rect_for_preset`/`rect_on_display` functions. *Ships value before the strip engine exists.*
- **M4 — Layout engine + tests.** Pure-Odin `Strip`/`Column`/`Tile` + niri operations + `layout()`, reusing M3's preset math, with `odin test` unit tests. No macOS calls.
- **M5 — Wire up scrollable tiling.** AX observers feed the registry; hotkeys drive strip operations; effector applies layout. Single-monitor scrollable tiling across 3–4 cooperating apps; float/unfloat toggle so direct ops and tiling share keybinds.
- **M6 — Robustness.** Multi-monitor strips + cross-monitor column moves; emulated workspaces; app launch/quit reconciliation; fixed-size/unresizable/full-screen handling; focus-follows; config file.
- **M7 — Polish.** Width presets, optional stepped animation, menu-bar UI, edge cases.

## Risks & honest limitations (the parts that won't match niri)

- **No smooth animation.** AX repositioning is per-window IPC; transitions are instant or coarse and may flicker with many windows. This is the #1 gap vs real niri — AeroSpace deliberately chose "instant, no animation" for the same reason.
- **App cooperation varies.** Fixed-size windows, dialogs, native-fullscreen apps (each lives in its own Space, largely unmanageable), and some Electron/Java/SDL apps clamp or ignore AX position/size. Needs allow/deny lists and graceful skipping.
- **Off-screen parking is imperfect.** Some apps refuse full off-screen placement → fallback to minimize/hide, which subtly changes the "infinite strip" feel.
- **Spaces & multi-monitor.** Public AX can't see/manage windows on *other native Spaces*. Mitigation (AeroSpace's): **emulate workspaces** rather than use native Spaces, and recommend disabling "Displays have separate Spaces."
- **Distribution.** Non-sandboxed (AX requires it) → **no Mac App Store**; users must grant Accessibility (possibly Screen Recording for titles on some OS versions); notarization needed for clean distribution.
- **macOS version drift.** AX behavior shifts across releases; the public-API/no-SIP choice is the most durable available — which is exactly why it's the right call here.
- **Odin objc maturity.** Workable but app-delegate/subclassing is fiddly; the ObjC shim is the pragmatic hedge.

## Verification (per milestone — this is a plan, so "verify" = how each step is proven)

- **M0**: binary launches, prints, links AppKit cleanly.
- **M1**: prints a correct live window list (titles/frames) for several running apps.
- **M2**: a visible window demonstrably moves/resizes/focuses; documented table of which canary apps honor off-screen parking vs need fallback.
- **M3**: keybinds visibly snap the focused window to maximize/half/quarter/third and **throw it to another monitor** keeping its relative size/position; works on a 2-display setup. (First genuinely usable build.)
- **M4**: `odin test ./layout` green; strip + preset operations covered by unit tests with no OS dependency.
- **M5**: manual demo — open 4 apps, scroll between columns via keyboard, new windows append columns without resizing existing ones; float/unfloat toggle works.
- **M6/M7**: multi-monitor strips + cross-monitor column move + workspace-switch demo; config file drives keybinds; canary-app regression pass.

## Open decision (flagged, not blocking)

- **`_AXUIElementGetWindow`**: the cleanest AX↔CGWindowID match uses this one private symbol (AeroSpace's sole exception). Plan defaults to a **public-only heuristic** per your constraint, with this isolated as an optional opt-in if the heuristic proves unreliable. Decide when M2 data is in hand.

## Prior art to study (closest analogues)

- **AeroSpace** (nikitabobko) — public-AX, no-SIP, emulated workspaces. The architectural template; differs only in layout model (i3 BSP vs our niri scroll).
- **niri** (YaLTeR) — the layout model & UX to replicate (columns, scrolling, width presets, consume/expel).
- **yabai** — what *more* is possible *if* you ever relaxed the SIP constraint (you've chosen not to).
- **PaperWM** — scrollable tiling on GNOME Shell; niri's own inspiration; useful for the "simulate scroll on a managed desktop" mindset.
