package macos

import "core:c"
import "core:strings"
import "core:sys/posix"
import CF "core:sys/darwin/CoreFoundation"

// CoreFoundation boolean singletons (needed to set AXMinimized).
foreign import cfb "system:CoreFoundation.framework"

@(default_calling_convention = "c")
foreign cfb {
	kCFBooleanTrue:  CF.TypeRef
	kCFBooleanFalse: CF.TypeRef
}

// A standard, managed window: a retained AX element plus identifying info.
// Caller owns `ax` (CF.Release) and `title` (delete).
Std_Window :: struct {
	pid:   i32,
	ax:    AXUIElement,
	cgwin: u32, // CGWindowID (0 if unknown) — lets frame reads skip AX for slow apps
	title: string, // window title (AXTitle)
	app:   string, // owning application name (CGWindow owner)
	frame: CF.CGRect,
}

// Minimize or unminimize a window.
ax_set_minimized :: proc(w: AXUIElement, minimized: bool) -> AXError {
	a := cf_str("AXMinimized")
	defer CF.Release(CF.TypeRef(a))
	return AXUIElementSetAttributeValue(w, a, minimized ? kCFBooleanTrue : kCFBooleanFalse)
}

// Give a window real keyboard focus: make it its app's main window, raise it,
// then make its app frontmost. Setting AXMain is what makes the app report this
// window as its focused window (AXRaise alone only changes z-order). pid is the
// window's owning process.
focus_window :: proc(w: AXUIElement, pid: i32) {
	ma := cf_str("AXMain")
	defer CF.Release(CF.TypeRef(ma))
	AXUIElementSetAttributeValue(w, ma, kCFBooleanTrue)

	ax_raise(w)

	// Patient timeout: this is a one-off user action (hotkey/click), and an
	// AX-slow app (Godot) would drop the AXFrontmost write under the short cap.
	app := ax_app_patient(pid)
	defer CF.Release(CF.TypeRef(app))
	fa := cf_str("AXFrontmost")
	defer CF.Release(CF.TypeRef(fa))
	AXUIElementSetAttributeValue(app, fa, kCFBooleanTrue)
}

// Release the AX element and free the strings of a Std_Window.
std_window_destroy :: proc(w: Std_Window) {
	CF.Release(CF.TypeRef(w.ax))
	delete(w.title)
	delete(w.app)
}

// Enumerate every standard, on-screen window (role AXWindow, subrole
// AXStandardWindow) across all applications. If `app_filter` is non-empty, only
// windows owned by an app of that name are returned (used to scope a live test
// to a single throwaway app). Each result holds a retained AX element; caller
// destroys each with std_window_destroy and deletes the slice.
standard_windows :: proc(app_filter: string = "", allocator := context.allocator) -> [dynamic]Std_Window {
	out := make([dynamic]Std_Window, allocator)

	opts := u32(CGWindowListOption.OnScreenOnly) | u32(CGWindowListOption.ExcludeDesktopElements)
	arr := CGWindowListCopyWindowInfo(opts, 0)
	if arr == nil do return out
	defer CF.Release(arr)

	seen := make(map[i32]bool)
	defer delete(seen)

	self_pid := i32(posix.getpid()) // skip our own windows (focus ring, bar, share stage)

	n := CFArrayGetCount(arr)
	for i in 0 ..< n {
		d := CFArrayGetValueAtIndex(arr, i)

		layer, _ := dict_number_i32(d, "kCGWindowLayer")
		if layer != 0 do continue
		pid, _ := dict_number_i32(d, "kCGWindowOwnerPID")
		if pid == self_pid do continue
		if pid in seen do continue
		seen[pid] = true

		owner, _ := dict_string(d, "kCGWindowOwnerName") // app name (shared by this pid's windows)
		defer delete(owner)
		if app_filter != "" && owner != app_filter do continue

		// Don't re-poke an app whose AX server recently timed out: every query
		// below blocks the run loop for the full messaging timeout. Its
		// windows still get adopted — via the daemon's slow lane, which calls
		// slow_app_windows off the main thread.
		if ax_pid_slow(pid) do continue

		append_windows_of_app(&out, pid, owner, AX_CALL_TIMEOUT, abort_when_slow = true)
	}
	return out
}

// Windows of the apps currently in AX backoff, enumerated with the patient
// timeout. Run this OFF the main thread (the daemon's slow lane): each call
// may block for up to AX_PATIENT_TIMEOUT × calls, which is the whole point —
// the worker eats the wait so the event tap never does. Same ownership
// contract as standard_windows.
slow_app_windows :: proc(app_filter: string = "", allocator := context.allocator) -> [dynamic]Std_Window {
	out := make([dynamic]Std_Window, allocator)

	opts := u32(CGWindowListOption.OnScreenOnly) | u32(CGWindowListOption.ExcludeDesktopElements)
	arr := CGWindowListCopyWindowInfo(opts, 0)
	if arr == nil do return out
	defer CF.Release(arr)

	seen := make(map[i32]bool)
	defer delete(seen)

	n := CFArrayGetCount(arr)
	for i in 0 ..< n {
		d := CFArrayGetValueAtIndex(arr, i)
		layer, _ := dict_number_i32(d, "kCGWindowLayer")
		if layer != 0 do continue
		pid, _ := dict_number_i32(d, "kCGWindowOwnerPID")
		if pid in seen do continue
		seen[pid] = true
		if !ax_pid_slow(pid) do continue // fast lane's job

		owner, _ := dict_string(d, "kCGWindowOwnerName")
		defer delete(owner)
		if app_filter != "" && owner != app_filter do continue

		start := len(out)
		append_windows_of_app(&out, pid, owner, AX_PATIENT_TIMEOUT, abort_when_slow = false)

		// A loose app is lightly wrapped: track only its one primary window.
		// Godot & co. spawn child windows (the "Create New Node" dialog, docks,
		// the running game — some *larger* than the editor, and Godot even
		// reports the open dialog as its AXMainWindow/AXFocusedWindow) that
		// should stay entirely outside the tiling ecosystem. The reliable
		// signal is the CGWindowID: the primary window is the oldest, so it has
		// the lowest window number; every transient child is created later and
		// gets a higher one. Pick the smallest non-zero cgwin, falling back to
		// the largest window if no IDs are available.
		if len(out) - start > 1 {
			best := start
			for k in start + 1 ..< len(out) {
				if primary_beats(out[k], out[best]) do best = k
			}
			for k := len(out) - 1; k >= start; k -= 1 {
				if k == best do continue
				std_window_destroy(out[k])
				ordered_remove(&out, k)
			}
		}
	}
	return out
}

// Whether window `a` is a better "primary window" pick than `b`: lower non-zero
// CGWindowID wins (oldest window); ties and missing IDs fall back to larger area.
@(private = "file")
primary_beats :: proc(a, b: Std_Window) -> bool {
	if a.cgwin != 0 && b.cgwin != 0 do return a.cgwin < b.cgwin
	if a.cgwin != 0 && b.cgwin == 0 do return true
	if a.cgwin == 0 && b.cgwin != 0 do return false
	return frame_area(a.frame) > frame_area(b.frame)
}

@(private = "file")
frame_area :: proc(r: CF.CGRect) -> f64 {
	return f64(r.size.width) * f64(r.size.height)
}

// Shared enumeration body: one app's standard windows appended to `out`, every
// element capped at `timeout`. `abort_when_slow` is the fast lane's escape
// hatch — a slow success on AXWindows flags the pid (see ax_get_err) and we
// stop before piling per-window reads on a stalled AX server. The slow lane
// passes false: its whole purpose is to keep going.
@(private = "file")
append_windows_of_app :: proc(out: ^[dynamic]Std_Window, pid: i32, owner: string, timeout: f32, abort_when_slow: bool) {
	app := AXUIElementCreateApplication(c.int(pid))
	AXUIElementSetMessagingTimeout(app, timeout)
	defer CF.Release(CF.TypeRef(app))

	wins, werr := ax_get_err(app, "AXWindows")
	if werr == .CannotComplete {
		ax_mark_slow(pid)
		return
	}
	if werr != .Success do return
	defer CF.Release(wins)

	if abort_when_slow && ax_pid_slow(pid) do return

	wn := CFArrayGetCount(wins)
	for j in 0 ..< wn {
		w := AXUIElement(CFArrayGetValueAtIndex(wins, j))
		// Window elements get the timeout too: they are retained into the
		// registry and every later read/write (title, frame, tiling writes)
		// goes through this same element instance.
		AXUIElementSetMessagingTimeout(w, timeout)

		subrole, _ := ax_string(w, "AXSubrole")
		standard := subrole == "AXStandardWindow"
		delete(subrole)
		if !standard do continue

		cgwin: u32
		_AXUIElementGetWindow(w, &cgwin) // best-effort; stays 0 if unavailable

		title, _ := ax_title(w)
		pos, _ := ax_position(w)
		sz, _ := ax_size(w)
		append(out, Std_Window{
			pid   = pid,
			ax    = AXUIElement(CFRetain(CF.TypeRef(w))),
			cgwin = cgwin,
			title = title,
			app   = strings.clone(owner),
			frame = CF.CGRect{pos, sz},
		})
	}
}
