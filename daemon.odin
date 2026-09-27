package main

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:thread"
import "core:time"
import CF "core:sys/darwin/CoreFoundation"
import "layout"
import mac "macos"

// A managed window: the strip refers to it by Window_Id; this is the real thing.
Managed :: struct {
	pid:     i32,
	ax:      mac.AXUIElement, // retained
	cgwin:   u32, // CGWindowID (0 if unknown) — non-AX frame reads for slow apps
	title:   string, // allocated
	app:     string, // allocated (owning app name)
	mon:     int, // which monitor (index into g.monitors) this window tiles on
	ws:      int, // workspace within that monitor
	hidden:  Hidden, // hidden by us, and how (parked stays enumerable; minimized doesn't)
	floated: bool, // user-excluded from tiling (Alt+F) — left where it is
	loose:   bool, // AX-slow app (a game): full-screen column, minimal AX traffic
	req_w:   f64, // width we last asked this window to be (to detect clamping)
	placed:  layout.Rect, // frame the effector last applied (loose: skip repeat writes)
	orig:    layout.Rect, // frame when first managed, restored on un-tile
}

Workspace :: struct {
	strip: layout.Strip,
}

// A physical display with its own independent tiling area (niri's per-output
// model): its usable viewport and its own set of workspaces. Every monitor is
// always laid out — unlike workspaces, where only the focused one shows.
Monitor :: struct {
	display_id: u32,
	bounds:     layout.Rect, // full CGDisplayBounds at build time (staleness check)
	viewport:   layout.Rect, // this display's usable area (below its bar)
	bar_rect:   layout.Rect, // status bar strip across the top of this display
	workspaces: [dynamic]Workspace,
	focused_ws: int,
	live:       bool, // per-monitor tiling: false = freeform (windows left where they are)
}

Layout_Mode :: enum {
	Columns, // niri scrollable strip
	Monocle, // one window (the focused column) fills the screen; others scroll off
	Grid, // all windows in a grid
}

// Daemon state. Single instance, global so the IPC/hotkey/timer callbacks reach
// it. Windows live across emulated workspaces; only the focused one is laid out.
Daemon :: struct {
	monitors:        [dynamic]Monitor, // one per physical display, ordered left→right
	focused_monitor: int,
	reg:        map[layout.Window_Id]Managed,
	next_id:    u64,
	live:           bool, // false => dry-run effector (default)
	manage_app:     string,
	hide_offscreen: bool, // off-view windows: park off-screen (no animation) vs minimize
	mode:           Layout_Mode, // columns (scrollable strip) vs grid
	ignore_apps:    map[string]bool, // app names never adopted into tiling (keys allocated)
	menu_h:         f64, // native menu-bar height; clicks above it pass through to it
}

@(private = "file")
g: Daemon
@(private = "file")
g_listen_fd: posix.FD
@(private = "file")
g_tap: mac.CFMachPort
// After we set focus ourselves (a hotkey raise), skip this many fast ticks of
// click-sync so it can't snap focus back before our raise has taken effect.
@(private = "file")
g_focus_hold: int

// Countdown of fast ticks during which we try to sync the daemon's focus to the
// OS-frontmost window. Armed ONLY by a real mouse click (so it never fights
// hotkey navigation, which was the reason continuous polling was reverted). It
// takes a tick or two for the OS to make the clicked window frontmost.
@(private = "file")
g_click_sync: int

// The managed window we last followed the OS focus to. Lets the fast tick act only
// when the OS-frontmost window *changes* (native Cmd+Tab, Raycast, Spotlight, Dock),
// instead of re-syncing every tick. Updated whenever we deliberately focus a window.
@(private = "file")
g_last_synced_id: layout.Window_Id

// A window we asked to become frontmost but that hasn't activated yet. A loose
// app (Godot) activates asynchronously and slowly (~1s); until it does, the OS
// still reports the *previous* window as frontmost, so the OS-focus-follow tick
// would snap focus straight back off Godot ("go to Godot, it bounces back").
// While this is set, the follow tick is suppressed until this pid is actually
// frontmost or the deadline passes.
@(private = "file")
g_activating_pid: i32
@(private = "file")
g_activating_until: mac.CFAbsoluteTime

// A loose window the user has navigated onto but not yet settled on. We hold off
// raising/activating it (an expensive, slow AX op that also steals the app
// frontmost) until the cursor has dwelt on it — so spam-navigating *past* Godot
// never activates it, while stopping *on* it does (long wait is fine then).
@(private = "file")
g_pending_raise_id: layout.Window_Id
@(private = "file")
g_pending_raise_at: mac.CFAbsoluteTime

// The last window we enqueued a real focus write for, and — when a newer raise
// superseded a slow (loose) one that hadn't come frontmost yet — the superseded
// window. A slow app's activation can land ~1s after we asked; if the OS then
// reports THAT window frontmost, it's our own late write, not the user
// switching ("move past Godot, it drags you back"). The follow tick re-asserts
// instead of following, until the marker expires.
@(private = "file")
g_issued_raise_id: layout.Window_Id
@(private = "file")
g_stale_raise_id: layout.Window_Id
@(private = "file")
g_stale_raise_until: mac.CFAbsoluteTime

// A frontmost change seen for one tick, awaiting its confirming second tick.
// A one-tick blip (Outlook self-activating for a reminder while AX-flagged
// slow) must never yank focus; a real switch (Cmd+Tab, Dock) persists.
@(private = "file")
g_follow_candidate: layout.Window_Id

// How (whether) we've hidden a window. Parked windows keep a 6px on-screen
// peek, so they stay in the on-screen enumeration; minimized ones drop out.
Hidden :: enum {
	None,
	Parked, // slid off-view (hide_offscreen mode): still enumerable
	Minimized, // truly minimized: absent from the on-screen enumeration
}

// --- pure tick decisions (unit-tested in daemon_test.odin) -------------------

// A managed window absent from this tick's enumeration: is it really closed?
// A dead pid settles it — the app is gone, so is the window. Otherwise the
// window's own AX element is ground truth: probing it (ax_window_alive) answers
// .InvalidUIElement the instant it's gone, yet .Success for a window merely on
// another Space / hidden / minimized. That distinction is why the on-screen
// enumeration alone can't decide: it's Space-local, so a fullscreen app, a
// Space switch, or Cmd+H drops every managed window from it at once — reading
// that as "closed" mass-removed them, then re-adoption scattered them across
// monitors and stole focus.
//
// AX can be inconclusive (`!ax_decided`) for an AX-backed-off (slow) app, whose
// element we won't block on. Then fall back: the window server's FULL list
// (cg_listed) still knows an off-Space window exists — but it also KEEPS a
// closed off-screen (parked) window's id around a while, so it can only clear a
// slow app's window, never confirm one closed here; a window WE minimized is
// expected to be absent while its app lives; a parked/visible window without a
// CGWindowID rides the slow-lane batch (only a tick that covered its pid knows).
absent_window_closed :: proc(hidden: Hidden, pid_alive, pid_slow, pid_in_slow_batch: bool, cg_known, cg_listed: bool, ax_alive, ax_decided: bool) -> bool {
	if !pid_alive do return true
	if ax_decided do return !ax_alive // the element itself: alive means on another Space / hidden, not closed
	if cg_known do return !cg_listed
	if hidden == .Minimized do return false
	return !pid_slow || pid_in_slow_batch
}

// What the fast tick should do about a deferred (loose-window) raise.
Pending_Raise :: enum {
	Waiting, // focus still on it, dwell not yet elapsed — keep waiting
	Raise,   // focus dwelt on it long enough — raise/activate now
	Drop,    // focus moved on before it settled — never activate it
}

pending_raise_tick :: proc(pending, focused: layout.Window_Id, has_focused: bool, now, due: mac.CFAbsoluteTime) -> Pending_Raise {
	if !has_focused || focused != pending do return .Drop
	return now >= due ? .Raise : .Waiting
}

// While a window we activated is still coming frontmost, the OS-focus-follow
// tick is suppressed; the guard lifts once the pid is frontmost or we time out.
activation_guard_done :: proc(guard_pid, frontmost_pid: i32, now, deadline: mac.CFAbsoluteTime) -> bool {
	return frontmost_pid == guard_pid || now >= deadline
}

// What the follow tick should do about the OS-frontmost managed window.
Follow_Action :: enum {
	Ignore, // nothing managed frontmost, or no change since last sync
	Record, // frontmost is already the daemon's focus — just remember it
	Arm, // frontmost changed this tick — confirm on the next before acting
	Follow, // confirmed external switch (Cmd+Tab, Dock, Raycast) — adopt it
	Reassert, // our superseded slow raise landed late — put focus back on ours
}

follow_action :: proc(frontmost, last_synced, cur_focused: layout.Window_Id, has_cur: bool, stale: layout.Window_Id, stale_active: bool, candidate: layout.Window_Id) -> Follow_Action {
	if frontmost == 0 do return .Ignore
	if frontmost == last_synced do return .Ignore
	if has_cur && frontmost == cur_focused do return .Record
	if stale_active && frontmost == stale do return .Reassert
	if frontmost != candidate do return .Arm
	return .Follow
}

// What a post-click sync tick should do about the OS-frontmost managed window.
Click_Sync_Action :: enum {
	Wait, // nothing managed frontmost, or still the pre-click window — keep waiting
	Arm, // a new window came frontmost — confirm on the next tick before syncing
	Sync, // held frontmost two consecutive ticks: this is the click's target
}

click_sync_action :: proc(frontmost, cur_focused: layout.Window_Id, has_cur: bool, candidate: layout.Window_Id) -> Click_Sync_Action {
	if frontmost == 0 do return .Wait
	if has_cur && frontmost == cur_focused do return .Wait
	return frontmost == candidate ? .Sync : .Arm
}

// Issuing a raise for `new` supersedes the previous one. The old write can only
// land late (and steal focus back) if it went to the slow queue (a loose
// window) and its app hadn't come frontmost yet when it was superseded — a
// fast-queue write is either replaced in-queue or lands in milliseconds.
raise_superseded_late :: proc(prev, new: layout.Window_Id, prev_loose, prev_arrived: bool) -> bool {
	return prev != 0 && prev != new && prev_loose && !prev_arrived
}

FOCUS_HOLD_TICKS :: 3
CLICK_SYNC_TICKS :: 4
ACTIVATE_TIMEOUT :: mac.CFAbsoluteTime(2.0) // give up waiting for a window to come frontmost
LOOSE_RAISE_DWELL :: mac.CFAbsoluteTime(0.18) // settle time before raising a slow window

// A tap callback that overruns the WindowServer's budget has its keystroke
// passed through to the app (the stray ∆˚¬˙) and the tap disabled. Log any
// dispatch that gets near that budget so the culprit is visible in the log.
TAP_SLOW_MS :: 100.0

GAP :: 12
IDLE_MS :: 500
FOCUS_MS :: 120
BAR_H :: 28

// Windows smaller than this in either dimension are treated as alerts /
// notification popups and left floating (not adopted into the tiling strip).
MIN_TILE_W :: 200
MIN_TILE_H :: 120

// A window that comes back this many px narrower than we asked is treated as
// width-constrained (e.g. System Settings); neighbours pack against its real
// width so there's no gap.
WIDTH_TOL :: 24

// Virtual keycodes (ANSI) for the default Alt-based keymap.
KEY_H :: 4
KEY_J :: 38
KEY_K :: 40
KEY_L :: 37
KEY_R :: 15
KEY_COMMA :: 43
KEY_PERIOD :: 47
KEY_T :: 17
KEY_M :: 46
KEY_G :: 5
KEY_F :: 3 // toggle floating (exclude focused window from tiling)
KEY_S :: 1 // open the settings window
KEY_P :: 35 // mirror the focused window onto the share stage
KEY_Z :: 6 // toggle fullscreen / monocle (one window per screen)

HOTKEYS_TEXT :: `Alt + h/j/k/l               focus left / down / up / right
Alt + Shift + h/l           move column left / right
Alt + Shift + j/k           focus next / prev monitor
Alt + Ctrl + j/k            move focused window to next / prev monitor
Alt + r                    cycle column width (1/3 · 1/2 · 2/3)
Alt + m                    maximize column width
Alt + z                    fullscreen: one window per screen (toggle)
Alt + g                    toggle grid / columns
Alt + f                    float / unfloat the focused window
Alt + , / .                consume / expel within a column
Alt + Shift + ,            dock window with its same-app siblings
Alt + 1 – 9                focus window n
Alt + Shift + 1 – 9        move focused window to slot n
Ctrl + 1 – 9               switch to workspace n
Ctrl + Shift + 1 – 9       move focused window to workspace n
Alt + t                    pause / resume tiling
Alt + s                    open this settings window
Alt + p                    mirror the focused window to the share Stage
Cmd + Tab                  native macOS switcher (the WM follows your pick)`
KEY_TAB :: 48 // used with Cmd for the window switcher

run_daemon :: proc(manage_app: string = "") {
	// One app with a slow AX server (a game, Godot) must not freeze our run
	// loop: the event tap lives on it, so every keystroke system-wide queues
	// behind these synchronous AX calls. The real caps are per-element
	// (mac.ax_app / standard_windows) plus the per-pid slow-app backoff in the
	// macos package; this global cap is only a safety net for stray elements.
	mac.ax_set_global_timeout(mac.AX_CALL_TIMEOUT)

	g.reg = make(map[layout.Window_Id]Managed)
	g.ignore_apps = make(map[string]bool)
	g.next_id = 1 // id 0 is the "no window" sentinel throughout this file
	build_monitors() // one independent tiling area per physical display
	g.live = true // start tiling immediately (use `wm live off` / Alt+T to pause)
	g.manage_app = manage_app
	g.hide_offscreen = true // no-SIP smooth hide (no minimize animation)
	mac.wm_settings_set_handler(settings_cmd_cb) // settings-window buttons drive daemon commands

	listen_fd, ok := ipc_listen()
	if !ok {
		fmt.eprintln("could not open IPC socket")
		return
	}
	g_listen_fd = listen_fd

	rl := mac.CFRunLoopGetCurrent()

	// IPC socket as a run-loop source.
	fdref := mac.CFFileDescriptorCreate(nil, c.int(listen_fd), false, socket_cb, nil)
	mac.CFFileDescriptorEnableCallBacks(fdref, mac.kCFFileDescriptorReadCallBack)
	mac.CFRunLoopAddSource(rl, mac.CFFileDescriptorCreateRunLoopSource(nil, fdref, 0), mac.kCFRunLoopDefaultMode)

	// Global hotkeys via a CGEventTap. A keyboard tap needs Input Monitoring
	// permission (distinct from Accessibility); prompt if we don't have it.
	input_ok := bool(mac.CGPreflightListenEventAccess())
	if !input_ok {
		mac.CGRequestListenEventAccess() // shows the system prompt / adds us to the list
	}
	mask := mac.event_mask_bit(mac.kCGEventKeyDown) | mac.event_mask_bit(mac.kCGEventLeftMouseDown)
	g_tap = mac.CGEventTapCreate(mac.kCGSessionEventTap, mac.kCGHeadInsertEventTap, mac.kCGEventTapOptionDefault, mask, tap_cb, nil)
	if g_tap != nil {
		mac.CFRunLoopAddSource(rl, mac.CFMachPortCreateRunLoopSource(nil, g_tap, 0), mac.kCFRunLoopDefaultMode)
		mac.CGEventTapEnable(g_tap, true)
	}

	// Periodic reconcile (auto-track + auto-tile when live).
	interval := f64(IDLE_MS) / 1000.0
	timer := mac.CFRunLoopTimerCreate(nil, mac.CFAbsoluteTimeGetCurrent() + interval, interval, 0, 0, timer_cb, nil)
	mac.CFRunLoopAddTimer(rl, timer, mac.kCFRunLoopDefaultMode)

	// Faster tick: follow the OS focus (mouse clicks) and move the ring.
	fi := f64(FOCUS_MS) / 1000.0
	ftimer := mac.CFRunLoopTimerCreate(nil, mac.CFAbsoluteTimeGetCurrent() + fi, fi, 0, 0, focus_cb, nil)
	mac.CFRunLoopAddTimer(rl, ftimer, mac.kCFRunLoopDefaultMode)

	// Slow lane: AX-backed-off apps (Godot answers each AX call in ~255ms)
	// still deserve tiling. This worker enumerates their windows with patient
	// timeouts, blocking only itself; reconcile drains the results.
	g_slow_thread = thread.create_and_start(slow_lane_loop)

	// Writer threads: perform every window AX write off the main thread (see the
	// window-writer section). Two of them so slow (Godot) writes never stall the
	// fast windows queued behind them.
	g_fast_q.thread = thread.create_and_start(fast_writer_loop)
	g_slow_q.thread = thread.create_and_start(slow_writer_loop)

	scope := manage_app == "" ? "all apps" : manage_app
	fmt.printfln("niri-mac daemon listening on %s", SOCKET_PATH)
	fmt.printfln("  managing %s, TILING (use `wm live off` or Alt+T to pause)", scope)
	if g_tap != nil && input_ok {
		fmt.println("  hotkeys: ENABLED (Alt+hjkl focus, r=width m=maximize g=grid/columns f=float ,/.=consume/expel Alt+Shift+,=group 1-9=focus, Ctrl+1-9=workspace, t=tiling this monitor; Cmd+Tab is native)")
	} else {
		fmt.println("  hotkeys: NOT ACTIVE — grant Input Monitoring to your terminal in")
		fmt.println("           System Settings > Privacy & Security > Input Monitoring, then restart the daemon")
	}

	// Adopt and tile the current windows immediately, before entering the loop.
	reconcile(home_new_at_frame = true)
	run_effector(nil)

	// Run the AppKit event loop (not a bare CFRunLoopRun) so the settings window's
	// controls receive mouse events; it still services our tap/socket/timers.
	mac.wm_app_run()

	g_slow_quit = true
	if g_slow_thread != nil do thread.join(g_slow_thread)
	for w in g_slow_wins do mac.std_window_destroy(w)
	delete(g_slow_wins)

	// Stop the writer threads (wake them so they see the quit flag), then release
	// any retains still sitting in their queues.
	g_writer_quit = true
	sync.sema_post(&g_fast_q.sema)
	sync.sema_post(&g_slow_q.sema)
	if g_fast_q.thread != nil do thread.join(g_fast_q.thread)
	if g_slow_q.thread != nil do thread.join(g_slow_q.thread)
	drain_writer_queue(&g_fast_q)
	drain_writer_queue(&g_slow_q)

	mac.wm_bar_hide()
	mac.wm_ring_hide()
	restore_all() // put windows back where they were before exiting
	ipc_cleanup()
	clear_registry()
	destroy_monitors()
	delete(g.reg)
	for k in g.ignore_apps do delete(k)
	delete(g.ignore_apps)
	fmt.println("daemon stopped")
}

// --- monitors ---------------------------------------------------------------

// (Re)build g.monitors from the active displays: one Monitor per display, each
// with its own bar strip + viewport and a fresh single-workspace strip, ordered
// left→right by screen position so "next/prev monitor" navigation is spatial.
@(private = "file")
build_monitors :: proc() {
	g.monitors = make([dynamic]Monitor)
	g.menu_h = mac.wm_menu_bar_height() // reserve the top strip's clicks for the native menu bar

	main := mac.CGMainDisplayID()
	buf: [16]u32
	for id in mac.active_displays(buf[:]) {
		vf := mac.visible_frame(id)
		full := layout.Rect{f64(vf.origin.x), f64(vf.origin.y), f64(vf.size.width), f64(vf.size.height)}

		b := mac.CGDisplayBounds(id)

		mon: Monitor
		mon.display_id = id
		mon.bounds = {f64(b.origin.x), f64(b.origin.y), f64(b.size.width), f64(b.size.height)}
		mon.live = true // tiling on by default; Alt+T toggles this monitor
		mon.bar_rect = {full.x, full.y, full.w, BAR_H} // each display gets a bar across its top
		mon.viewport = {full.x, full.y + BAR_H, full.w, full.h - BAR_H} // windows tile below it
		mon.workspaces = make([dynamic]Workspace)
		append(&mon.workspaces, Workspace{strip = layout.make_strip(GAP)})
		append(&g.monitors, mon)
	}

	slice.sort_by(g.monitors[:], proc(a, b: Monitor) -> bool {return a.viewport.x < b.viewport.x})

	g.focused_monitor = 0
	for m, i in g.monitors do if m.display_id == main do g.focused_monitor = i
}

// True when the active display set no longer matches g.monitors: a display was
// added/removed/swapped (id not found) or changed resolution/arrangement
// (CGDisplayBounds differs from build time). Compares bounds, not visibleFrame,
// so transient menu-bar hides (fullscreen spaces) don't trigger churn.
@(private = "file")
monitors_stale :: proc(ids: []u32) -> bool {
	if len(ids) != len(g.monitors) do return true
	for id in ids {
		b := mac.CGDisplayBounds(id)
		cur := layout.Rect{f64(b.origin.x), f64(b.origin.y), f64(b.size.width), f64(b.size.height)}
		found := false
		for mon in g.monitors {
			if mon.display_id == id {
				found = mon.bounds == cur
				break
			}
		}
		if !found do return true
	}
	return false
}

@(private = "file")
destroy_monitors :: proc() {
	for &mon in g.monitors {
		for &w in mon.workspaces do layout.strip_destroy(&w.strip)
		delete(mon.workspaces)
	}
	delete(g.monitors)
	g.monitors = nil
}

// The monitor index whose display contains (px, py); falls back to the focused
// monitor when the point isn't on any known display.
@(private = "file")
monitor_for_point :: proc(px, py: f64) -> int {
	if disp, ok := mac.display_for_point(px, py); ok {
		for m, i in g.monitors do if m.display_id == disp do return i
	}
	return g.focused_monitor
}

// --- slow lane (worker thread) ----------------------------------------------
// Windows of AX-backed-off apps, enumerated off the main thread with patient
// timeouts so the event tap never waits on them. reconcile drains the batch.
g_slow_wins: [dynamic]mac.Std_Window // guarded by g_slow_mu
g_slow_mu: sync.Mutex
g_slow_quit: bool
g_slow_thread: ^thread.Thread

SLOW_LANE_MS :: 2000

slow_lane_loop :: proc() {
	for !g_slow_quit {
		wins := mac.slow_app_windows(g.manage_app)
		if len(wins) > 0 {
			sync.mutex_lock(&g_slow_mu)
			// Replace any undrained batch — newest data wins.
			for w in g_slow_wins do mac.std_window_destroy(w)
			clear(&g_slow_wins)
			for w in wins do append(&g_slow_wins, w)
			sync.mutex_unlock(&g_slow_mu)
		}
		delete(wins)
		// Sleep in short slices so daemon shutdown never waits the full period.
		for _ in 0 ..< (SLOW_LANE_MS / 250) {
			if g_slow_quit do break
			time.sleep(250 * time.Millisecond)
		}
	}
}

// --- window writer (worker threads) -----------------------------------------
// EVERY window move/resize/raise goes here, never on the main thread. The main
// thread runs the CGEventTap that all system input passes through, and it fires
// run_effector + raise_focused on every focus-nav hotkey; a synchronous AX
// write there blocks the tap for the app's full AX latency. That's cheap for a
// snappy app but not for Godot (~255ms) or a busy Electron app (Teams/Discord/
// Spotify), and it stacks with key-repeat — the "delay between panes". So the
// tap only mutates in-memory layout state (instant) and queues the AX writes.
//
// Two queues, each with its own thread: a FAST queue for snappy apps and a
// SLOW queue for loose (AX-slow) windows. A single shared thread would let one
// in-flight ~1s Godot write stall every fast window queued behind it — which is
// exactly why navigating *past* Godot dragged everything. Splitting them means
// fast windows never wait on Godot. Frames coalesce per window (a fast scroll
// enqueues many rects; only the last matters); focus keeps just the latest
// target. Every queued AXUIElement carries its own +1 retain, released once the
// op runs, so it stays valid even if the window closes first.
Frame_Write :: struct {
	ax:         mac.AXUIElement,
	rect:       layout.Rect,
	size_first: bool,
}

Writer_Queue :: struct {
	frames:    map[uintptr]Frame_Write, // key: ax pointer
	focus_ax:  mac.AXUIElement,
	focus_pid: i32,
	focus_set: bool,
	mu:        sync.Mutex,
	sema:      sync.Sema,
	thread:    ^thread.Thread,
}

g_fast_q: Writer_Queue
g_slow_q: Writer_Queue // loose (AX-slow) windows only
g_writer_quit: bool

enqueue_frame :: proc(ax: mac.AXUIElement, rect: layout.Rect, size_first: bool, loose: bool) {
	q := loose ? &g_slow_q : &g_fast_q
	sync.mutex_lock(&q.mu)
	if q.frames == nil do q.frames = make(map[uintptr]Frame_Write)
	key := uintptr(rawptr(ax))
	if old, ok := q.frames[key]; ok do CF.Release(CF.TypeRef(old.ax)) // superseded
	mac.CFRetain(CF.TypeRef(ax))
	q.frames[key] = Frame_Write{ax = ax, rect = rect, size_first = size_first}
	sync.mutex_unlock(&q.mu)
	sync.sema_post(&q.sema)
}

enqueue_focus :: proc(ax: mac.AXUIElement, pid: i32, loose: bool) {
	q := loose ? &g_slow_q : &g_fast_q
	sync.mutex_lock(&q.mu)
	if q.focus_set do CF.Release(CF.TypeRef(q.focus_ax)) // superseded
	mac.CFRetain(CF.TypeRef(ax))
	q.focus_ax = ax
	q.focus_pid = pid
	q.focus_set = true
	sync.mutex_unlock(&q.mu)
	sync.sema_post(&q.sema)
}

writer_loop :: proc(q: ^Writer_Queue) {
	for {
		sync.sema_wait(&q.sema)

		sync.mutex_lock(&q.mu)
		frames := make([dynamic]Frame_Write, 0, len(q.frames))
		for _, f in q.frames do append(&frames, f)
		clear(&q.frames)
		focus_ax := q.focus_ax
		focus_pid := q.focus_pid
		focus_set := q.focus_set
		q.focus_set = false
		quit := g_writer_quit
		sync.mutex_unlock(&q.mu)

		// These block for the target app's AX latency — but on THIS thread, not
		// the run loop. focus before frame: raising is what the user waits to see.
		if focus_set {
			mac.focus_window(focus_ax, focus_pid)
			CF.Release(CF.TypeRef(focus_ax))
		}
		for f in frames {
			mac.set_frame(f.ax, to_cg(f.rect), f.size_first)
			CF.Release(CF.TypeRef(f.ax))
		}
		delete(frames)

		if quit do return
	}
}

fast_writer_loop :: proc() { writer_loop(&g_fast_q) }
slow_writer_loop :: proc() { writer_loop(&g_slow_q) }

@(private = "file")
drain_writer_queue :: proc(q: ^Writer_Queue) {
	for _, f in q.frames do CF.Release(CF.TypeRef(f.ax))
	delete(q.frames)
	if q.focus_set do CF.Release(CF.TypeRef(q.focus_ax))
}

// --- run-loop callbacks (run on the main thread) ----------------------------

@(private = "file")
socket_cb :: proc "c" (f: mac.CFFileDescriptor, types: u64, info: rawptr) {
	context = runtime.default_context()
	stop := ipc_accept_once(g_listen_fd, daemon_handle)
	if stop {
		mac.wm_app_stop()
		return
	}
	mac.CFFileDescriptorEnableCallBacks(f, mac.kCFFileDescriptorReadCallBack)
}

@(private = "file")
timer_cb :: proc "c" (timer: mac.CFRunLoopTimer, info: rawptr) {
	context = runtime.default_context()
	// Display hotplug: if the active display set or any display's geometry no
	// longer matches what build_monitors captured (unplug, swap, resolution
	// change), rebuild the monitors and re-adopt windows from scratch so nothing
	// is tiled into a stale viewport (e.g. under the bar, or off-screen).
	buf: [16]u32
	ids := mac.active_displays(buf[:])
	if len(ids) == 0 do return // lid closed / displays asleep: rebuilding now would leave zero monitors and crash cur_mon; wait for wake
	if monitors_stale(ids) {
		full_resync()
		if g.live do run_effector(nil)
		mac.wm_bar_status_refresh()
		return
	}
	added, removed, retagged := reconcile()
	if g.live && (added > 0 || removed > 0 || retagged > 0) {
		run_effector(nil)
	}
	mac.wm_bar_status_refresh() // keep the clock/battery/wifi cluster current
	refresh_settings() // keep the open-window list live (no-op when closed)
}

// Fast tick: keep the focus ring on the daemon's focused window (also tracks the
// window if it moves). NOTE: continuous OS-focus polling (click-to-focus) was
// removed — it fought hotkey navigation because AX focus transfer isn't instant.
// A click-detecting approach (mouse-down event tap) is the right way to re-add it.
@(private = "file")
focus_cb :: proc "c" (timer: mac.CFRunLoopTimer, info: rawptr) {
	context = runtime.default_context()
	if len(g.monitors) == 0 do return // displays asleep/mid-reconfigure: cur_strip would crash; timer_cb rebuilds on wake

	// A slow window the user paused on: once the dwell passes and focus is still
	// there, raise/activate it (deferred from raise_focused). If focus has moved
	// on (spam-navigated past), just drop it — we never activate it.
	if g_pending_raise_id != 0 {
		cur, has := layout.focused_window(cur_strip())
		switch pending_raise_tick(g_pending_raise_id, cur, has, mac.CFAbsoluteTimeGetCurrent(), g_pending_raise_at) {
		case .Raise:
			if m, ok := g.reg[g_pending_raise_id]; ok {
				note_raise_issued(g_pending_raise_id)
				enqueue_focus(m.ax, m.pid, true)
				arm_activation_guard(m.pid)
			}
			g_pending_raise_id = 0
		case .Drop:
			g_pending_raise_id = 0 // focus left before it settled — skip it
		case .Waiting:
		}
	}

	// While a window we activated is still coming frontmost, don't let the
	// OS-focus-follow below bounce us back to whatever is frontmost right now.
	if g_activating_pid != 0 {
		if activation_guard_done(g_activating_pid, mac.wm_frontmost_pid(), mac.CFAbsoluteTimeGetCurrent(), g_activating_until) {
			g_activating_pid = 0
		} else {
			update_focus_ring()
			return
		}
	}

	if g_focus_hold > 0 {
		// A hotkey just raised a window; let it settle before any click-sync, so
		// a stale frontmost read can't snap focus back (the old polling bug).
		g_focus_hold -= 1
	} else if g_click_sync > 0 {
		g_click_sync -= 1
		if sync_focus_from_os() { // matched the clicked window into the strip
			g_click_sync = 0
			// The clicked window may live on another workspace/monitor: the sync
			// switched daemon focus there, but only the effector un-hides that
			// workspace and re-parks the old one. It also refreshes ring + bar;
			// on a plain same-workspace click nothing moved, so it's just that.
			run_effector(nil)
		}
	} else {
		// Follow the OS focus: native Cmd+Tab, Raycast, Spotlight, the Dock — any
		// activation of a window we manage. Acts only when the frontmost window
		// *changes*, holds steady for two ticks (a self-activating app's blip is
		// not a switch), and isn't a stale raise of our own landing late — so it
		// never fights hotkey nav (further guarded by g_focus_hold above). This
		// is what makes a "jump to a window" land even when we'd hidden it (other
		// workspace / off view): run_effector un-hides and re-tiles it.
		id, _ := frontmost_managed()
		cur, has := layout.focused_window(cur_strip())
		stale_active := g_stale_raise_id != 0 && mac.CFAbsoluteTimeGetCurrent() < g_stale_raise_until
		act := follow_action(id, g_last_synced_id, cur, has, g_stale_raise_id, stale_active, g_follow_candidate)
		g_follow_candidate = act == .Arm ? id : 0
		switch act {
		case .Record:
			g_last_synced_id = id
		case .Follow:
			g_last_synced_id = id
			focus_window_id(id)
			run_effector(nil) // switch workspace / un-hide / re-tile
			raise_focused() // re-assert focus after un-minimize
			update_bar()
		case .Reassert:
			g_stale_raise_id = 0
			raise_focused() // our late-landing write stole frontmost — take it back
		case .Ignore, .Arm:
		}
	}
	update_focus_ring()
}

@(private = "file")
tap_cb :: proc "c" (proxy: mac.CGEventTapProxy, type: u32, event: mac.CGEvent, userInfo: rawptr) -> mac.CGEvent {
	context = runtime.default_context()
	if type == mac.kCGEventTapDisabledByTimeout || type == mac.kCGEventTapDisabledByUserInput {
		why := type == mac.kCGEventTapDisabledByTimeout ? "timeout (callback overran)" : "user input"
		fmt.printfln("tap DISABLED: %s — re-enabling", why)
		if g_tap != nil do mac.CGEventTapEnable(g_tap, true)
		return event
	}
	if type == mac.kCGEventKeyDown {
		// We only inspect Alt-chords (our keymap) and Ctrl+digit (workspaces);
		// other keys — including Cmd+Tab — pass straight through, never recorded.
		flags := mac.CGEventGetFlags(event)
		if (flags & mac.FLAG_ALT) != 0 || (flags & mac.FLAG_CONTROL) != 0 {
			keycode := mac.CGEventGetIntegerValueField(event, mac.kCGKeyboardEventKeycode)
			t0 := mac.CFAbsoluteTimeGetCurrent()
			handled := dispatch_hotkey(keycode, flags)
			ms := f64(mac.CFAbsoluteTimeGetCurrent() - t0) * 1000
			if ms > TAP_SLOW_MS do fmt.printfln("tap dispatch keycode=%d took %.0fms", keycode, ms)
			if handled {
				return mac.CGEvent(nil) // consume the keystroke
			}
		}
	} else if type == mac.kCGEventLeftMouseDown {
		loc := mac.CGEventGetLocation(event)
		if bar_click(f64(loc.x), f64(loc.y)) {
			return mac.CGEvent(nil) // consumed a click on the bar
		}
		// A real click on a window: follow the OS focus to it on the next fast
		// ticks (the click isn't dispatched yet, so frontmost updates shortly).
		g_click_sync = CLICK_SYNC_TICKS
	}
	return event
}

// Handle a left-click that landed on a status bar: focus the window whose segment
// was clicked (on whichever monitor's bar it hit). Returns true if the click was
// inside a bar (consume it).
@(private = "file")
bar_click :: proc(cx, cy: f64) -> bool {
	main := mac.CGMainDisplayID()
	for mon, mi in g.monitors {
		r := mon.bar_rect
		if !(cy >= r.y && cy < r.y + r.h && cx >= r.x && cx < r.x + r.w) do continue

		id := mac.wm_bar_hit(c.int(mi), cx - r.x)

		// Our own controls (gear, mode toggle) stay clickable even within the top
		// menu-bar strip — they're the explicit exceptions to the pass-through.
		switch id {
		case mac.WM_BAR_SETTINGS:
			mac.wm_settings_open()
			refresh_settings()
			return true
		case mac.WM_BAR_MODE:
			cycle_mode() // columns → monocle → grid → columns
			return true
		}

		// On the main display only, let clicks in the native menu-bar strip fall
		// through to the native menu bar (which reveals on hover over our bar).
		if mon.display_id == main && cy < g.menu_h do return false

		if id != mac.WM_BAR_NONE {
			focus_window_id(layout.Window_Id(id))
			run_effector(nil)
			raise_focused()
		}
		return true // inside a bar (nothing tiled behind it) — consume
	}
	return false
}

// --- hotkeys ----------------------------------------------------------------

@(private = "file")
// Point the share stage at the currently focused window (live-mirror it). The
// real window doesn't move; you share the "Niri Stage" window once in Teams and
// swap sources with this. Needs Screen Recording permission (separate grant).
stage_focused :: proc() {
	if mac.wm_screen_capture_authorized() == 0 {
		mac.wm_screen_capture_request()
		fmt.println("grant Screen Recording to your terminal in System Settings > Privacy & Security > Screen Recording, then restart the daemon")
		return
	}
	ax, ok := mac.focused_window()
	if !ok do return
	defer CF.Release(CF.TypeRef(ax))

	wid: u32
	if mac._AXUIElementGetWindow(ax, &wid) != .Success do return
	mac.wm_stage_capture_window(wid)
}

dispatch_hotkey :: proc(keycode: i64, flags: u64) -> bool {
	shift := (flags & mac.FLAG_SHIFT) != 0

	// Alt+Ctrl+J/K: move the focused window to the next/prev monitor (and follow
	// it). Checked before the Ctrl-digit block below, since this chord carries
	// both Alt and Ctrl. J = next, K = prev.
	if (flags & mac.FLAG_ALT) != 0 && (flags & mac.FLAG_CONTROL) != 0 {
		if keycode == KEY_J || keycode == KEY_K {
			move_focused_to_monitor(keycode == KEY_J ? 1 : -1)
			run_effector(nil)
			raise_focused()
			return true
		}
		return false // other Alt+Ctrl chords pass through
	}

	// Workspaces: Ctrl+1..9 switch, Ctrl+Shift+1..9 move the focused window there.
	// (Native Cmd+Tab is intentionally NOT intercepted — we follow it in focus_cb.)
	if (flags & mac.FLAG_CONTROL) != 0 {
		if n, is_digit := digit_for_keycode(keycode); is_digit {
			if shift do ws_move_focused(n - 1) // 0-indexed workspaces
			else do ws_switch(n - 1)
			run_effector(nil)
			raise_focused()
			return true
		}
		return false // pass other Ctrl chords through to the OS
	}

	if (flags & mac.FLAG_ALT) == 0 do return false // our modifier is Alt

	// Alt+S opens the settings window — handle it before the generic
	// run_effector/raise_focused tail, which would steal focus back from it.
	if keycode == KEY_S {
		mac.wm_settings_open()
		refresh_settings()
		return true
	}

	// Alt+F floats/unfloats — self-contained (it raises the floated window itself,
	// which the generic raise_focused tail would otherwise cover with a tile).
	if keycode == KEY_F {
		toggle_float_focused()
		return true
	}

	// Alt+P mirrors the focused window onto the share stage — self-contained
	// (no tile move/raise; the source window stays exactly where it is).
	if keycode == KEY_P {
		stage_focused()
		return true
	}

	handled := true
	switch keycode {
	case KEY_H:
		if shift do layout.move_column_left(cur_strip())
		else do layout.focus_left(cur_strip())
	case KEY_L:
		if shift do layout.move_column_right(cur_strip())
		else do layout.focus_right(cur_strip())
	case KEY_J:
		if shift do focus_monitor(1) // Alt+Shift+J: focus next monitor
		else do layout.focus_down(cur_strip())
	case KEY_K:
		if shift do focus_monitor(-1) // Alt+Shift+K: focus prev monitor
		else do layout.focus_up(cur_strip())
	case KEY_R:
		layout.cycle_width(cur_strip())
	case KEY_M:
		maximize_focused()
	case KEY_Z:
		toggle_monocle()
	case KEY_G:
		toggle_mode()
	case KEY_COMMA:
		if shift do group_with_app_mates() // Alt+Shift+, : dock with same-app windows
		else do layout.consume_into_column(cur_strip())
	case KEY_PERIOD:
		layout.expel_from_column(cur_strip())
	case KEY_T:
		// Alt+T toggles tiling for the FOCUSED monitor only (per-monitor);
		// the global master stays on `wm live` / the settings toggle.
		set_monitor_live(g.focused_monitor, !g.monitors[g.focused_monitor].live)
	case:
		if n, is_digit := digit_for_keycode(keycode); is_digit {
			if shift do move_focused_to_slot(n)
			else do focus_column(n)
		} else {
			handled = false
		}
	}

	if handled {
		run_effector(nil) // apply layout first (move the focused window into view)
		raise_focused() // then give it real keyboard focus
		fmt.printfln("hotkey keycode=%d shift=%v -> applied (live=%v)", keycode, shift, g.live)
	}
	return handled
}

@(private = "file")
digit_for_keycode :: proc(kc: i64) -> (int, bool) {
	switch kc {
	case 18: return 1, true
	case 19: return 2, true
	case 20: return 3, true
	case 21: return 4, true
	case 23: return 5, true
	case 22: return 6, true
	case 26: return 7, true
	case 28: return 8, true
	case 25: return 9, true
	}
	return 0, false
}

// --- IPC handler ------------------------------------------------------------

daemon_handle :: proc(cmd: string) -> (string, bool) {
	b := strings.builder_make()
	parts := strings.fields(cmd)
	defer delete(parts)
	op := len(parts) > 0 ? parts[0] : ""
	stop := false

	if op != "ping" && op != "quit" && op != "stop" && op != "sync" {
		reconcile()
	}

	switch op {
	case "ping":
		fmt.sbprintln(&b, "pong")
	case "quit", "stop":
		fmt.sbprintln(&b, "stopping daemon")
		stop = true
	case "sync":
		full_resync()
		fmt.sbprintfln(&b, "resynced: %d window(s)", len(g.reg))
		render_state(&b)
	case "state":
		render_state(&b)
	case "focus-left":
		layout.focus_left(cur_strip());render_state(&b);raise_focused()
	case "focus-right":
		layout.focus_right(cur_strip());render_state(&b);raise_focused()
	case "focus-up":
		layout.focus_up(cur_strip());render_state(&b);raise_focused()
	case "focus-down":
		layout.focus_down(cur_strip());render_state(&b);raise_focused()
	case "move-left":
		layout.move_column_left(cur_strip());render_state(&b)
	case "move-right":
		layout.move_column_right(cur_strip());render_state(&b)
	case "width":
		layout.cycle_width(cur_strip());render_state(&b)
	case "width-max":
		maximize_focused();render_state(&b)
	case "consume":
		layout.consume_into_column(cur_strip());render_state(&b)
	case "expel":
		layout.expel_from_column(cur_strip());render_state(&b)
	case "focus-monitor":
		dir := len(parts) > 1 && parts[1] == "prev" ? -1 : 1
		focus_monitor(dir);render_state(&b);raise_focused()
	case "move-to-monitor":
		dir := len(parts) > 1 && parts[1] == "prev" ? -1 : 1
		move_focused_to_monitor(dir);render_state(&b);raise_focused()
	case "windows":
		// Machine-readable list of tiled windows: id <TAB> mon <TAB> ws <TAB> app <TAB> title.
		// Feed a fuzzy picker (Raycast) and jump with `focus-window <id>`.
		for mon, mi in g.monitors {
			for wi in 0 ..< len(mon.workspaces) {
				s := &mon.workspaces[wi].strip
				for ci in 0 ..< len(s.columns) {
					for tile in s.columns[ci].tiles {
						if m, ok := g.reg[tile.id]; ok {
							fmt.sbprintfln(&b, "%d\t%d\t%d\t%s\t%s", u64(tile.id), mi + 1, wi + 1, m.app, m.title)
						}
					}
				}
			}
		}
	case "focus-window":
		if len(parts) > 1 {
			if v, ok := strconv.parse_u64(parts[1]); ok {
				focus_window_id(layout.Window_Id(v))
				run_effector(nil)
				raise_focused()
				render_state(&b)
			} else {
				fmt.sbprintln(&b, "usage: focus-window <id>")
			}
		} else {
			fmt.sbprintln(&b, "usage: focus-window <id>")
		}
	case "workspace":
		if n, ok := parse_ws(parts); ok {
			ws_switch(n)
			fmt.sbprintfln(&b, "switched to workspace %d", n)
			render_state(&b)
		} else {
			fmt.sbprintln(&b, "usage: workspace <n>")
		}
	case "move-to-workspace":
		if n, ok := parse_ws(parts); ok {
			ws_move_focused(n)
			fmt.sbprintfln(&b, "moved focused window to workspace %d", n)
			render_state(&b)
		} else {
			fmt.sbprintln(&b, "usage: move-to-workspace <n>")
		}
	case "live":
		if len(parts) > 1 && parts[1] == "on" {
			set_live(true)
		} else if len(parts) > 1 && parts[1] == "off" {
			set_live(false)
		}
		fmt.sbprintfln(&b, "effector: %s", g.live ? "LIVE" : "dry-run")
		render_state(&b)
	case "monitor-tiling":
		// Per-monitor tiling for the focused monitor (same as Alt+T).
		// `monitor-tiling on|off|toggle` (default toggle).
		mi := g.focused_monitor
		cur := g.monitors[mi].live
		on := !cur
		if len(parts) > 1 && parts[1] == "on" do on = true
		else if len(parts) > 1 && parts[1] == "off" do on = false
		set_monitor_live(mi, on)
		if g.live do run_effector(nil)
		fmt.sbprintfln(&b, "monitor %d tiling: %s", mi + 1, g.monitors[mi].live ? "on" : "manual")
		render_state(&b)
	case "mode":
		if len(parts) > 1 && parts[1] == "columns" {
			g.mode = .Columns
		} else if len(parts) > 1 && parts[1] == "grid" {
			g.mode = .Grid
		} else if len(parts) > 1 && (parts[1] == "monocle" || parts[1] == "fullscreen") {
			g.mode = .Monocle
		} else {
			cycle_mode()
		}
		fmt.sbprintfln(&b, "layout: %s", mode_name(g.mode))
		render_state(&b)
	case "hide-mode":
		if len(parts) > 1 && (parts[1] == "offscreen" || parts[1] == "minimize") {
			restore_all() // clear windows out of the old mode first
			g.hide_offscreen = parts[1] == "offscreen"
		}
		fmt.sbprintfln(&b, "hide mode: %s", g.hide_offscreen ? "offscreen (no animation)" : "minimize")
		render_state(&b)
	case "settings":
		mac.wm_settings_open()
		refresh_settings()
		fmt.sbprintln(&b, "opened settings window")
	case "stage":
		stage_focused()
		fmt.sbprintln(&b, "mirroring focused window to the share stage")
	case "stage-hide":
		mac.wm_stage_hide()
		fmt.sbprintln(&b, "hid the share stage")
	case "float":
		toggle_float_focused()
		render_state(&b)
	case "ignore":
		if len(parts) > 1 {
			app := strings.join(parts[1:], " ")
			defer delete(app)
			ignore_app(app)
			fmt.sbprintfln(&b, "ignoring %q — its windows now float", app)
		} else {
			fmt.sbprintln(&b, "usage: ignore <App name>")
		}
		render_state(&b)
	case "unignore":
		if len(parts) > 1 {
			app := strings.join(parts[1:], " ")
			defer delete(app)
			unignore_app(app)
			fmt.sbprintfln(&b, "no longer ignoring %q", app)
		} else {
			fmt.sbprintln(&b, "usage: unignore <App name>")
		}
		render_state(&b)
	case:
		fmt.sbprintfln(&b, "unknown command: %q", cmd)
	}

	return strings.to_string(b), stop
}

@(private = "file")
parse_ws :: proc(parts: []string) -> (int, bool) {
	if len(parts) < 2 do return 0, false
	n, ok := strconv.parse_int(parts[1])
	if !ok || n < 1 do return 0, false
	return n - 1, true // user-facing 1-indexed -> internal 0-indexed
}

// --- workspaces -------------------------------------------------------------

@(private = "file")
cur_mon :: proc() -> ^Monitor {
	return &g.monitors[g.focused_monitor]
}

@(private = "file")
cur_strip :: proc() -> ^layout.Strip {
	m := cur_mon()
	return &m.workspaces[m.focused_ws].strip
}

// The strip a managed window lives on (its monitor's workspace), if both indices
// are still in range (a removed monitor can leave a window's mon dangling).
@(private = "file")
strip_of :: proc(m: Managed) -> (^layout.Strip, bool) {
	if m.mon < 0 || m.mon >= len(g.monitors) do return nil, false
	mon := &g.monitors[m.mon]
	if m.ws < 0 || m.ws >= len(mon.workspaces) do return nil, false
	return &mon.workspaces[m.ws].strip, true
}

@(private = "file")
ensure_ws :: proc(n: int) {
	m := cur_mon()
	for len(m.workspaces) <= n {
		append(&m.workspaces, Workspace{strip = layout.make_strip(GAP)})
	}
}

// Focus the next (+1) / previous (-1) monitor, wrapping. Its own focused window
// becomes the focus; the caller re-tiles + raises.
@(private = "file")
focus_monitor :: proc(dir: int) {
	if len(g.monitors) < 2 do return
	g.focused_monitor = (g.focused_monitor + dir + len(g.monitors)) % len(g.monitors)
}

// Move the focused window to the next (+1) / previous (-1) monitor's focused
// workspace and follow it there. The effector re-tiles it into that monitor's
// viewport (no manual remap needed for a tiled window).
@(private = "file")
move_focused_to_monitor :: proc(dir: int) {
	if len(g.monitors) < 2 do return
	s := cur_strip()
	id, has := layout.focused_window(s)
	if !has do return
	m, ok := g.reg[id]
	if !ok do return

	target := (g.focused_monitor + dir + len(g.monitors)) % len(g.monitors)
	layout.remove_window(s, id)

	tmon := &g.monitors[target]
	layout.add_window(&tmon.workspaces[tmon.focused_ws].strip, id)
	m.mon = target
	m.ws = tmon.focused_ws
	g.reg[id] = m
	g.focused_monitor = target // focus follows the window
}

// Focus the n-th window/column (1-based) in the current workspace.
@(private = "file")
focus_column :: proc(n: int) {
	s := cur_strip()
	idx := n - 1
	if idx >= 0 && idx < len(s.columns) do s.focused_col = idx
}

// Give the daemon's focused window real keyboard focus (raise + activate app).
@(private = "file")
raise_focused :: proc() {
	id, ok := layout.focused_window(cur_strip())
	if !ok do return
	m, found := g.reg[id]
	if found {
		g_focus_hold = FOCUS_HOLD_TICKS // hold off OS-focus polling while this settles
		g_last_synced_id = id // our own focus, not an external change to follow
		if m.loose {
			// Don't raise a slow window just because focus swept over it — that
			// activation is expensive and, if the user is passing through, wrong.
			// Defer it: the fast tick raises it only once focus has dwelt here.
			g_pending_raise_id = id
			g_pending_raise_at = mac.CFAbsoluteTimeGetCurrent() + LOOSE_RAISE_DWELL
		} else {
			// Snappy app: raise now (off the main thread) and guard against the
			// follow tick bouncing focus away before it comes frontmost.
			g_pending_raise_id = 0
			note_raise_issued(id)
			enqueue_focus(m.ax, m.pid, false)
			arm_activation_guard(m.pid)
		}
		// Mouse follows focus: warp to the window's center. Use the rect the
		// effector just placed it at (m.placed) — no AX read, and it's exactly
		// where the window is headed even if the async move hasn't landed yet.
		r := m.placed
		if r.w > 0 && r.h > 0 {
			mac.warp_mouse(r.x + r.w / 2, r.y + r.h / 2)
		}
	}
}

// Suppress the OS-focus-follow tick until `pid` is actually the frontmost app
// (or we time out). Stops the follow logic from snapping focus back off a
// window whose activation is still in flight.
@(private = "file")
arm_activation_guard :: proc(pid: i32) {
	g_activating_pid = pid
	g_activating_until = mac.CFAbsoluteTimeGetCurrent() + ACTIVATE_TIMEOUT
}

// Bookkeeping around every focus write we enqueue: if it supersedes a slow
// raise still in flight, remember that window as stale so the follow tick can
// recognize its late arrival as ours (and re-assert) instead of following it.
@(private = "file")
note_raise_issued :: proc(id: layout.Window_Id) {
	if pm, ok := g.reg[g_issued_raise_id]; ok && raise_superseded_late(g_issued_raise_id, id, pm.loose, pm.pid == mac.wm_frontmost_pid()) {
		g_stale_raise_id = g_issued_raise_id
		g_stale_raise_until = mac.CFAbsoluteTimeGetCurrent() + ACTIVATE_TIMEOUT
	}
	if g_stale_raise_id == id do g_stale_raise_id = 0 // deliberately raising it again
	g_issued_raise_id = id
}

// Point the daemon's focus at the window the user actually has focused in the OS
// (e.g. after a mouse click). Returns false while still waiting: the clicked
// window's app may not be frontmost yet (a match on the window we already
// focus is just the pre-click frontmost), and a new frontmost must hold for
// two consecutive ticks — a click on the focused window leaves this armed for
// CLICK_SYNC_TICKS, and an Outlook reminder blip landing in that window used
// to be adopted as the click's target instantly.
@(private = "file")
sync_focus_from_os :: proc() -> bool {
	id, _ := frontmost_managed()
	cur, has := layout.focused_window(cur_strip())
	act := click_sync_action(id, cur, has, g_follow_candidate)
	g_follow_candidate = act == .Arm ? id : 0
	if act != .Sync do return false
	focus_window_id(id)
	return true
}

@(private = "file")
focus_window_id :: proc(id: layout.Window_Id) {
	for mi in 0 ..< len(g.monitors) {
		mon := &g.monitors[mi]
		for wi in 0 ..< len(mon.workspaces) {
			s := &mon.workspaces[wi].strip
			for ci in 0 ..< len(s.columns) {
				for ti in 0 ..< len(s.columns[ci].tiles) {
					if s.columns[ci].tiles[ti].id == id {
						g.focused_monitor = mi
						mon.focused_ws = wi
						s.focused_col = ci
						s.columns[ci].focused_tile = ti
						return
					}
				}
			}
		}
	}
}

// Dock the focused window into the nearest column (searching outward from the
// focused column) that already holds another window of the same app — e.g. a
// torn-off browser window rejoining its siblings. No-op if there's no such column.
// Mutates only; the caller applies the layout (run_effector/raise).
@(private = "file")
group_with_app_mates :: proc() {
	s := cur_strip()
	id, ok := layout.focused_window(s)
	if !ok do return
	me, found := g.reg[id]
	if !found do return

	best, bestd := -1, max(int)
	for ci in 0 ..< len(s.columns) {
		if ci == s.focused_col do continue
		for tile in s.columns[ci].tiles {
			m, ok2 := g.reg[tile.id]
			if !ok2 || m.app != me.app do continue
			if d := abs(ci - s.focused_col); d < bestd {
				bestd, best = d, ci
			}
			break // this column qualifies; move on to the next
		}
	}
	if best >= 0 do layout.regroup_into(s, id, best)
}

// Move the focused column to slot n (1-based), reordering the strip.
@(private = "file")
move_focused_to_slot :: proc(n: int) {
	s := cur_strip()
	if len(s.columns) == 0 do return
	target := clamp(n - 1, 0, len(s.columns) - 1)
	for s.focused_col > target do layout.move_column_left(s)
	for s.focused_col < target do layout.move_column_right(s)
}

// Switch the layout between the scrollable column strip and a grid.
@(private = "file")
toggle_mode :: proc() {
	g.mode = g.mode == .Grid ? .Columns : .Grid
	run_effector(nil)
}

// Toggle fullscreen/monocle (one window per screen) on and off; "off" is the
// normal scrollable columns. Non-destructive — column widths are preserved.
@(private = "file")
toggle_monocle :: proc() {
	g.mode = g.mode == .Monocle ? .Columns : .Monocle
	run_effector(nil)
}

// Advance the layout mode columns → monocle → grid → columns. Driven by the
// single bar mode control so one click can reach every mode.
@(private = "file")
cycle_mode :: proc() {
	switch g.mode {
	case .Columns: g.mode = .Monocle
	case .Monocle: g.mode = .Grid
	case .Grid:    g.mode = .Columns
	}
	run_effector(nil)
}

@(private = "file")
mode_name :: proc(m: Layout_Mode) -> string {
	switch m {
	case .Grid:    return "grid"
	case .Monocle: return "monocle"
	case .Columns: return "columns"
	}
	return "columns"
}

// The managed window the user currently sees as frontmost (so a floated window,
// which isn't in the strip, can still be the Alt+F target to un-float it).
@(private = "file")
frontmost_managed :: proc() -> (layout.Window_Id, bool) {
	w, ok := mac.focused_window()
	if !ok {
		// An AX-slow frontmost app (Godot) can't be asked for its focused
		// window without blocking; if we manage exactly one of its windows,
		// that must be it — enough for click-focus to keep following.
		pid := mac.wm_frontmost_pid()
		if pid > 0 && mac.ax_pid_slow(pid) {
			found: layout.Window_Id
			count := 0
			for id, m in g.reg do if m.pid == pid {
				found = id
				count += 1
			}
			if count == 1 do return found, true
		}
		return 0, false
	}
	defer CF.Release(CF.TypeRef(w))
	for id, m in g.reg {
		if bool(mac.CFEqual(CF.TypeRef(m.ax), CF.TypeRef(w))) do return id, true
	}
	return 0, false
}

// Toggle a window between tiled and floating. Floating pops it out of the strip,
// centres it, and raises it so it's a free, draggable window the daemon no longer
// touches; un-floating re-tiles it. The target is the OS-frontmost managed window
// (falling back to the strip focus), so a floated window can be un-floated by
// clicking/raising it and pressing Alt+F again.
@(private = "file")
toggle_float_focused :: proc() {
	id, ok := frontmost_managed()
	if !ok {
		id, ok = layout.focused_window(cur_strip())
	}
	if !ok do return
	m, in_reg := g.reg[id]
	if !in_reg do return

	if m.floated {
		// Un-float: back into the strip and re-tiled.
		m.floated = false
		g.reg[id] = m
		layout.append_window(cur_strip(), id)
		run_effector(nil)
		raise_focused()
	} else {
		// Float: pop out, re-tile the rest, then centre + raise this one.
		m.floated = true
		g.reg[id] = m
		layout.remove_window(cur_strip(), id)
		run_effector(nil)
		if m.hidden == .Minimized {
			mac.ax_set_minimized(m.ax, false)
		}
		set_hidden(id, .None)
		// Centre + raise so it's draggable immediately — via the writer thread
		// (loose apps must never take a synchronous AX call on the tap thread).
		centre := layout.apply_preset(cur_mon().viewport, .Center)
		set_placed(id, centre)
		enqueue_frame(m.ax, centre, false, m.loose)
		note_raise_issued(id)
		enqueue_focus(m.ax, m.pid, m.loose)
		arm_activation_guard(m.pid)
	}
}

// Add an app (by CGWindow owner name) to the never-tile set and evict any of its
// windows currently in the strip (they stay where they are, now floating).
@(private = "file")
ignore_app :: proc(app: string) {
	if app == "" || app in g.ignore_apps do return
	g.ignore_apps[strings.clone(app)] = true

	evict: [dynamic]layout.Window_Id
	defer delete(evict)
	for id, m in g.reg do if m.app == app do append(&evict, id)
	for id in evict {
		m := g.reg[id]
		if s, ok := strip_of(m); ok do layout.remove_window(s, id)
		CF.Release(CF.TypeRef(m.ax))
		delete(m.title)
		delete(m.app)
		delete_key(&g.reg, id)
	}
	run_effector(nil)
}

// Remove an app from the never-tile set; reconcile re-adopts its windows.
@(private = "file")
unignore_app :: proc(app: string) {
	key: string
	found := false
	for k in g.ignore_apps {
		if k == app {
			key = k
			found = true
			break
		}
	}
	if !found do return
	delete_key(&g.ignore_apps, key)
	delete(key)
	reconcile()
	run_effector(nil)
}

// Toggle the focused column between full width and the default width.
@(private = "file")
maximize_focused :: proc() {
	s := cur_strip()
	if len(s.columns) == 0 do return
	col := &s.columns[s.focused_col]
	col.width_frac = col.width_frac >= 0.99 ? layout.DEFAULT_WIDTH : 1.0
	col.eff_w = 0 // re-probe at the new width
}

@(private = "file")
ws_switch :: proc(n: int) {
	ensure_ws(n)
	cur_mon().focused_ws = n
}

@(private = "file")
ws_move_focused :: proc(n: int) {
	id, has := layout.focused_window(cur_strip())
	if !has do return
	ensure_ws(n)
	layout.remove_window(cur_strip(), id)
	mon := cur_mon()
	layout.add_window(&mon.workspaces[n].strip, id)
	m := g.reg[id]
	m.ws = n
	g.reg[id] = m
}

// --- window tracking --------------------------------------------------------

@(private = "file")
clear_registry :: proc() {
	for _, m in g.reg {
		CF.Release(CF.TypeRef(m.ax))
		delete(m.title)
		delete(m.app)
	}
	clear(&g.reg)
}

@(private = "file")
full_resync :: proc() {
	// Keep each display's Alt+T state: a sleep/wake or resolution change must
	// not silently switch tiling back on for a monitor the user turned off.
	manual := make(map[u32]bool)
	defer delete(manual)
	for mon in g.monitors do if !mon.live do manual[mon.display_id] = true
	clear_registry()
	destroy_monitors()
	build_monitors() // re-read displays too, so this doubles as hotplug handling
	for &mon in g.monitors do if mon.display_id in manual do mon.live = false
	reconcile(home_new_at_frame = true)
}

// The frame to restore an adopted window to when tiling is turned off. A window
// whose centre is on no display was parked off-screen by a previous daemon run;
// "restoring" it there would leave it invisible, so centre it in the viewport.
orig_for_adopted :: proc(frame: layout.Rect, on_display: bool, viewport: layout.Rect) -> layout.Rect {
	if on_display do return frame
	w := min(frame.w, viewport.w)
	h := min(frame.h, viewport.h)
	return {viewport.x + (viewport.w - w) / 2, viewport.y + (viewport.h - h) / 2, w, h}
}

// Whether a freshly-seen window should be adopted into the tiling strip. Skips
// user-ignored apps, windows too small to be anything but a popup, and
// fixed-size windows (alerts/notifications can't be resized to fit a column).
@(private = "file")
should_tile :: proc(w: mac.Std_Window) -> bool {
	if w.app in g.ignore_apps do return false
	if f64(w.frame.size.width) < MIN_TILE_W || f64(w.frame.size.height) < MIN_TILE_H do return false
	if !mac.ax_settable(w.ax, "AXSize") do return false
	return true
}

// home_new_at_frame: initial adoption / full resync homes each window on the
// monitor its frame sits on (they have legitimate positions). Steady-state
// ticks home new windows on the FOCUSED monitor instead — macOS opens a
// window on whichever display the app last used, which is not where the user
// is looking.
@(private = "file")
reconcile :: proc(home_new_at_frame := false) -> (added: int, removed: int, retagged: int) {
	if len(g.monitors) == 0 do return // no displays to home windows on; timer_cb rebuilds on wake
	wins := mac.standard_windows(g.manage_app)
	defer delete(wins)

	// Merge the slow lane's latest batch: windows of AX-backed-off apps,
	// enumerated off-thread so this tick never blocked for them. Remember
	// which pids the batch covered — only those ticks carry enough truth to
	// declare one of that app's windows closed.
	slow_batch_pids := make(map[i32]bool)
	defer delete(slow_batch_pids)
	sync.mutex_lock(&g_slow_mu)
	for w in g_slow_wins {
		slow_batch_pids[w.pid] = true
		append(&wins, w)
	}
	clear(&g_slow_wins)
	sync.mutex_unlock(&g_slow_mu)

	// Dedup: a pid can leave backoff between a slow-lane batch and this tick,
	// getting enumerated by both lanes; adopting twice would double-register.
	for i := 0; i < len(wins); i += 1 {
		for j := i + 1; j < len(wins); {
			if bool(mac.CFEqual(CF.TypeRef(wins[i].ax), CF.TypeRef(wins[j].ax))) {
				mac.std_window_destroy(wins[j])
				ordered_remove(&wins, j)
			} else {
				j += 1
			}
		}
	}

	matched := make([]bool, len(wins))
	defer delete(matched)

	// The window server's full list (all Spaces, minimized, hidden apps) —
	// fetched lazily, only on ticks where some managed window went missing.
	all_cg: map[u32]bool
	all_cg_fetched := false
	defer delete(all_cg)

	to_remove: [dynamic]layout.Window_Id
	defer delete(to_remove)
	for id, m in g.reg {
		found := false
		for w, i in wins {
			if matched[i] do continue
			if bool(mac.CFEqual(CF.TypeRef(m.ax), CF.TypeRef(w.ax))) {
				matched[i] = true
				found = true
				break
			}
		}
		// Keep the loose tag in sync with the app's AX health, so a recovered
		// app rejoins real tiling and a newly-slow one stops being polled.
		if found && m.loose != mac.ax_pid_slow(m.pid) {
			mm := m
			mm.loose = !m.loose
			g.reg[id] = mm
			retagged += 1
			// A recovered app joins real tiling at the default width — without
			// this it keeps the full-viewport column from its loose adoption.
			if !mm.loose {
				if s, ok := strip_of(mm); ok do layout.set_window_width(s, id, layout.DEFAULT_WIDTH)
			}
		}
		// Absent from this tick's scan: closed, or just invisible to it?
		// absent_window_closed has the full rules; the liveness probe is a
		// free syscall (signal 0), no AX.
		if !found {
			alive := posix.kill(posix.pid_t(m.pid), .NONE) == .OK
			slow := mac.ax_pid_slow(m.pid)
			// Ask the window's own AX element whether it still exists — the
			// reliable per-window check. Skip a slow app (we won't block on it)
			// and fall back to the server list below.
			ax_alive, ax_decided := false, false
			if alive && !slow {
				ax_alive, ax_decided = mac.ax_window_alive(m.ax)
			}
			cg_listed := false
			if alive && !ax_decided && m.cgwin != 0 {
				if !all_cg_fetched {
					all_cg = mac.all_window_ids()
					all_cg_fetched = true
				}
				cg_listed = m.cgwin in all_cg
			}
			if absent_window_closed(m.hidden, alive, slow, m.pid in slow_batch_pids, m.cgwin != 0, cg_listed, ax_alive, ax_decided) {
				append(&to_remove, id)
			}
		}
	}
	for id in to_remove {
		m := g.reg[id]
		if s, ok := strip_of(m); ok do layout.remove_window(s, id)
		CF.Release(CF.TypeRef(m.ax))
		delete(m.title)
		delete(m.app)
		delete_key(&g.reg, id)
		removed += 1
	}

	// Append new windows in reverse z-order so the strip reads oldest->newest
	// (left->right) instead of frontmost-first; the newest ends up focused.
	#reverse for w, i in wins {
		if matched[i] {
			mac.std_window_destroy(w)
			continue
		}
		// Leave alerts, notification popups, and user-ignored apps floating.
		if !should_tile(w) {
			mac.std_window_destroy(w)
			continue
		}
		cx, cy := layout.center_of(to_rect(w.frame))
		mi := home_new_at_frame ? monitor_for_point(cx, cy) : g.focused_monitor
		mon := &g.monitors[mi]
		_, on_display := mac.display_for_point(cx, cy)

		id := layout.Window_Id(g.next_id)
		g.next_id += 1
		// An AX-slow app's window is adopted "loose": it rides the strip as a
		// full-viewport column (navigable, in the bar — in the ecosystem) but
		// we stop polling it and only write to it on placement changes — also
		// not. Games and Godot land here.
		loose := mac.ax_pid_slow(w.pid)
		g.reg[id] = Managed {
			pid   = w.pid,
			ax    = w.ax,
			cgwin = w.cgwin,
			title = w.title,
			app   = w.app,
			mon   = mi,
			ws    = mon.focused_ws,
			loose = loose,
			orig  = orig_for_adopted(to_rect(w.frame), on_display, mon.viewport),
		}
		strip := &mon.workspaces[mon.focused_ws].strip
		if loose {
			layout.append_window(strip, id, width_frac = 1.0) // whole screen
		} else {
			layout.append_window(strip, id) // new windows land on the right
		}
		added += 1
	}
	return
}

// --- rendering / effector ---------------------------------------------------

@(private = "file")
render_state :: proc(b: ^strings.Builder) {
	fmt.sbprintfln(b, "monitor %d/%d  (effector=%s)", g.focused_monitor + 1, len(g.monitors), g.live ? "LIVE" : "dry-run")

	for mon, mi in g.monitors {
		s := &mon.workspaces[mon.focused_ws].strip
		marker := mi == g.focused_monitor ? "*" : " "
		tiling := mon.live ? "tiling" : "manual"
		fmt.sbprintfln(b, "%smonitor %d (display %d, ws %d/%d, %s):", marker, mi + 1, mon.display_id, mon.focused_ws, len(mon.workspaces) - 1, tiling)
		if len(s.columns) == 0 do fmt.sbprintln(b, "  (focused workspace empty)")
		for col, ci in s.columns {
			fmt.sbprintf(b, ci == s.focused_col ? "  > col%d w=%.2f:" : "    col%d w=%.2f:", ci, col.width_frac)
			for tile, ti in col.tiles {
				star := ci == s.focused_col && ti == col.focused_tile ? "*" : ""
				fmt.sbprintf(b, " [%d %s%s]", u64(tile.id), clip(g.reg[tile.id].title, 18), star)
			}
			fmt.sbprintln(b)
		}
	}

	run_effector(b)

	for mon, mi in g.monitors {
		for ws, wi in mon.workspaces {
			if wi == mon.focused_ws do continue
			n := 0
			for col in ws.strip.columns do n += len(col.tiles)
			if n > 0 do fmt.sbprintfln(b, "  monitor %d workspace %d: %d window(s) hidden", mi + 1, wi, n)
		}
	}

	nfloat := 0
	for _, m in g.reg do if m.floated do nfloat += 1
	if nfloat > 0 do fmt.sbprintfln(b, "  floating (Alt+F, not tiled): %d window(s)", nfloat)
	if len(g.ignore_apps) > 0 {
		fmt.sbprint(b, "  ignored apps:")
		for k in g.ignore_apps do fmt.sbprintf(b, " %q", k)
		fmt.sbprintln(b)
	}
}

// Tile every monitor (each into its own viewport), then refresh the ring + bar.
// All monitors are always laid out; only the focused workspace of each shows.
@(private = "file")
run_effector :: proc(b: ^strings.Builder) {
	for mi in 0 ..< len(g.monitors) do apply_monitor(b, mi)
	update_focus_ring()
	update_bar()
}

// Apply the focused workspace of monitor `mi` into that monitor's viewport, and
// hide its other workspaces.
@(private = "file")
apply_monitor :: proc(b: ^strings.Builder, mi: int) {
	mon := &g.monitors[mi]
	// Effective tiling for this monitor: the global master AND this monitor's own
	// switch. A monitor with live=false is freeform — its windows are left where
	// they are, so one screen can tile while another stays manual.
	live := g.live && mon.live
	s := &mon.workspaces[mon.focused_ws].strip
	if live && g.mode == .Columns do learn_widths(s)
	ps: []layout.Placement
	switch g.mode {
	case .Grid:    ps = layout.compute_grid(s, mon.viewport)
	case .Monocle: ps = layout.compute_monocle(s, mon.viewport)
	case .Columns: ps = layout.compute_layout(s, mon.viewport)
	}
	defer delete(ps)

	// Which edges of this monitor face empty space (for parking off-view windows).
	other_bounds := make([dynamic]layout.Rect, 0, len(g.monitors))
	defer delete(other_bounds)
	for m2, j in g.monitors do if j != mi do append(&other_bounds, m2.bounds)
	open_left, open_right := open_park_sides(mon.bounds, other_bounds[:])

	if b != nil do fmt.sbprintfln(b, "monitor %d (display %d) view_x=%.0f", mi + 1, mon.display_id, s.view_x)
	for p in ps {
		m := g.reg[p.id]
		applied := ""
		if live {
			if p.visible {
				// Only a real minimize needs the synchronous AX undo; a parked
				// window just gets its on-view frame back below.
				if m.hidden == .Minimized {
					mac.ax_set_minimized(m.ax, false)
				}
				set_hidden(p.id, .None)
				// All frame writes go to a writer thread (never block the tap),
				// and only when the placement actually changed since our last one.
				if m.placed != p.rect {
					enqueue_frame(m.ax, p.rect, false, m.loose)
					set_placed(p.id, p.rect)
				}
				if !m.loose do set_req_w(p.id, p.rect.w) // asked-for width, to detect clamping
				applied = " -> on-screen"
			} else {
				// Hide off-view columns. Either park off-screen (instant, no genie
				// animation) or minimize. Mark hidden so reconcile doesn't mistake
				// the vanished-from-enumeration window for a closed one.
				if g.hide_offscreen {
					hr := park_rect(p.rect, mon.viewport, mon.bounds, open_left, open_right)
					if m.placed != hr {
						enqueue_frame(m.ax, hr, true, m.loose)
						set_placed(p.id, hr)
					}
					set_hidden(p.id, .Parked)
				} else {
					mac.ax_set_minimized(m.ax, true)
					set_hidden(p.id, .Minimized)
				}
				applied = g.hide_offscreen ? " -> off-screen" : " -> minimized"
			}
		}
		if b != nil {
			fmt.sbprintfln(
				b,
				"  win %d %-20s (%.0f,%.0f %.0fx%.0f) %s%s",
				u64(p.id), clip(m.title, 18),
				p.rect.x, p.rect.y, p.rect.w, p.rect.h,
				p.visible ? "visible" : "HIDDEN", applied,
			)
		}
	}

	if live {
		for ws, wi in mon.workspaces {
			if wi == mon.focused_ws do continue
			for col in ws.strip.columns {
				for tile in col.tiles {
					// Already down: skip the synchronous AX re-minimize this
					// loop used to pay per off-workspace window on EVERY
					// effector pass (i.e. every navigation hotkey). If the
					// user summons it externally (Dock), it becomes frontmost
					// and the focus-follow tick switches to its workspace.
					if g.reg[tile.id].hidden == .Minimized do continue
					mac.ax_set_minimized(g.reg[tile.id].ax, true)
					set_hidden(tile.id, .Minimized)
				}
			}
		}
	}
}

// Refresh every monitor's bar (one per display), then hide any bars left over
// from a display that was unplugged, and push the clock/battery/wifi cluster.
@(private = "file")
update_bar :: proc() {
	for mi in 0 ..< len(g.monitors) do set_monitor_bar(mi)
	mac.wm_bar_hide_from(c.int(len(g.monitors))) // drop bars for displays that went away
	mac.wm_bar_status_refresh() // clock/battery/wifi on the right of each bar
}

// Build and push monitor `mi`'s bar: settings gear, this monitor's status (with a
// dot marking the focused monitor), the mode toggle, then one clickable segment
// per window on its focused workspace (the focused one highlighted) — so each
// display's bar shows exactly which windows live on it.
@(private = "file")
set_monitor_bar :: proc(mi: int) {
	mon := &g.monitors[mi]
	s := &mon.workspaces[mon.focused_ws].strip

	segs: [dynamic]mac.WMBarSeg
	defer delete(segs)
	cstrs: [dynamic]cstring
	defer {
		for cs in cstrs do delete(cs)
		delete(cstrs)
	}

	// Settings gear (leftmost, clickable — opens the settings window). Rendered as
	// an SF Symbol by the bar view, so no text is needed here.
	append(&segs, mac.WMBarSeg{app = nil, window_id = mac.WM_BAR_SETTINGS})

	// Status segment (non-clickable): this monitor + its workspace; a leading dot
	// marks the monitor that currently has focus.
	status: string
	if len(g.monitors) > 1 {
		dot := mi == g.focused_monitor ? "● " : ""
		status = fmt.aprintf("%smon %d/%d · ws %d/%d", dot, mi + 1, len(g.monitors), mon.focused_ws + 1, len(mon.workspaces))
	} else {
		status = fmt.aprintf("ws %d/%d", mon.focused_ws + 1, len(mon.workspaces))
	}
	status_c := strings.clone_to_cstring(status)
	delete(status)
	// Per-monitor tiling state: global-off shows dry-run everywhere; otherwise
	// each bar shows whether ITS monitor is tiling or freeform ("manual").
	tiling_label := !g.live ? "dry-run" : (mon.live ? "tiling" : "manual")
	mode_c := strings.clone_to_cstring(tiling_label)
	append(&cstrs, status_c, mode_c)
	append(&segs, mac.WMBarSeg{app = status_c, title = mode_c, window_id = mac.WM_BAR_NONE})

	// Clickable layout-mode toggle. The plain word picks the SF Symbol in the view.
	layout_c := strings.clone_to_cstring(mode_name(g.mode))
	append(&cstrs, layout_c)
	append(&segs, mac.WMBarSeg{app = layout_c, window_id = mac.WM_BAR_MODE})

	// One clickable segment per window on this monitor.
	for col, ci in s.columns {
		for tile, ti in col.tiles {
			m := g.reg[tile.id]
			app_c := strings.clone_to_cstring(clip(m.app, 18))
			title_c := strings.clone_to_cstring(clip(m.title, 26))
			append(&cstrs, app_c, title_c)
			foc: c.int = (ci == s.focused_col && ti == col.focused_tile) ? 1 : 0
			append(&segs, mac.WMBarSeg {
				app       = app_c,
				title     = title_c,
				window_id = u64(tile.id),
				focused   = foc,
				index     = c.int(ci + 1), // column number = Alt+<n>
			})
		}
	}

	mac.wm_bar_set(c.int(mi), raw_data(segs[:]), c.int(len(segs)), mon.bar_rect.x, mon.bar_rect.y, mon.bar_rect.w, mon.bar_rect.h)
}

// --- settings window --------------------------------------------------------

// A button in the settings window was clicked; run it as a daemon command, then
// re-push the window's contents. Runs on the main thread (same as the daemon),
// so touching daemon state directly is safe.
@(private = "file")
settings_cmd_cb :: proc "c" (cmd: cstring) {
	context = runtime.default_context()
	c := string(cmd)
	switch c {
	case "live toggle":
		set_live(!g.live)
	case "mode toggle":
		toggle_mode()
	case "monocle toggle":
		toggle_monocle()
	case "hide-mode toggle":
		restore_all()
		g.hide_offscreen = !g.hide_offscreen
		run_effector(nil)
	case:
		reply, _ := daemon_handle(c) // ignore / unignore <App>
		delete(reply)
	}
	refresh_settings()
}

// Push current config, the hotkey reference, and the full open-window list (with
// per-app ignore state) into the settings window. No-op while it's closed.
@(private = "file")
refresh_settings :: proc() {
	if mac.wm_settings_is_open() == 0 do return

	wins := mac.standard_windows("")
	defer {
		for w in wins do mac.std_window_destroy(w)
		delete(wins)
	}
	rows: [dynamic]mac.WMSettingsRow
	cstrs: [dynamic]cstring
	defer {
		for cs in cstrs do delete(cs)
		delete(cstrs)
		delete(rows)
	}
	for w in wins {
		app_c := strings.clone_to_cstring(w.app)
		title_c := strings.clone_to_cstring(w.title)
		append(&cstrs, app_c, title_c)
		ign: c.int = (w.app in g.ignore_apps) ? 1 : 0
		append(&rows, mac.WMSettingsRow{app = app_c, title = title_c, ignored = ign})
	}
	// The enumeration above skips AX-slow apps (Godot, games), but their
	// windows are still managed via the slow lane — add those rows from the
	// registry so they appear in the list too.
	outer: for _, m in g.reg {
		if !mac.ax_pid_slow(m.pid) do continue
		for w in wins do if w.pid == m.pid do continue outer // both lanes raced; already listed
		app_c := strings.clone_to_cstring(m.app)
		title_c := strings.clone_to_cstring(m.title)
		append(&cstrs, app_c, title_c)
		ign: c.int = (m.app in g.ignore_apps) ? 1 : 0
		append(&rows, mac.WMSettingsRow{app = app_c, title = title_c, ignored = ign})
	}
	mac.wm_settings_set_rows(raw_data(rows[:]), c.int(len(rows)))

	cfg := fmt.aprintf(
		"Tiling: %s      Layout: %s      Hide: %s      Gap: %dpx",
		g.live ? "on" : "paused (dry-run)",
		mode_name(g.mode),
		g.hide_offscreen ? "off-screen" : "minimize",
		int(GAP),
	)
	defer delete(cfg)
	cfg_c := strings.clone_to_cstring(cfg)
	defer delete(cfg_c)
	hk_c := strings.clone_to_cstring(HOTKEYS_TEXT)
	defer delete(hk_c)
	mac.wm_settings_set_info(cfg_c, hk_c)
}

// Truncate to at most n bytes without splitting a UTF-8 sequence (empty stays
// empty so the bar omits a missing title).
@(private = "file")
clip :: proc(s: string, n: int) -> string {
	if len(s) <= n do return s
	i := n
	for i > 0 && (s[i] & 0xC0) == 0x80 do i -= 1
	return s[:i]
}

// Draw the focus ring around the focused window's *actual* current frame, so it
// gives visible feedback even in dry-run (where windows aren't moved).
@(private = "file")
update_focus_ring :: proc() {
	if len(g.monitors) == 0 {
		mac.wm_ring_hide()
		return
	}
	if !g.live || !g.monitors[g.focused_monitor].live {
		mac.wm_ring_hide() // tiling paused: no outlines
		return
	}
	fid, has := layout.focused_window(cur_strip())
	if !has {
		mac.wm_ring_hide()
		return
	}
	m, ok := g.reg[fid]
	if !ok {
		mac.wm_ring_hide()
		return
	}
	// Runs every fast tick (120ms). Draw the ring at the rect the effector last
	// placed this window (m.placed) — a tiling WM owns the geometry, so this is
	// authoritative, and reading it costs no AX. That keeps the tap-hosting main
	// thread off every app's AX server (the polling here is what originally
	// froze all input when a slow app like Godot was focused).
	r := m.placed
	if r.w > 0 && r.h > 0 {
		mac.wm_ring_show(r.x, r.y, r.w, r.h)
	} else {
		mac.wm_ring_hide()
	}
}

EDGE_REVEAL :: 6.0

// Which sides of monitor `mon` face empty space — no other display overlaps
// its vertical band on that side. A side-parked window keeps its own y, so
// only displays sharing this monitor's y-range can see it. Bounds are full
// CGDisplayBounds rects.
open_park_sides :: proc(mon: layout.Rect, others: []layout.Rect) -> (left, right: bool) {
	left, right = true, true
	for b in others {
		if b.y + b.h <= mon.y || b.y >= mon.y + mon.h do continue // no vertical overlap
		if b.x < mon.x do left = false
		if b.x > mon.x do right = false
	}
	return
}

// Where to park an off-view window so it's (nearly) invisible. macOS clamps a
// window parked DOWN so its whole title bar stays on screen — that's a full
// tab-bar strip peeking along the bottom, not the EDGE_REVEAL sliver we asked
// for. Horizontal placement isn't clamped that way, so prefer sliding the
// window off an OPEN side edge (past the display bounds), keeping EDGE_REVEAL
// px on-screen — fully off-screen would drop it from the on-screen window
// list and reconcile would mistake it for closed. A monitor boxed in on both
// sides falls back to bottom parking and accepts the title-bar peek.
park_rect :: proc(r, vp, bounds: layout.Rect, open_left, open_right: bool) -> layout.Rect {
	if open_right do return {bounds.x + bounds.w - EDGE_REVEAL, r.y, r.w, r.h}
	if open_left do return {bounds.x - r.w + EDGE_REVEAL, r.y, r.w, r.h}
	return {r.x, vp.y + vp.h - EDGE_REVEAL, r.w, r.h}
}

// Restore every managed window to the frame it had when first managed, so
// un-tiling (or stopping the daemon) puts windows back where they were.
@(private = "file")
restore_all :: proc() {
	ids: [dynamic]layout.Window_Id
	defer delete(ids)
	for id, m in g.reg {
		mac.ax_set_minimized(m.ax, false)
		mac.set_frame(m.ax, to_cg(m.orig))
		append(&ids, id)
	}
	for id in ids do set_hidden(id, .None)
}

// Toggle the effector. Turning it off restores all managed windows.
@(private = "file")
set_live :: proc(on: bool) {
	if g.live && !on do restore_all()
	g.live = on
}

// Restore just monitor `mi`'s managed windows to where they were before tiling
// (un-hide off-view ones, move each back to its original frame) — via the writer
// thread so a loose app never blocks. Used when a single monitor leaves tiling.
@(private = "file")
restore_monitor :: proc(mi: int) {
	mon := &g.monitors[mi]
	for ws in mon.workspaces {
		for col in ws.strip.columns {
			for tile in col.tiles {
				m, ok := g.reg[tile.id]
				if !ok do continue
				if m.hidden == .Minimized {
					mac.ax_set_minimized(m.ax, false) // undo a real minimize
				}
				enqueue_frame(m.ax, m.orig, false, m.loose)
				set_placed(tile.id, m.orig)
				set_hidden(tile.id, .None)
			}
		}
	}
}

// Per-monitor tiling toggle: lets one screen tile while another stays freeform.
// Turning a monitor off restores its windows; turning it on re-tiles on the next
// run_effector (the hotkey tail runs one).
@(private = "file")
set_monitor_live :: proc(mi: int, on: bool) {
	if mi < 0 || mi >= len(g.monitors) do return
	mon := &g.monitors[mi]
	if mon.live == on do return
	if mon.live && !on do restore_monitor(mi)
	mon.live = on
}

@(private = "file")
set_hidden :: proc(id: layout.Window_Id, hidden: Hidden) {
	m, ok := g.reg[id]
	if ok && m.hidden != hidden {
		m.hidden = hidden
		g.reg[id] = m
	}
}

@(private = "file")
set_req_w :: proc(id: layout.Window_Id, w: f64) {
	m, ok := g.reg[id]
	if ok {
		m.req_w = w
		g.reg[id] = m
	}
}

@(private = "file")
set_placed :: proc(id: layout.Window_Id, r: layout.Rect) {
	m, ok := g.reg[id]
	if ok {
		m.placed = r
		g.reg[id] = m
	}
}

// Detect width-constrained windows (those that won't grow to the width we asked
// for, e.g. System Settings) and record their real width as the column's eff_w,
// so compute_layout packs neighbours against it instead of the nominal slot.
@(private = "file")
learn_widths :: proc(s: ^layout.Strip) {
	for &col in s.columns {
		if len(col.tiles) == 0 do continue
		id := col.tiles[col.focused_tile].id
		m, ok := g.reg[id]
		if !ok || m.hidden != .None || m.req_w <= 0 do continue // only on-screen, already-asked windows
		if m.loose do continue // full-width by design; not worth an AX read to a slow app
		// This runs inside the event-tap callback (every hotkey press). A backed-off
		// app costs AX_CALL_TIMEOUT here, and a few of them on screen push the
		// callback past the WindowServer's budget — which passes the keystroke
		// through to the app (stray ∆˚¬˙) and disables the tap. Skip them; their
		// width is re-learned once the backoff lifts.
		if mac.ax_pid_slow(m.pid) do continue
		sz, got := mac.ax_size(m.ax)
		if !got do continue
		actual := f64(sz.width)
		if actual < m.req_w - WIDTH_TOL {
			col.eff_w = actual // clamped narrower than asked → pack against the real width
		}
	}
}

