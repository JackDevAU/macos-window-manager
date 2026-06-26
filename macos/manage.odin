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

	ax_perform(w, "AXRaise")

	app := AXUIElementCreateApplication(c.int(pid))
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

		app := AXUIElementCreateApplication(c.int(pid))
		defer CF.Release(CF.TypeRef(app))

		wins, ok := ax_get(app, "AXWindows")
		if !ok do continue
		defer CF.Release(wins)

		wn := CFArrayGetCount(wins)
		for j in 0 ..< wn {
			w := AXUIElement(CFArrayGetValueAtIndex(wins, j))

			subrole, _ := ax_string(w, "AXSubrole")
			standard := subrole == "AXStandardWindow"
			delete(subrole)
			if !standard do continue

			title, _ := ax_string(w, "AXTitle")
			pos, _ := ax_point(w, "AXPosition")
			sz, _ := ax_size(w, "AXSize")
			append(&out, Std_Window{
				pid   = pid,
				ax    = AXUIElement(CFRetain(CF.TypeRef(w))),
				title = title,
				app   = strings.clone(owner),
				frame = CF.CGRect{pos, sz},
			})
		}
	}
	return out
}
