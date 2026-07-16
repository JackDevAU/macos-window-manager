// Run-loop plumbing for the daemon: CFRunLoop, a CGEventTap for global
// hotkeys, a CFFileDescriptor source for the IPC socket, and CFRunLoopTimer for
// periodic reconciliation. Plus CGEvent synthesis (for self-testing the tap).
package macos

import "core:c"
import CF "core:sys/darwin/CoreFoundation"

foreign import cfrl "system:CoreFoundation.framework"
foreign import cgrl "system:CoreGraphics.framework"

// --- opaque handles ---------------------------------------------------------

CFRunLoop       :: distinct rawptr
CFRunLoopSource :: distinct rawptr
CFRunLoopTimer  :: distinct rawptr
CFFileDescriptor :: distinct rawptr
CFMachPort      :: distinct rawptr
CGEvent         :: distinct rawptr
CGEventTapProxy :: distinct rawptr

CFAbsoluteTime  :: f64
CFTimeInterval  :: f64

// --- callback types ---------------------------------------------------------

CFFileDescriptorCallBack :: #type proc "c" (f: CFFileDescriptor, callBackTypes: u64, info: rawptr)
CFRunLoopTimerCallBack   :: #type proc "c" (timer: CFRunLoopTimer, info: rawptr)
CGEventTapCallBack       :: #type proc "c" (proxy: CGEventTapProxy, type: u32, event: CGEvent, userInfo: rawptr) -> CGEvent

CFFileDescriptorContext :: struct {
	version:         CF.Index,
	info:            rawptr,
	retain:          rawptr,
	release:         rawptr,
	copyDescription: rawptr,
}

// --- constants --------------------------------------------------------------

kCFFileDescriptorReadCallBack :: u64(1) // 1 << 0

// CGEventTap location / placement / options.
kCGHIDEventTap          :: u32(0)
kCGSessionEventTap      :: u32(1)
kCGHeadInsertEventTap   :: u32(0)
kCGEventTapOptionDefault :: u32(0)

// CGEventType.
kCGEventLeftMouseDown           :: u32(1)
kCGEventKeyDown                 :: u32(10)
kCGEventTapDisabledByTimeout    :: u32(0xFFFFFFFE)
kCGEventTapDisabledByUserInput  :: u32(0xFFFFFFFF)

// CGEventField.
kCGKeyboardEventKeycode :: u32(9)

// CGEventFlags (modifier masks).
FLAG_SHIFT   :: u64(0x00020000)
FLAG_CONTROL :: u64(0x00040000)
FLAG_ALT     :: u64(0x00080000)
FLAG_COMMAND :: u64(0x00100000)

// Event mask bit for a given CGEventType.
event_mask_bit :: proc(type: u32) -> u64 {
	return u64(1) << u64(type)
}

// --- bindings ---------------------------------------------------------------

@(default_calling_convention = "c")
foreign cfrl {
	kCFRunLoopDefaultMode: CF.String
	kCFRunLoopCommonModes: CF.String

	CFRunLoopGetCurrent :: proc() -> CFRunLoop ---
	CFRunLoopRun        :: proc() ---
	CFRunLoopStop       :: proc(rl: CFRunLoop) ---
	CFRunLoopAddSource  :: proc(rl: CFRunLoop, source: CFRunLoopSource, mode: CF.String) ---
	CFRunLoopAddTimer   :: proc(rl: CFRunLoop, timer: CFRunLoopTimer, mode: CF.String) ---

	CFAbsoluteTimeGetCurrent :: proc() -> CFAbsoluteTime ---
	CFRunLoopTimerCreate :: proc(alloc: rawptr, fireDate: CFAbsoluteTime, interval: CFTimeInterval, flags: u64, order: CF.Index, callout: CFRunLoopTimerCallBack, ctx: rawptr) -> CFRunLoopTimer ---

	CFFileDescriptorCreate              :: proc(alloc: rawptr, fd: c.int, closeOnInvalidate: b8, callout: CFFileDescriptorCallBack, ctx: ^CFFileDescriptorContext) -> CFFileDescriptor ---
	CFFileDescriptorEnableCallBacks     :: proc(f: CFFileDescriptor, callBackTypes: u64) ---
	CFFileDescriptorCreateRunLoopSource :: proc(alloc: rawptr, f: CFFileDescriptor, order: CF.Index) -> CFRunLoopSource ---

	CFMachPortCreateRunLoopSource :: proc(alloc: rawptr, port: CFMachPort, order: CF.Index) -> CFRunLoopSource ---
}

@(default_calling_convention = "c")
foreign cgrl {
	// Input Monitoring (ListenEvent) permission — required for a keyboard event
	// tap on macOS 10.15+, separate from Accessibility.
	CGPreflightListenEventAccess :: proc() -> b8 ---
	CGRequestListenEventAccess   :: proc() -> b8 ---

	CGEventTapCreate :: proc(tap: u32, place: u32, options: u32, eventsOfInterest: u64, callback: CGEventTapCallBack, userInfo: rawptr) -> CFMachPort ---
	CGEventTapEnable :: proc(tap: CFMachPort, enable: b8) ---
	CGEventGetIntegerValueField :: proc(event: CGEvent, field: u32) -> i64 ---
	CGEventGetFlags :: proc(event: CGEvent) -> u64 ---
	CGEventGetLocation :: proc(event: CGEvent) -> CF.CGPoint ---

	// Synthesis (for self-testing the tap).
	CGEventSourceCreate :: proc(stateID: u32) -> rawptr ---
	CGEventCreateKeyboardEvent :: proc(source: rawptr, keycode: u16, keyDown: b8) -> CGEvent ---
	CGEventSetFlags :: proc(event: CGEvent, flags: u64) ---
	CGEventPost :: proc(tap: u32, event: CGEvent) ---

	CGWarpMouseCursorPosition :: proc(newCursorPosition: CF.CGPoint) -> i32 ---
	CGAssociateMouseAndMouseCursorPosition :: proc(connected: b8) -> i32 ---
}

// Move the mouse cursor to (x, y) in global CG coordinates (top-left origin,
// same space as AXPosition). Works across displays. The re-associate call
// cancels the ~0.25s input freeze CGWarpMouseCursorPosition otherwise imposes.
warp_mouse :: proc(x, y: f64) {
	CGWarpMouseCursorPosition(CF.CGPoint{CF.CGFloat(x), CF.CGFloat(y)})
	CGAssociateMouseAndMouseCursorPosition(true)
}

// Synthesize a keyboard event with modifier flags and post it (used by the
// `synth-key` debug command to exercise the hotkey tap without real keypresses).
post_key :: proc(keycode: u16, flags: u64) {
	src := CGEventSourceCreate(1) // kCGEventSourceStateHIDSystemState
	down := CGEventCreateKeyboardEvent(src, keycode, true)
	if down != nil {
		CGEventSetFlags(down, flags)
		CGEventPost(kCGHIDEventTap, down)
		CF.Release(CF.TypeRef(down))
	}
	up := CGEventCreateKeyboardEvent(src, keycode, false)
	if up != nil {
		CGEventSetFlags(up, flags)
		CGEventPost(kCGHIDEventTap, up)
		CF.Release(CF.TypeRef(up))
	}
	if src != nil do CF.Release(CF.TypeRef(src))
}
