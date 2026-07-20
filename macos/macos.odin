// Package macos: thin Odin bindings over the macOS C APIs this window manager
// needs (Accessibility / ApplicationServices, CoreFoundation collection access,
// and CoreGraphics window/display enumeration), plus a small set of
// Odin-friendly helper wrappers.
//
// We reuse the types that ship with Odin in core:sys/darwin/CoreFoundation
// (TypeRef, String, CGPoint/CGSize/CGRect, StringCopyToOdinString) and
// core:sys/darwin/CoreGraphics (display list), and only hand-bind the symbols
// those packages don't already expose.
package macos

import "core:c"
import "core:sync"
import CF "core:sys/darwin/CoreFoundation"

foreign import cf "system:CoreFoundation.framework"
foreign import ax "system:ApplicationServices.framework"
foreign import cg "system:CoreGraphics.framework"

// ---------------------------------------------------------------------------
// CoreFoundation: collection + string + number access not bound by core.
// ---------------------------------------------------------------------------

CFNumberType :: enum c.int {
	SInt32 = 3,
	SInt64 = 4,
	Float64 = 6,
}

@(default_calling_convention = "c")
foreign cf {
	CFRetain               :: proc(obj: CF.TypeRef) -> CF.TypeRef ---
	CFEqual                :: proc(a: CF.TypeRef, b: CF.TypeRef) -> b8 ---
	CFArrayGetCount        :: proc(arr: CF.TypeRef) -> CF.Index ---
	CFArrayGetValueAtIndex :: proc(arr: CF.TypeRef, idx: CF.Index) -> rawptr ---
	CFDictionaryGetValue   :: proc(dict: CF.TypeRef, key: rawptr) -> rawptr ---
	CFNumberGetValue       :: proc(num: CF.TypeRef, theType: CFNumberType, valuePtr: rawptr) -> b8 ---
	CFStringCreateWithCString :: proc(alloc: rawptr, cStr: cstring, encoding: CF.StringEncoding) -> CF.String ---
}

// ---------------------------------------------------------------------------
// Accessibility (ApplicationServices / HIServices).
// ---------------------------------------------------------------------------

AXUIElement :: distinct rawptr
AXValue     :: distinct rawptr
AXObserver  :: distinct rawptr

AXError :: enum c.int {
	Success              = 0,
	Failure              = -25200,
	IllegalArgument      = -25201,
	InvalidUIElement     = -25202,
	InvalidObserver      = -25203,
	CannotComplete       = -25204,
	AttributeUnsupported = -25205,
	ActionUnsupported    = -25206,
	NotificationUnsupported = -25207,
	NotImplemented       = -25208,
	NotificationAlreadyRegistered = -25209,
	NotificationNotRegistered = -25210,
	APIDisabled          = -25211,
	NoValue              = -25212,
	ParameterizedAttributeUnsupported = -25213,
	NotEnoughPrecision   = -25214,
}

// Stable integer tags for AXValueRef payloads (unchanged across SDK versions).
AXValueType :: enum c.uint32_t {
	Illegal = 0,
	CGPoint = 1,
	CGSize  = 2,
	CGRect  = 3,
	CFRange = 4,
	AXError = 5,
}

@(default_calling_convention = "c")
foreign ax {
	AXIsProcessTrusted            :: proc() -> b8 ---
	AXUIElementCreateApplication  :: proc(pid: c.int) -> AXUIElement ---
	AXUIElementCreateSystemWide   :: proc() -> AXUIElement ---
	AXUIElementCopyAttributeValue :: proc(element: AXUIElement, attribute: CF.String, value: ^CF.TypeRef) -> AXError ---
	AXUIElementSetAttributeValue  :: proc(element: AXUIElement, attribute: CF.String, value: CF.TypeRef) -> AXError ---
	AXUIElementIsAttributeSettable :: proc(element: AXUIElement, attribute: CF.String, settable: ^b8) -> AXError ---
	AXUIElementPerformAction      :: proc(element: AXUIElement, action: CF.String) -> AXError ---
	AXValueGetValue               :: proc(value: AXValue, theType: AXValueType, valuePtr: rawptr) -> b8 ---
	AXValueCreate                 :: proc(theType: AXValueType, valuePtr: rawptr) -> AXValue ---
	AXUIElementSetMessagingTimeout :: proc(element: AXUIElement, timeoutInSeconds: f32) -> AXError ---
	AXUIElementGetPid             :: proc(element: AXUIElement, pid: ^c.int) -> AXError ---
	// Private but stable for ~15 years (used by yabai et al.): the CGWindowID
	// behind an AX window element — the one-call way to identify a window for
	// ScreenCaptureKit. Falls back to NoValue if the element isn't a window.
	_AXUIElementGetWindow         :: proc(element: AXUIElement, out: ^u32) -> AXError ---
}

// ---------------------------------------------------------------------------
// CoreGraphics: window list + display bounds (display list itself is in
// core:sys/darwin/CoreGraphics).
// ---------------------------------------------------------------------------

// Option bits for CGWindowListCopyWindowInfo.
CGWindowListOption :: enum c.uint32_t {
	All                    = 0,
	OnScreenOnly           = 1,  // 1 << 0
	ExcludeDesktopElements = 16, // 1 << 4
}

@(default_calling_convention = "c")
foreign cg {
	CGWindowListCopyWindowInfo :: proc(option: c.uint32_t, relativeToWindow: c.uint32_t) -> CF.TypeRef ---
	CGRectMakeWithDictionaryRepresentation :: proc(dict: CF.TypeRef, rect: ^CF.CGRect) -> b8 ---
	CGMainDisplayID :: proc() -> c.uint32_t ---
	CGDisplayBounds :: proc(display: c.uint32_t) -> CF.CGRect ---
	CGGetActiveDisplayList :: proc(maxDisplays: c.uint32_t, activeDisplays: [^]c.uint32_t, displayCount: ^c.uint32_t) -> c.int ---
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

// Create an interned-ish CFString from a C string. Caller owns it (CF.Release).
cf_str :: proc(s: cstring) -> CF.String {
	return CFStringCreateWithCString(nil, s, CF.StringEncoding(CF.StringBuiltInEncodings.UTF8))
}

// CFDictionaryGetValue keyed by a C-string. Returns a borrowed value (do not release).
dict_get_raw :: proc(dict: rawptr, key: cstring) -> rawptr {
	k := cf_str(key)
	defer CF.Release(CF.TypeRef(k))
	return CFDictionaryGetValue(CF.TypeRef(dict), rawptr(k))
}

dict_number_i32 :: proc(dict: rawptr, key: cstring) -> (i32, bool) {
	v := dict_get_raw(dict, key)
	if v == nil do return 0, false
	out: i32
	ok := CFNumberGetValue(CF.TypeRef(v), .SInt32, &out)
	return out, bool(ok)
}

// Returns a newly-allocated Odin string (caller frees) or ("", false) if absent.
dict_string :: proc(dict: rawptr, key: cstring, allocator := context.allocator) -> (string, bool) {
	v := dict_get_raw(dict, key)
	if v == nil do return "", false
	return CF.StringCopyToOdinString(CF.String(v), allocator)
}

dict_bounds :: proc(dict: rawptr, key: cstring) -> (CF.CGRect, bool) {
	v := dict_get_raw(dict, key)
	if v == nil do return {}, false
	r: CF.CGRect
	ok := CGRectMakeWithDictionaryRepresentation(CF.TypeRef(v), &r)
	return r, bool(ok)
}

// Our run loop hosts the event tap that every keystroke on the system passes
// through, so no synchronous AX call may block it for long. macOS's default
// messaging timeout is 6 seconds; even one app with a slow AX server (measured:
// Godot answers AXWindows in ~255ms while every normal app answers in <25ms)
// multiplied by our per-window attribute reads saturates the loop and the whole
// machine's input stutters. Three layers of defence:
//   1. a short per-element messaging timeout on every element we talk to,
//   2. duration-based backoff: any call slower than AX_SLOW_CALL_SECS puts its
//      pid in a cooldown — a slow *success* is as damaging as a timeout,
//   3. hot paths check ax_pid_slow before (and between) AX calls.
AX_CALL_TIMEOUT     :: f32(0.1) // per-element cap on one synchronous AX call (main thread)
AX_PATIENT_TIMEOUT  :: f32(1.0) // cap for the slow lane / one-off user actions
AX_SLOW_CALL_SECS   :: 0.05     // calls slower than this flag the app as slow
AX_BACKOFF_SECS     :: 15.0     // how long a flagged app's AX traffic stays off

// Cap the process-global AX timeout too (belt and braces — in practice the
// per-element timeouts below are what actually bound our calls).
ax_set_global_timeout :: proc(seconds: f32) {
	sys := AXUIElementCreateSystemWide()
	defer CF.Release(CF.TypeRef(sys))
	AXUIElementSetMessagingTimeout(sys, seconds)
}

// Create an app's AX element with the per-element messaging timeout applied.
// All app-element lookups must come through here, never bare
// AXUIElementCreateApplication, or the 6s default timeout is back.
ax_app :: proc(pid: i32) -> AXUIElement {
	el := AXUIElementCreateApplication(c.int(pid))
	AXUIElementSetMessagingTimeout(el, AX_CALL_TIMEOUT)
	return el
}

// Same, with the patient timeout: for the slow lane (off the main thread) and
// for one-off user-initiated actions where a sub-second block is acceptable.
ax_app_patient :: proc(pid: i32) -> AXUIElement {
	el := AXUIElementCreateApplication(c.int(pid))
	AXUIElementSetMessagingTimeout(el, AX_PATIENT_TIMEOUT)
	return el
}

// Apps whose AX server was recently slow: pid -> when it may be probed again.
// Mutex-guarded: the daemon's slow-lane thread marks pids while the main
// thread checks them.
@(private)
ax_slow_until: map[i32]CFAbsoluteTime
@(private)
ax_slow_mu: sync.Mutex

// Suspend AX traffic to a pid whose AX server timed out or answered slowly.
ax_mark_slow :: proc(pid: i32) {
	sync.mutex_lock(&ax_slow_mu)
	defer sync.mutex_unlock(&ax_slow_mu)
	if ax_slow_until == nil do ax_slow_until = make(map[i32]CFAbsoluteTime)
	ax_slow_until[pid] = CFAbsoluteTimeGetCurrent() + AX_BACKOFF_SECS
}

// Whether AX traffic to this pid is currently suspended (expired entries clear).
ax_pid_slow :: proc(pid: i32) -> bool {
	sync.mutex_lock(&ax_slow_mu)
	defer sync.mutex_unlock(&ax_slow_mu)
	until, backed_off := ax_slow_until[pid]
	if !backed_off do return false
	if CFAbsoluteTimeGetCurrent() >= until {
		delete_key(&ax_slow_until, pid)
		return false
	}
	return true
}

// Copy an AX attribute as a raw CF object, reporting the AXError so callers can
// tell a timeout (.CannotComplete — the app's AX server didn't answer) from a
// plain miss. Also the central slow-call detector: any call that took longer
// than AX_SLOW_CALL_SECS puts its app in backoff, whatever the outcome.
// Caller releases the value on .Success.
ax_get_err :: proc(el: AXUIElement, attr: cstring) -> (CF.TypeRef, AXError) {
	a := cf_str(attr)
	defer CF.Release(CF.TypeRef(a))
	val: CF.TypeRef
	t0 := CFAbsoluteTimeGetCurrent()
	err := AXUIElementCopyAttributeValue(el, a, &val)
	if CFAbsoluteTimeGetCurrent() - t0 > AX_SLOW_CALL_SECS {
		pid: c.int
		if AXUIElementGetPid(el, &pid) == .Success do ax_mark_slow(i32(pid))
	}
	if err == .Success && val == nil do err = .NoValue
	return val, err
}

// Copy an AX attribute as a raw CF object. Caller releases on success.
ax_get :: proc(el: AXUIElement, attr: cstring) -> (CF.TypeRef, bool) {
	val, err := ax_get_err(el, attr)
	return val, err == .Success
}

// Read a string-valued AX attribute (e.g. AXRole, AXSubrole). Caller frees the string.
ax_string :: proc(el: AXUIElement, attr: cstring, allocator := context.allocator) -> (string, bool) {
	val, ok := ax_get(el, attr)
	if !ok do return "", false
	defer CF.Release(val)
	return CF.StringCopyToOdinString(CF.String(val), allocator)
}

// A window's title. Caller frees the string.
ax_title :: proc(el: AXUIElement, allocator := context.allocator) -> (string, bool) {
	return ax_string(el, "AXTitle", allocator)
}

// A window's top-left position (global CG coordinates).
//
// Note: AXValueGetValue must be called *before* building the return tuple.
// `return p, bool(AXValueGetValue(..., &p))` would copy `p` (still zero) for the
// first result before the call mutates it — an evaluation-order trap.
ax_position :: proc(el: AXUIElement) -> (CF.CGPoint, bool) {
	val, ok := ax_get(el, "AXPosition")
	if !ok do return {}, false
	defer CF.Release(val)
	p: CF.CGPoint
	got := bool(AXValueGetValue(AXValue(val), .CGPoint, &p))
	return p, got
}

// A window's size.
ax_size :: proc(el: AXUIElement) -> (CF.CGSize, bool) {
	val, ok := ax_get(el, "AXSize")
	if !ok do return {}, false
	defer CF.Release(val)
	s: CF.CGSize
	got := bool(AXValueGetValue(AXValue(val), .CGSize, &s))
	return s, got
}

// Move a window (write AXPosition).
ax_set_position :: proc(el: AXUIElement, point: CF.CGPoint) -> AXError {
	p := point
	v := AXValueCreate(.CGPoint, &p)
	if v == nil do return .Failure
	defer CF.Release(CF.TypeRef(v))
	a := cf_str("AXPosition")
	defer CF.Release(CF.TypeRef(a))
	return AXUIElementSetAttributeValue(el, a, CF.TypeRef(v))
}

// Resize a window (write AXSize).
ax_set_size :: proc(el: AXUIElement, size: CF.CGSize) -> AXError {
	s := size
	v := AXValueCreate(.CGSize, &s)
	if v == nil do return .Failure
	defer CF.Release(CF.TypeRef(v))
	a := cf_str("AXSize")
	defer CF.Release(CF.TypeRef(a))
	return AXUIElementSetAttributeValue(el, a, CF.TypeRef(v))
}

// Perform an AX action.
ax_perform :: proc(el: AXUIElement, action: cstring) -> AXError {
	a := cf_str(action)
	defer CF.Release(CF.TypeRef(a))
	return AXUIElementPerformAction(el, a)
}

// Bring a window to the front of its app's z-order (does not focus its app).
ax_raise :: proc(el: AXUIElement) -> AXError {
	return ax_perform(el, "AXRaise")
}

// Whether an attribute can be written (e.g. AXSize on a resizable window). Used
// to tell tileable windows from fixed-size alerts/notification popups.
ax_settable :: proc(el: AXUIElement, attr: cstring) -> bool {
	a := cf_str(attr)
	defer CF.Release(CF.TypeRef(a))
	settable: b8
	if AXUIElementIsAttributeSettable(el, a, &settable) != .Success do return false
	return bool(settable)
}

// Set a window's frame, choosing the AX write order to avoid macOS clamping the
// *size* to fit between the window's current position and the screen edge.
//
// When the window is growing, move it to the target position first, then resize
// (so the bigger size fits at the new spot). Otherwise resize first, then move
// (so moving mostly off-screen doesn't get its size clamped). This mirrors
// Hiro/OmniWM's frameWriteOrder and replaces the old position->size->position
// triple-set, which clamped windows parked near a screen edge.
// `size_first` forces resize-then-move regardless of the grow heuristic. Use it
// when parking a window mostly off-screen: the window must reach full size while
// still on-screen, then be moved off (moving off clamps to a thin sliver). The
// default grow heuristic would otherwise move the small window off first, where
// growing it drags it back on-screen.
set_frame :: proc(w: AXUIElement, rect: CF.CGRect, size_first := false) {
	cur, _ := ax_size(w)
	grow := f64(rect.size.width) > f64(cur.width) + 0.5 || f64(rect.size.height) > f64(cur.height) + 0.5
	if grow && !size_first {
		ax_set_position(w, rect.origin)
		ax_set_size(w, rect.size)
	} else {
		ax_set_size(w, rect.size)
		ax_set_position(w, rect.origin)
	}
}

// Return the first AX window of an application, retained so it stays valid after
// the owning AXWindows array is released. Caller releases with CF.Release.
first_window :: proc(pid: i32) -> (AXUIElement, bool) {
	appel := ax_app(pid)
	defer CF.Release(CF.TypeRef(appel))

	wins, werr := ax_get_err(appel, "AXWindows")
	if werr == .CannotComplete {
		ax_mark_slow(pid)
		return nil, false
	}
	if werr != .Success do return nil, false
	defer CF.Release(wins)

	if CFArrayGetCount(wins) == 0 do return nil, false
	raw := CFArrayGetValueAtIndex(wins, 0)
	return AXUIElement(CFRetain(CF.TypeRef(raw))), true
}

// Frame of a CGWindowID straight from the window server — no AX round-trip,
// so it's safe to call for windows of AX-slow apps (the focus ring uses this
// when the focused window's app is in backoff). Same global coordinate space
// as AXPosition.
window_bounds :: proc(win_id: u32) -> (CF.CGRect, bool) {
	if win_id == 0 do return {}, false
	opts := u32(CGWindowListOption.OnScreenOnly) | u32(CGWindowListOption.ExcludeDesktopElements)
	arr := CGWindowListCopyWindowInfo(opts, 0)
	if arr == nil do return {}, false
	defer CF.Release(arr)

	n := CFArrayGetCount(arr)
	for i in 0 ..< n {
		d := CFArrayGetValueAtIndex(arr, i)
		num, _ := dict_number_i32(d, "kCGWindowNumber")
		if u32(num) != win_id do continue
		return dict_bounds(d, "kCGWindowBounds")
	}
	return {}, false
}

// Find the pid of the application owning the first normal (layer 0) on-screen
// window whose owner name matches `app_name`.
find_app_pid :: proc(app_name: string) -> (i32, bool) {
	opts := u32(CGWindowListOption.OnScreenOnly) | u32(CGWindowListOption.ExcludeDesktopElements)
	arr := CGWindowListCopyWindowInfo(opts, 0)
	if arr == nil do return 0, false
	defer CF.Release(arr)

	n := CFArrayGetCount(arr)
	for i in 0 ..< n {
		d := CFArrayGetValueAtIndex(arr, i)
		layer, _ := dict_number_i32(d, "kCGWindowLayer")
		if layer != 0 do continue
		name, has := dict_string(d, "kCGWindowOwnerName")
		if !has do continue
		match := name == app_name
		delete(name)
		if match {
			pid, _ := dict_number_i32(d, "kCGWindowOwnerPID")
			return pid, true
		}
	}
	return 0, false
}
