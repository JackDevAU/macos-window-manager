package macos

import "core:c"
import CF "core:sys/darwin/CoreFoundation"

// Linked from screens.o (compiled by build.sh from screens.m).
foreign import shim "screens.o"

// Must match the C struct in screens.m exactly (display_id, _pad, then 4 doubles).
WMVisibleFrame :: struct {
	display_id: u32,
	_pad:       u32,
	x, y, w, h: f64,
}

// Must match the C WMBarSeg struct in screens.m.
WMBarSeg :: struct {
	app:       cstring,
	title:     cstring,
	window_id: u64,
	focused:   c.int,
	index:     c.int, // 1-based position (matches Alt+<n>); 0 = none
}

WM_BAR_NONE :: max(u64) // sentinel id for non-window bar segments / no hit
WM_BAR_MODE :: max(u64) - 1 // clickable "layout mode" toggle segment
WM_BAR_SETTINGS :: max(u64) - 2 // clickable settings (gear) segment

// Must match the C WMSettingsRow struct in screens.m.
WMSettingsRow :: struct {
	app:     cstring,
	title:   cstring,
	ignored: c.int,
}

@(default_calling_convention = "c")
foreign shim {
	wm_visible_frames :: proc(out: [^]WMVisibleFrame, max: c.int) -> c.int ---
	wm_frontmost_pid  :: proc() -> i32 ---
	wm_ring_show      :: proc(x, y, w, h: f64) ---
	wm_ring_hide      :: proc() ---
	wm_bar_set        :: proc(idx: c.int, segs: [^]WMBarSeg, count: c.int, x, y, w, h: f64) ---
	wm_bar_hit        :: proc(idx: c.int, local_x: f64) -> u64 ---
	wm_bar_hide       :: proc() --- // hide all bars
	wm_bar_hide_from  :: proc(from: c.int) --- // hide bars at index >= from (display unplugged)
	wm_bar_status_refresh :: proc() --- // refresh the right-aligned clock/battery/wifi cluster
	wm_menu_bar_height :: proc() -> f64 --- // system menu-bar thickness (~24pt)
	wm_settings_set_handler :: proc(fn: proc "c" (cmd: cstring)) --- // register the command callback
	wm_settings_open        :: proc() ---
	wm_settings_is_open     :: proc() -> c.int ---
	wm_settings_set_info    :: proc(config: cstring, hotkeys: cstring) ---
	wm_settings_set_rows    :: proc(rows: [^]WMSettingsRow, count: c.int) ---
	wm_app_run              :: proc() --- // run the AppKit event loop (services CFRunLoop sources too)
	wm_app_stop             :: proc() --- // stop the AppKit event loop
	wm_stage_capture_window :: proc(cg_window_id: u32) --- // mirror this window onto the share stage (shows it)
	wm_stage_hide           :: proc() ---
	wm_stage_window_id      :: proc() -> u32 --- // the stage's own CGWindowID (0 if not shown), for self-exclusion
	wm_screen_capture_authorized :: proc() -> c.int --- // Screen Recording granted?
	wm_screen_capture_request    :: proc() --- // prompt for Screen Recording
}

// The currently focused window, retained (caller releases with CF.Release).
//
// We resolve the frontmost app via NSWorkspace (the system-wide AX "focused
// application" attribute is unavailable to a background process), then take its
// focused window, falling back to its main window or first window.
focused_window :: proc() -> (AXUIElement, bool) {
	pid := wm_frontmost_pid()
	if pid <= 0 do return nil, false

	app := AXUIElementCreateApplication(c.int(pid))
	defer CF.Release(CF.TypeRef(app))

	// AXUIElementCopyAttributeValue returns a +1 reference, so the value we
	// hand back is owned by the caller.
	if v, ok := ax_get(app, "AXFocusedWindow"); ok do return AXUIElement(v), true
	if v, ok := ax_get(app, "AXMainWindow"); ok do return AXUIElement(v), true
	return first_window(pid)
}

// CGDirectDisplayIDs of all active displays, written into `buf`.
active_displays :: proc(buf: []u32) -> []u32 {
	count: c.uint32_t
	CGGetActiveDisplayList(c.uint32_t(len(buf)), raw_data(buf), &count)
	return buf[:count]
}

// The display whose full bounds contain the point (window center).
display_for_point :: proc(px, py: f64) -> (u32, bool) {
	buf: [16]u32
	for id in active_displays(buf[:]) {
		b := CGDisplayBounds(id)
		x0 := f64(b.origin.x)
		y0 := f64(b.origin.y)
		if px >= x0 && px < x0 + f64(b.size.width) && py >= y0 && py < y0 + f64(b.size.height) {
			return id, true
		}
	}
	return 0, false
}

// The usable rect (menu bar / Dock excluded) of a display. Falls back to the
// full display bounds if the NSScreen shim has no entry for it.
visible_frame :: proc(display_id: u32) -> CF.CGRect {
	frames: [16]WMVisibleFrame
	n := int(wm_visible_frames(raw_data(frames[:]), 16))
	for i in 0 ..< n {
		f := frames[i]
		if f.display_id == display_id {
			return CF.CGRect{
				CF.CGPoint{CF.CGFloat(f.x), CF.CGFloat(f.y)},
				CF.CGSize{CF.CGFloat(f.w), CF.CGFloat(f.h)},
			}
		}
	}
	return CGDisplayBounds(display_id)
}
