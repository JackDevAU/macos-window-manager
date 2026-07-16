package main

import "base:runtime"
import "core:c"
import "core:c/libc"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import CF "core:sys/darwin/CoreFoundation"
import "layout"
import mac "macos"

USAGE :: `niri-mac commands:
  list                 enumerate all on-screen windows (CGWindowList + AX)
  poke [App]           demo: move/resize/maximize/park/restore a window (default TextEdit)
  snap <preset>        snap the focused window within its display
  maximize             fill the focused window's display (alias: snap maximize)
  center               center the focused window at 60%% (alias: snap center)
  move-monitor <next|prev>   move the focused window to the next/prev display
  strip-demo           visualize the niri scrollable-strip engine (moves nothing)
  bar-demo             float the status bar mid-screen for a few seconds (visual check)

daemon (scrollable tiling; dry-run by default — logs intended moves):
  daemon [App]         run the daemon; with App, manage only that app's windows (safe for live test)
  sync                 (re)build the strip from current standard windows
  state                show the strip + the layout the effector would apply
  focus-left|right|up|down     move focus around the strip
  move-left|right      move the focused column
  width                cycle the focused column width (1/3 1/2 2/3)
  consume|expel        merge the next window into / split out of the column
  windows              list tiled windows: id<TAB>ws<TAB>app<TAB>title (for fuzzy pickers)
  focus-window <id>    jump to a window by id (un-hides it / switches workspace)
  float                toggle the focused window between tiled and floating (Alt+F)
  ignore <App>         never tile that app's windows (e.g. notification popups)
  unignore <App>       resume tiling that app's windows
  settings             open the settings window (gear on the bar / Alt+S)
  workspace <n>        switch to workspace n (others hidden)
  move-to-workspace <n>  send the focused window to workspace n
  live on|off          apply layout to real windows (off = dry-run) — disable your other WM first
  stage                mirror the focused window onto the share Stage (Alt+P)
  stage-hide           stop the Stage capture and hide it
  stop                 stop the daemon (graceful: restores windows)
  kill                 force-stop ALL running wm daemons (no restore)

snap presets:
  maximize center
  left right top bottom
  tl tr bl br                (quarters)
  l3 c3 r3                   (thirds)
  l23 r23                    (two-thirds: left/right)`

main :: proc() {
	cmd := "list"
	if len(os.args) > 1 do cmd = os.args[1]

	switch cmd {
	case "list":
		cmd_list()
	case "poke":
		app := "TextEdit"
		if len(os.args) > 2 do app = os.args[2]
		cmd_poke(app)
	case "snap":
		if len(os.args) < 3 {
			fmt.println("usage: snap <preset>\n");fmt.println(USAGE);return
		}
		cmd_snap(os.args[2])
	case "maximize":
		cmd_snap("maximize")
	case "center":
		cmd_snap("center")
	case "move-monitor":
		dir := len(os.args) > 2 ? os.args[2] : "next"
		cmd_move_monitor(dir)
	case "focused":
		cmd_focused()
	case "displays":
		cmd_displays()
	case "strip-demo":
		cmd_strip_demo()
	case "bar-demo":
		cmd_bar_demo()
	case "settings-demo":
		cmd_settings_demo()
	case "daemon":
		app := len(os.args) > 2 ? os.args[2] : ""
		run_daemon(app)
	case "synth-key":
		// Debug: synthesize Alt+L to exercise the daemon's hotkey tap.
		mac.post_key(37, mac.FLAG_ALT)
		fmt.println("posted Alt+L")
	case "kill":
		cmd_kill()
	case "ping", "sync", "state", "live", "stop",
	     "focus-left", "focus-right", "focus-up", "focus-down",
	     "move-left", "move-right", "width", "width-max", "consume", "expel",
	     "windows", "focus-window",
	     "workspace", "move-to-workspace", "hide-mode", "mode",
	     "float", "ignore", "unignore", "settings", "stage", "stage-hide":
		forward_to_daemon()
	case "help", "-h", "--help":
		fmt.println(USAGE)
	case:
		fmt.printfln("unknown command %q\n", cmd)
		fmt.println(USAGE)
	}
}

// Throwaway visual check for the status bar (segments + clock/battery/wifi
// cluster). Floats the bar mid-screen so it doesn't fight a running daemon's top
// bar, refreshes for a few seconds, then exits. Moves no windows.
@(private = "file")
bar_demo_ticks: int

@(private = "file")
bar_demo_tick :: proc "c" (timer: mac.CFRunLoopTimer, info: rawptr) {
	context = runtime.default_context()
	mac.wm_bar_status_refresh()
	bar_demo_ticks += 1
	if bar_demo_ticks >= 10 do mac.CFRunLoopStop(mac.CFRunLoopGetCurrent())
}

cmd_bar_demo :: proc() {
	vf := mac.visible_frame(mac.CGMainDisplayID())
	segs := []mac.WMBarSeg {
		{window_id = mac.WM_BAR_SETTINGS},
		{app = "ws 1/1", title = "tiling", window_id = mac.WM_BAR_NONE},
		{app = "columns", window_id = mac.WM_BAR_MODE},
		{app = "Safari", title = "Apple", window_id = 1, focused = 1, index = 1},
		{app = "Terminal", title = "wm — zsh", window_id = 2, index = 2},
		{app = "Notes", title = "Bar ideas", window_id = 3, index = 3},
	}
	// Mid-screen so it's clearly separate from a live daemon's top bar.
	x := f64(vf.origin.x)
	y := f64(vf.origin.y) + 300
	w := f64(vf.size.width)
	mac.wm_bar_set(0, raw_data(segs), c.int(len(segs)), x, y, w, BAR_H)
	mac.wm_bar_status_refresh()

	rl := mac.CFRunLoopGetCurrent()
	t := mac.CFRunLoopTimerCreate(nil, mac.CFAbsoluteTimeGetCurrent() + 0.5, 0.5, 0, 0, bar_demo_tick, nil)
	mac.CFRunLoopAddTimer(rl, t, mac.kCFRunLoopDefaultMode)
	fmt.println("bar-demo: floating the status bar mid-screen for ~5s")
	mac.CFRunLoopRun()
	mac.wm_bar_hide()
}

// Throwaway visual check for the settings window: populates it with the real
// open-window list + sample config and shows it for a few seconds.
@(private = "file")
settings_demo_cmd :: proc "c" (cmd: cstring) {
	context = runtime.default_context()
	fmt.printfln("settings-demo: button -> %q", string(cmd))
}

@(private = "file")
settings_demo_ticks: int

@(private = "file")
settings_demo_tick :: proc "c" (timer: mac.CFRunLoopTimer, info: rawptr) {
	context = runtime.default_context()
	settings_demo_ticks += 1
	if settings_demo_ticks >= 30 do mac.wm_app_stop()
}

cmd_settings_demo :: proc() {
	mac.wm_settings_set_handler(settings_demo_cmd)
	mac.wm_settings_open()

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
	for w, i in wins {
		app_c := strings.clone_to_cstring(w.app)
		title_c := strings.clone_to_cstring(w.title)
		append(&cstrs, app_c, title_c)
		append(&rows, mac.WMSettingsRow{app = app_c, title = title_c, ignored = (i % 4 == 0) ? 1 : 0})
	}
	mac.wm_settings_set_rows(raw_data(rows[:]), c.int(len(rows)))

	cfg_c := strings.clone_to_cstring("Tiling: on      Layout: columns      Hide: off-screen      Gap: 12px")
	defer delete(cfg_c)
	hk_c := strings.clone_to_cstring(HOTKEYS_TEXT)
	defer delete(hk_c)
	mac.wm_settings_set_info(cfg_c, hk_c)

	rl := mac.CFRunLoopGetCurrent()
	t := mac.CFRunLoopTimerCreate(nil, mac.CFAbsoluteTimeGetCurrent() + 0.5, 0.5, 0, 0, settings_demo_tick, nil)
	mac.CFRunLoopAddTimer(rl, t, mac.kCFRunLoopDefaultMode)
	fmt.println("settings-demo: showing the settings window for ~15s — click the buttons (clicks print here)")
	mac.wm_app_run()
}

// Force-stop every running `wm daemon` process (no graceful window restore —
// use `wm stop` for that). The `[w]m` regex matches the daemons' command lines
// but not the shell running pkill itself, so it never kills its own invocation.
cmd_kill :: proc() {
	n := libc.system("pkill -f '[w]m daemon'")
	fmt.println(n == 0 ? "killed running wm daemon(s)" : "no running wm daemon found")
}

// Forward the invocation (verbatim args) to the running daemon and print its reply.
forward_to_daemon :: proc() {
	cmd := strings.join(os.args[1:], " ")
	defer delete(cmd)
	reply, ok := ipc_send(cmd)
	if !ok {
		fmt.println("could not reach daemon — start it with:  wm daemon")
		return
	}
	defer delete(reply)
	fmt.print(reply)
}

// ---------------------------------------------------------------------------
// M1: read path — enumerate windows via CGWindowList + the AX API.
// ---------------------------------------------------------------------------

cmd_list :: proc() {
	fmt.println("niri-mac: M1 — accessibility permission + window enumeration")
	fmt.printfln("Accessibility trusted: %v\n", bool(mac.AXIsProcessTrusted()))

	pids := collect_onscreen_windows()
	defer {
		for _, name in pids do delete(name)
		delete(pids)
	}

	fmt.println("\n== AX view (per application) ==")
	for pid, app in pids {
		print_ax_windows(pid, app)
	}
}

collect_onscreen_windows :: proc() -> map[i32]string {
	pids := make(map[i32]string)

	opts := u32(mac.CGWindowListOption.OnScreenOnly) | u32(mac.CGWindowListOption.ExcludeDesktopElements)
	arr := mac.CGWindowListCopyWindowInfo(opts, 0)
	if arr == nil {
		fmt.println("CGWindowListCopyWindowInfo returned nil")
		return pids
	}
	defer CF.Release(arr)

	fmt.println("== On-screen windows (CGWindowList) ==")
	n := mac.CFArrayGetCount(arr)
	for i in 0 ..< n {
		d := mac.CFArrayGetValueAtIndex(arr, i)

		layer, _ := mac.dict_number_i32(d, "kCGWindowLayer")
		if layer != 0 do continue

		pid, _ := mac.dict_number_i32(d, "kCGWindowOwnerPID")
		num, _ := mac.dict_number_i32(d, "kCGWindowNumber")
		app, _ := mac.dict_string(d, "kCGWindowOwnerName")
		rect, _ := mac.dict_bounds(d, "kCGWindowBounds")

		fmt.printfln(
			"  pid=%d  win#%d  %-24s (%.0f,%.0f  %.0fx%.0f)",
			pid, num, app,
			f64(rect.x), f64(rect.y), f64(rect.width), f64(rect.height),
		)

		if pid in pids {
			delete(app)
		} else {
			pids[pid] = app
		}
	}
	return pids
}

print_ax_windows :: proc(pid: i32, app: string) {
	appel := mac.AXUIElementCreateApplication(c.int(pid))
	defer CF.Release(CF.TypeRef(appel))

	wins, ok := mac.ax_get(appel, "AXWindows")
	if !ok {
		fmt.printfln("  %s (pid %d): <no accessible windows>", app, pid)
		return
	}
	defer CF.Release(wins)

	n := mac.CFArrayGetCount(wins)
	fmt.printfln("  %s (pid %d): %d window(s)", app, pid, n)
	for i in 0 ..< n {
		w := mac.AXUIElement(mac.CFArrayGetValueAtIndex(wins, i))

		title, _ := mac.ax_title(w)
		defer delete(title)
		role, _ := mac.ax_string(w, "AXRole")
		defer delete(role)
		pos, _ := mac.ax_position(w)
		sz, _ := mac.ax_size(w)

		fmt.printfln(
			"      - %-50q %s  (%.0f,%.0f  %.0fx%.0f)",
			title, role,
			f64(pos.x), f64(pos.y), f64(sz.width), f64(sz.height),
		)
	}
}

// ---------------------------------------------------------------------------
// M2: write path — move / resize / raise / maximize / off-screen park a window,
// then restore it. Run against a throwaway window (e.g. a TextEdit canary).
// ---------------------------------------------------------------------------

cmd_poke :: proc(app_name: string) {
	fmt.printfln("niri-mac: M2 — manipulate a window of %q\n", app_name)
	if !bool(mac.AXIsProcessTrusted()) {
		fmt.println("ERROR: process is not Accessibility-trusted")
		return
	}

	pid, w, found := wait_for_window(app_name, 40)
	if !found {
		fmt.printfln("could not find a window for %q (is it open?)", app_name)
		return
	}
	defer CF.Release(CF.TypeRef(w))
	fmt.printfln("target: %s (pid %d)\n", app_name, pid)

	// Snapshot the original frame so we can put it back exactly.
	orig_pos, _ := mac.ax_position(w)
	orig_size, _ := mac.ax_size(w)
	report("original", w)

	fmt.printfln("  AXRaise -> %v", mac.ax_raise(w))
	pause()

	do_move(w, "move (120,120)", {120, 120})
	do_size(w, "resize 900x640", {900, 640})
	do_move(w, "move (520,300)", {520, 300})

	// Maximize to the main display (inset for the menu bar): exercises a
	// combined move+resize, the basis for the M3 "maximize" command.
	disp := mac.CGDisplayBounds(mac.CGMainDisplayID())
	fmt.printfln(
		"\n  main display: (%.0f,%.0f  %.0fx%.0f)",
		f64(disp.origin.x), f64(disp.origin.y), f64(disp.size.width), f64(disp.size.height),
	)
	TOP :: 28
	do_size(w, "maximize size", {disp.size.width - 16, disp.size.height - TOP - 8})
	do_move(w, "maximize pos", {disp.origin.x + 8, disp.origin.y + TOP})

	// The make-or-break test: try to shove the window far off the right edge and
	// see whether the app honors it (parkable) or the OS/app clamps it back.
	fmt.println("\n-- off-screen parking test --")
	park := CF.CGPoint{disp.origin.x + disp.size.width + 4000, disp.origin.y + 200}
	mac.ax_set_position(w, park)
	pause()
	actual, _ := mac.ax_position(w)
	verdict := f64(actual.x) >= f64(park.x) - 1 ? "PARKED fully off-screen" : "CLAMPED back toward screen"
	fmt.printfln("  requested x=%.0f  ->  actual x=%.0f   [%s]", f64(park.x), f64(actual.x), verdict)

	// Restore the original frame.
	fmt.println("\n-- restore --")
	mac.ax_set_size(w, orig_size)
	mac.ax_set_position(w, orig_pos)
	pause()
	report("restored", w)
}

pause :: proc() {
	time.sleep(700 * time.Millisecond)
}

report :: proc(label: string, w: mac.AXUIElement) {
	p, _ := mac.ax_position(w)
	s, _ := mac.ax_size(w)
	fmt.printfln("  %-16s (%.0f,%.0f  %.0fx%.0f)", label, f64(p.x), f64(p.y), f64(s.width), f64(s.height))
}

do_move :: proc(w: mac.AXUIElement, label: string, p: CF.CGPoint) {
	mac.ax_set_position(w, p)
	pause()
	report(label, w)
}

do_size :: proc(w: mac.AXUIElement, label: string, s: CF.CGSize) {
	mac.ax_set_size(w, s)
	pause()
	report(label, w)
}

// Poll until the named app has an accessible window (it may have just launched).
wait_for_window :: proc(app_name: string, tries: int) -> (pid: i32, w: mac.AXUIElement, ok: bool) {
	for _ in 0 ..< tries {
		if p, found := mac.find_app_pid(app_name); found {
			if win, ok2 := mac.first_window(p); ok2 {
				return p, win, true
			}
		}
		time.sleep(300 * time.Millisecond)
	}
	return 0, nil, false
}

// ---------------------------------------------------------------------------
// M3: direct window ops on the focused window (CLI-triggered, no global hotkeys).
// ---------------------------------------------------------------------------

// Drive the pure scrollable-strip engine through a scripted sequence and render
// each step. Purely in-memory — no windows are touched. This is what M5 will
// wire to real windows + the AX effector.
cmd_strip_demo :: proc() {
	vp := layout.Rect{0, 0, 1920, 1080}
	s := layout.make_strip(12)
	defer layout.strip_destroy(&s)

	fmt.println("niri-mac: M4 scrollable-strip engine (in-memory demo, nothing moves)")
	fmt.printfln("viewport %.0fx%.0f, gap %.0f", vp.w, vp.h, s.gap)

	layout.add_window(&s, 1)
	layout.add_window(&s, 2)
	layout.add_window(&s, 3)
	print_strip(&s, vp, "open 3 windows (each 1/2 width)")

	layout.focus_left(&s)
	layout.focus_left(&s)
	print_strip(&s, vp, "focus leftmost column")

	layout.cycle_width(&s)
	print_strip(&s, vp, "cycle focused width (1/2 -> 2/3)")

	layout.add_window(&s, 4)
	print_strip(&s, vp, "open window 4 (inserts right of focus, others unchanged)")

	layout.add_tile(&s, 5)
	print_strip(&s, vp, "stack window 5 into the focused column")

	layout.focus_right(&s)
	layout.focus_right(&s)
	layout.focus_right(&s)
	print_strip(&s, vp, "focus rightmost (view scrolls; left columns hide)")
}

// Render the logical strip + the computed layout for a viewport.
print_strip :: proc(s: ^layout.Strip, vp: layout.Rect, label: string) {
	fmt.printfln("\n── %s ──", label)

	for col, ci in s.columns {
		fmt.printf(ci == s.focused_col ? "  > col%d (w=%.2f):" : "    col%d (w=%.2f):", ci, col.width_frac)
		for tile, ti in col.tiles {
			focused := ci == s.focused_col && ti == col.focused_tile
			fmt.printf(focused ? " [%d*]" : " [%d]", u64(tile.id))
		}
		fmt.println()
	}

	ps := layout.compute_layout(s, vp)
	defer delete(ps)
	fid, hasf := layout.focused_window(s)

	// Proportional bar of the viewport: '=' focused col, '#' other visible, '.' empty.
	BAR :: 64
	row: [BAR]u8
	for i in 0 ..< BAR do row[i] = '.'
	for p in ps {
		if !p.visible do continue
		x0 := clamp(int((p.rect.x - vp.x) / vp.w * BAR), 0, BAR)
		x1 := clamp(int((p.rect.x + p.rect.w - vp.x) / vp.w * BAR), 0, BAR)
		ch: u8 = hasf && p.id == fid ? '=' : '#'
		for i in x0 ..< x1 do row[i] = ch
	}
	fmt.printfln("  view_x=%.0f  [%s]", s.view_x, string(row[:]))
	for p in ps {
		fmt.printfln(
			"    win %d: (%.0f,%.0f  %.0fx%.0f) %s",
			u64(p.id), p.rect.x, p.rect.y, p.rect.w, p.rect.h,
			p.visible ? "visible" : "HIDDEN",
		)
	}
}

// Read-only: compare the two display-geometry sources.
cmd_displays :: proc() {
	fmt.println("== CGGetActiveDisplayList + CGDisplayBounds (full) ==")
	buf: [16]u32
	for id in mac.active_displays(buf[:]) {
		b := mac.CGDisplayBounds(id)
		fmt.printfln(
			"  display #%d  (%.0f,%.0f  %.0fx%.0f)",
			id, f64(b.origin.x), f64(b.origin.y), f64(b.size.width), f64(b.size.height),
		)
	}

	fmt.println("== NSScreen shim visibleFrame (CG coords) ==")
	frames: [16]mac.WMVisibleFrame
	n := int(mac.wm_visible_frames(raw_data(frames[:]), 16))
	fmt.printfln("  (%d screens)", n)
	for i in 0 ..< n {
		f := frames[i]
		fmt.printfln("  display #%d  (%.0f,%.0f  %.0fx%.0f)", f.display_id, f.x, f.y, f.w, f.h)
	}
}

// Read-only: report the focused window and the display it sits on.
cmd_focused :: proc() {
	w, found := mac.focused_window()
	if !found {
		fmt.println("no focused window")
		return
	}
	defer CF.Release(CF.TypeRef(w))

	title, _ := mac.ax_title(w)
	defer delete(title)
	win := win_rect(w)
	cx, cy := layout.center_of(win)

	fmt.printfln("focused: %q  (%.0f,%.0f  %.0fx%.0f)", title, win.x, win.y, win.w, win.h)
	if disp, ok := mac.display_for_point(cx, cy); ok {
		vf := to_rect(mac.visible_frame(disp))
		fmt.printfln("  display #%d  visibleFrame (%.0f,%.0f  %.0fx%.0f)", disp, vf.x, vf.y, vf.w, vf.h)
	} else {
		fmt.println("  display: <unknown>")
	}
}

cmd_snap :: proc(name: string) {
	preset, ok := parse_preset(name)
	if !ok {
		fmt.printfln("unknown preset %q\n", name)
		fmt.println(USAGE)
		return
	}

	w, found := mac.focused_window()
	if !found {
		fmt.println("no focused window")
		return
	}
	defer CF.Release(CF.TypeRef(w))

	win := win_rect(w)
	cx, cy := layout.center_of(win)
	disp, dok := mac.display_for_point(cx, cy)
	if !dok {
		fmt.println("could not determine which display the window is on")
		return
	}

	area := to_rect(mac.visible_frame(disp))
	target := layout.apply_preset(area, preset)
	mac.set_frame(w, to_cg(target))

	fmt.printfln("snap %s -> (%.0f,%.0f  %.0fx%.0f)", name, target.x, target.y, target.w, target.h)
}

cmd_move_monitor :: proc(dir: string) {
	if dir != "next" && dir != "prev" {
		fmt.printfln("usage: move-monitor <next|prev> (got %q)", dir)
		return
	}

	w, found := mac.focused_window()
	if !found {
		fmt.println("no focused window")
		return
	}
	defer CF.Release(CF.TypeRef(w))

	win := win_rect(w)
	cx, cy := layout.center_of(win)
	cur, dok := mac.display_for_point(cx, cy)
	if !dok {
		fmt.println("could not determine which display the window is on")
		return
	}

	buf: [16]u32
	ids := mac.active_displays(buf[:])
	if len(ids) < 2 {
		fmt.println("only one display active; nothing to do")
		return
	}

	// Index of the current display, then step to next/prev (wrapping).
	idx := 0
	for id, i in ids do if id == cur do idx = i
	target_idx := dir == "next" ? (idx + 1) % len(ids) : (idx - 1 + len(ids)) % len(ids)
	target := ids[target_idx]

	src := to_rect(mac.visible_frame(cur))
	dst := to_rect(mac.visible_frame(target))
	moved := layout.remap(win, src, dst)
	mac.set_frame(w, to_cg(moved))
	mac.ax_raise(w)

	fmt.printfln("move-monitor %s -> (%.0f,%.0f  %.0fx%.0f)", dir, moved.x, moved.y, moved.w, moved.h)
}

// --- small conversion / parsing helpers ---

win_rect :: proc(w: mac.AXUIElement) -> layout.Rect {
	p, _ := mac.ax_position(w)
	s, _ := mac.ax_size(w)
	return {f64(p.x), f64(p.y), f64(s.width), f64(s.height)}
}

to_rect :: proc(r: CF.CGRect) -> layout.Rect {
	return {f64(r.origin.x), f64(r.origin.y), f64(r.size.width), f64(r.size.height)}
}

to_cg :: proc(r: layout.Rect) -> CF.CGRect {
	return CF.CGRect{
		CF.CGPoint{CF.CGFloat(r.x), CF.CGFloat(r.y)},
		CF.CGSize{CF.CGFloat(r.w), CF.CGFloat(r.h)},
	}
}

parse_preset :: proc(name: string) -> (layout.Preset, bool) {
	switch name {
	case "maximize", "max", "full":
		return .Maximize, true
	case "center", "centre":
		return .Center, true
	case "left":
		return .Left_Half, true
	case "right":
		return .Right_Half, true
	case "top":
		return .Top_Half, true
	case "bottom":
		return .Bottom_Half, true
	case "tl", "top-left":
		return .Top_Left, true
	case "tr", "top-right":
		return .Top_Right, true
	case "bl", "bottom-left":
		return .Bottom_Left, true
	case "br", "bottom-right":
		return .Bottom_Right, true
	case "l3", "left-third":
		return .Left_Third, true
	case "c3", "center-third":
		return .Center_Third, true
	case "r3", "right-third":
		return .Right_Third, true
	case "l23", "left-two-thirds":
		return .Left_Two_Thirds, true
	case "r23", "right-two-thirds":
		return .Right_Two_Thirds, true
	}
	return .Maximize, false
}
