package main

import "core:testing"
import "layout"

// Tests for the daemon's pure tick decisions.

// --- reconcile: when is an absent window really closed? ----------------------

@(test)
test_absent_visible_window_is_closed :: proc(t: ^testing.T) {
	testing.expect(t, absent_window_closed(.None, true, false, false))
}

@(test)
test_absent_parked_window_is_closed :: proc(t: ^testing.T) {
	// A parked window keeps a 6px on-screen peek, so it stays enumerable:
	// absence means the user closed it. (Was the lingering-bar-item bug —
	// closed hidden windows stuck around until next un-hidden.)
	testing.expect(t, absent_window_closed(.Parked, true, false, false))
}

@(test)
test_absent_minimized_window_is_not_forgotten :: proc(t: ^testing.T) {
	// A minimized window's app may have nothing on screen left to be
	// enumerated through — absence proves nothing while the app is alive.
	testing.expect(t, !absent_window_closed(.Minimized, true, false, false))
	testing.expect(t, !absent_window_closed(.Minimized, true, true, true))
}

@(test)
test_absent_window_of_dead_app_is_closed :: proc(t: ^testing.T) {
	// A dead pid overrides everything: the app is gone, so is its window.
	testing.expect(t, absent_window_closed(.Minimized, false, false, false))
	testing.expect(t, absent_window_closed(.Parked, false, true, false))
}

@(test)
test_absent_slow_app_window_needs_slow_batch_proof :: proc(t: ^testing.T) {
	// Fast lane skips a slow pid, so absence proves nothing…
	testing.expect(t, !absent_window_closed(.None, true, true, false))
	testing.expect(t, !absent_window_closed(.Parked, true, true, false))
	// …unless this tick's slow-lane batch actually covered that pid.
	testing.expect(t, absent_window_closed(.None, true, true, true))
	testing.expect(t, absent_window_closed(.Parked, true, true, true))
}

// --- loose-window deferred raise (Godot: ~255ms per AX call) -----------------

@(test)
test_pending_raise_waits_out_the_dwell :: proc(t: ^testing.T) {
	id := layout.Window_Id(7)
	testing.expect_value(t, pending_raise_tick(id, id, true, 1.00, 1.18), Pending_Raise.Waiting)
	testing.expect_value(t, pending_raise_tick(id, id, true, 1.18, 1.18), Pending_Raise.Raise)
	testing.expect_value(t, pending_raise_tick(id, id, true, 9.99, 1.18), Pending_Raise.Raise)
}

@(test)
test_pending_raise_dropped_when_focus_moves_on :: proc(t: ^testing.T) {
	// Spam-navigating PAST a slow window must never activate it.
	testing.expect_value(t, pending_raise_tick(7, 8, true, 9.99, 1.18), Pending_Raise.Drop)
	testing.expect_value(t, pending_raise_tick(7, 0, false, 9.99, 1.18), Pending_Raise.Drop)
}

// --- off-view parking ---------------------------------------------------------

@(test)
test_open_park_sides_side_by_side :: proc(t: ^testing.T) {
	// Real-world pair: 1920x1080 left of a 1728x1117 (offset y, overlapping band).
	a := layout.Rect{0, 0, 1920, 1080}
	b := layout.Rect{1920, -37, 1728, 1117}
	al, ar := open_park_sides(a, []layout.Rect{b})
	testing.expect(t, al && !ar) // b blocks a's right edge
	bl, br := open_park_sides(b, []layout.Rect{a})
	testing.expect(t, !bl && br) // a blocks b's left edge
}

@(test)
test_open_park_sides_stacked_and_single :: proc(t: ^testing.T) {
	// Vertically stacked displays don't share a y-band: both sides are open.
	top := layout.Rect{0, 0, 1920, 1080}
	bot := layout.Rect{0, 1080, 1920, 1080}
	l, r := open_park_sides(top, []layout.Rect{bot})
	testing.expect(t, l && r)
	// A single monitor is open on both sides.
	l2, r2 := open_park_sides(top, nil)
	testing.expect(t, l2 && r2)
}

@(test)
test_park_rect_prefers_open_side_edge :: proc(t: ^testing.T) {
	vp := layout.Rect{0, 28, 1920, 1052}
	bounds := layout.Rect{0, 0, 1920, 1080}
	r := layout.Rect{12, 40, 948, 1028}

	// Off-right: EDGE_REVEAL px remain on-screen (so enumeration — and thus
	// close-detection for parked windows — keeps seeing it).
	right := park_rect(r, vp, bounds, false, true)
	testing.expect_value(t, right, layout.Rect{1920 - EDGE_REVEAL, 40, 948, 1028})
	// Right wins when both sides are open.
	testing.expect_value(t, park_rect(r, vp, bounds, true, true), right)

	// Off-left mirror.
	left := park_rect(r, vp, bounds, true, false)
	testing.expect_value(t, left, layout.Rect{-948 + EDGE_REVEAL, 40, 948, 1028})

	// Boxed in on both sides: bottom fallback (macOS will clamp the title bar
	// back into view — the peek we're avoiding wherever a side is open).
	bottom := park_rect(r, vp, bounds, false, false)
	testing.expect_value(t, bottom, layout.Rect{12, 28 + 1052 - EDGE_REVEAL, 948, 1028})
}

@(test)
test_park_rect_never_fully_offscreen :: proc(t: ^testing.T) {
	// Regression guard: a parked window must always keep EDGE_REVEAL px inside
	// its display bounds — fully off-screen drops it from the on-screen window
	// list, and reconcile would then remove it as closed.
	vp := layout.Rect{0, 28, 1920, 1052}
	bounds := layout.Rect{0, 0, 1920, 1080}
	r := layout.Rect{12, 40, 948, 1028}
	right := park_rect(r, vp, bounds, false, true)
	testing.expect_value(t, bounds.x + bounds.w - right.x, EDGE_REVEAL)
	left := park_rect(r, vp, bounds, true, false)
	testing.expect_value(t, left.x + left.w - bounds.x, EDGE_REVEAL)
	bottom := park_rect(r, vp, bounds, false, false)
	testing.expect(t, bottom.y < vp.y + vp.h)
}

// --- activation guard (suppress OS-focus follow while a raise is in flight) --

@(test)
test_activation_guard :: proc(t: ^testing.T) {
	testing.expect(t, !activation_guard_done(42, 1, 0.0, 2.0)) // still activating: keep suppressing
	testing.expect(t, activation_guard_done(42, 42, 0.0, 2.0)) // frontmost now: guard lifts
	testing.expect(t, activation_guard_done(42, 1, 2.0, 2.0)) // deadline hit: give up
}
