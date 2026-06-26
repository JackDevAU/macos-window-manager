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

// Copy an AX attribute as a raw CF object. Caller releases on success.
ax_get :: proc(el: AXUIElement, attr: cstring) -> (CF.TypeRef, bool) {
	a := cf_str(attr)
	defer CF.Release(CF.TypeRef(a))
	val: CF.TypeRef
	err := AXUIElementCopyAttributeValue(el, a, &val)
	return val, err == .Success && val != nil
}

// Read a string-valued AX attribute (e.g. AXTitle, AXRole). Caller frees the string.
ax_string :: proc(el: AXUIElement, attr: cstring, allocator := context.allocator) -> (string, bool) {
	val, ok := ax_get(el, attr)
	if !ok do return "", false
	defer CF.Release(val)
	return CF.StringCopyToOdinString(CF.String(val), allocator)
}

// Read an AXPosition-style attribute (an AXValue wrapping a CGPoint).
//
// Note: AXValueGetValue must be called *before* building the return tuple.
// `return p, bool(AXValueGetValue(..., &p))` would copy `p` (still zero) for the
// first result before the call mutates it — an evaluation-order trap.
ax_point :: proc(el: AXUIElement, attr: cstring) -> (CF.CGPoint, bool) {
	val, ok := ax_get(el, attr)
	if !ok do return {}, false
	defer CF.Release(val)
	p: CF.CGPoint
	got := bool(AXValueGetValue(AXValue(val), .CGPoint, &p))
	return p, got
}

// Read an AXSize-style attribute (an AXValue wrapping a CGSize).
ax_size :: proc(el: AXUIElement, attr: cstring) -> (CF.CGSize, bool) {
	val, ok := ax_get(el, attr)
	if !ok do return {}, false
	defer CF.Release(val)
	s: CF.CGSize
	got := bool(AXValueGetValue(AXValue(val), .CGSize, &s))
	return s, got
}

// Write a CGPoint-valued attribute (e.g. AXPosition).
ax_set_point :: proc(el: AXUIElement, attr: cstring, point: CF.CGPoint) -> AXError {
	p := point
	v := AXValueCreate(.CGPoint, &p)
	if v == nil do return .Failure
	defer CF.Release(CF.TypeRef(v))
	a := cf_str(attr)
	defer CF.Release(CF.TypeRef(a))
	return AXUIElementSetAttributeValue(el, a, CF.TypeRef(v))
}

// Write a CGSize-valued attribute (e.g. AXSize).
ax_set_size :: proc(el: AXUIElement, attr: cstring, size: CF.CGSize) -> AXError {
	s := size
	v := AXValueCreate(.CGSize, &s)
	if v == nil do return .Failure
	defer CF.Release(CF.TypeRef(v))
	a := cf_str(attr)
	defer CF.Release(CF.TypeRef(a))
	return AXUIElementSetAttributeValue(el, a, CF.TypeRef(v))
}

// Perform an AX action (e.g. AXRaise).
ax_perform :: proc(el: AXUIElement, action: cstring) -> AXError {
	a := cf_str(action)
	defer CF.Release(CF.TypeRef(a))
	return AXUIElementPerformAction(el, a)
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
	cur, _ := ax_size(w, "AXSize")
	grow := f64(rect.size.width) > f64(cur.width) + 0.5 || f64(rect.size.height) > f64(cur.height) + 0.5
	if grow && !size_first {
		ax_set_point(w, "AXPosition", rect.origin)
		ax_set_size(w, "AXSize", rect.size)
	} else {
		ax_set_size(w, "AXSize", rect.size)
		ax_set_point(w, "AXPosition", rect.origin)
	}
}

// Return the first AX window of an application, retained so it stays valid after
// the owning AXWindows array is released. Caller releases with CF.Release.
first_window :: proc(pid: i32) -> (AXUIElement, bool) {
	appel := AXUIElementCreateApplication(c.int(pid))
	defer CF.Release(CF.TypeRef(appel))

	wins, ok := ax_get(appel, "AXWindows")
	if !ok do return nil, false
	defer CF.Release(wins)

	if CFArrayGetCount(wins) == 0 do return nil, false
	raw := CFArrayGetValueAtIndex(wins, 0)
	return AXUIElement(CFRetain(CF.TypeRef(raw))), true
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
