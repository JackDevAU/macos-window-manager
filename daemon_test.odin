package main

import "core:testing"
import "layout"

// Tests for the daemon's pure tick decisions.

// --- reconcile: when is an absent window really closed? ----------------------

// The last two args are (ax_alive, ax_decided). The pre-AX tests below exercise
// the fallback path (ax couldn't decide → false, false); the AX-authority tests
// that follow drive ax_decided=true.

@(test)
test_absent_visible_window_is_closed :: proc(t: ^testing.T) {
	testing.expect(t, absent_window_closed(.None, true, false, false, false, false, false, false))
}

@(test)
test_absent_parked_window_is_closed :: proc(t: ^testing.T) {
	// A parked window keeps a 6px on-screen peek, so it stays enumerable:
	// absence means the user closed it. (Was the lingering-bar-item bug —
	// closed hidden windows stuck around until next un-hidden.)
	testing.expect(t, absent_window_closed(.Parked, true, false, false, false, false, false, false))
}

@(test)
test_absent_minimized_window_is_not_forgotten :: proc(t: ^testing.T) {
	// A minimized window's app may have nothing on screen left to be
	// enumerated through — absence proves nothing while the app is alive.
	testing.expect(t, !absent_window_closed(.Minimized, true, false, false, false, false, false, false))
	testing.expect(t, !absent_window_closed(.Minimized, true, true, true, false, false, false, false))
}

@(test)
test_absent_window_of_dead_app_is_closed :: proc(t: ^testing.T) {
	// A dead pid overrides everything: the app is gone, so is its window.
	testing.expect(t, absent_window_closed(.Minimized, false, false, false, false, false, false, false))
	testing.expect(t, absent_window_closed(.Parked, false, true, false, false, true, false, false))
}

@(test)
test_absent_slow_app_window_needs_slow_batch_proof :: proc(t: ^testing.T) {
	// Fast lane skips a slow pid, so absence proves nothing…
	testing.expect(t, !absent_window_closed(.None, true, true, false, false, false, false, false))
	testing.expect(t, !absent_window_closed(.Parked, true, true, false, false, false, false, false))
	// …unless this tick's slow-lane batch actually covered that pid.
	testing.expect(t, absent_window_closed(.None, true, true, true, false, false, false, false))
	testing.expect(t, absent_window_closed(.Parked, true, true, true, false, false, false, false))
}

@(test)
test_absent_slow_app_window_on_another_space_is_kept :: proc(t: ^testing.T) {
	// The scattered-monitors bug, for a SLOW app the fast lane won't probe: the
	// on-screen enumeration is Space-local, so a fullscreen app / Space switch /
	// Cmd+H hides its windows from it at once. The window server's full list
	// still has them (cg_listed): not closed, must not be removed — the later
	// mass re-adoption is what teleported them onto the focused monitor.
	testing.expect(t, !absent_window_closed(.None, true, true, false, true, true, false, false))
	testing.expect(t, !absent_window_closed(.Parked, true, true, false, true, true, false, false))
	testing.expect(t, !absent_window_closed(.Minimized, true, true, false, true, true, false, false))
}

@(test)
test_absent_slow_app_window_gone_from_full_list_is_closed :: proc(t: ^testing.T) {
	// AX-inconclusive fallback: with a known CGWindowID the full list decides —
	// gone from it means closed, present means keep.
	testing.expect(t, absent_window_closed(.Minimized, true, true, false, true, false, false, false))
	testing.expect(t, absent_window_closed(.Parked, true, true, false, true, false, false, false))
	testing.expect(t, absent_window_closed(.None, true, true, false, true, false, false, false))
}

@(test)
test_absent_window_ax_element_is_ground_truth :: proc(t: ^testing.T) {
	// When we can probe the window's own element, it overrides the (Space-local
	// or stale) window lists. A dead element = closed, even while its id lingers
	// in the full list (cg_listed) — the closed-parked-window bar-linger bug.
	testing.expect(t, absent_window_closed(.Parked, true, false, false, true, true, false, true))
	testing.expect(t, absent_window_closed(.None, true, false, false, true, true, false, true))
	testing.expect(t, absent_window_closed(.Minimized, true, false, false, false, false, false, true))
	// A live element = on another Space / hidden / minimized, never closed —
	// even if the full list hasn't caught up (cg_listed=false).
	testing.expect(t, !absent_window_closed(.None, true, false, false, true, false, true, true))
	testing.expect(t, !absent_window_closed(.Parked, true, false, false, false, false, true, true))
	testing.expect(t, !absent_window_closed(.Minimized, true, false, false, true, true, true, true))
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

// --- OS-focus follow (the tick that adopts external focus changes) -----------

@(test)
test_follow_ignores_unchanged_or_unmanaged :: proc(t: ^testing.T) {
	testing.expect_value(t, follow_action(0, 5, 5, true, 0, false, 0), Follow_Action.Ignore)
	testing.expect_value(t, follow_action(5, 5, 5, true, 0, false, 0), Follow_Action.Ignore)
}

@(test)
test_follow_records_frontmost_already_ours :: proc(t: ^testing.T) {
	testing.expect_value(t, follow_action(5, 3, 5, true, 0, false, 0), Follow_Action.Record)
}

@(test)
test_follow_needs_two_consecutive_ticks :: proc(t: ^testing.T) {
	// First sighting arms a candidate; only the second consecutive tick follows.
	testing.expect_value(t, follow_action(9, 5, 5, true, 0, false, 0), Follow_Action.Arm)
	testing.expect_value(t, follow_action(9, 5, 5, true, 0, false, 9), Follow_Action.Follow)
}

@(test)
test_follow_frontmost_blip_is_never_followed :: proc(t: ^testing.T) {
	// The Outlook bug: a slow-flagged app self-activates for one tick (reminder
	// popup) and the old code followed + raised it. One tick arms; frontmost
	// returning to the synced window must end there — focus never moves.
	testing.expect_value(t, follow_action(9, 5, 5, true, 0, false, 0), Follow_Action.Arm)
	testing.expect_value(t, follow_action(5, 5, 5, true, 0, false, 9), Follow_Action.Ignore)
	// A different window on the confirm tick re-arms instead of following.
	testing.expect_value(t, follow_action(8, 5, 5, true, 0, false, 9), Follow_Action.Arm)
}

@(test)
test_follow_stale_godot_raise_is_reasserted :: proc(t: ^testing.T) {
	// The Godot bug: moved past Godot, its in-flight slow raise lands ~1s later
	// and Godot pops frontmost. That's our own write, not the user — put focus
	// back on the window the user is actually on.
	testing.expect_value(t, follow_action(9, 5, 5, true, 9, true, 0), Follow_Action.Reassert)
	// Expired stale marker: the same sighting is a genuine switch (armed first).
	testing.expect_value(t, follow_action(9, 5, 5, true, 9, false, 0), Follow_Action.Arm)
}

@(test)
test_raise_superseded_late_only_for_unarrived_loose :: proc(t: ^testing.T) {
	testing.expect(t, raise_superseded_late(7, 8, true, false)) // slow write still in flight
	testing.expect(t, !raise_superseded_late(7, 8, true, true)) // already frontmost: it landed
	testing.expect(t, !raise_superseded_late(7, 8, false, false)) // fast queue supersedes in-queue
	testing.expect(t, !raise_superseded_late(7, 7, true, false)) // same target re-raised
	testing.expect(t, !raise_superseded_late(0, 8, true, false)) // nothing issued before
}

// --- post-click focus sync ----------------------------------------------------

@(test)
test_click_sync_waits_for_the_real_target :: proc(t: ^testing.T) {
	// Right after the click the pre-click window (5, our focus) is still
	// frontmost — that's not the target; nothing managed frontmost also waits.
	testing.expect_value(t, click_sync_action(5, 5, true, 0), Click_Sync_Action.Wait)
	testing.expect_value(t, click_sync_action(0, 5, true, 0), Click_Sync_Action.Wait)
}

@(test)
test_click_sync_needs_two_consecutive_ticks :: proc(t: ^testing.T) {
	testing.expect_value(t, click_sync_action(9, 5, true, 0), Click_Sync_Action.Arm)
	testing.expect_value(t, click_sync_action(9, 5, true, 9), Click_Sync_Action.Sync)
}

@(test)
test_click_sync_ignores_frontmost_blip :: proc(t: ^testing.T) {
	// Clicking inside the already-focused window leaves click-sync armed for
	// CLICK_SYNC_TICKS; an Outlook reminder self-activating for one tick in
	// that window must not be adopted as the click's target.
	testing.expect_value(t, click_sync_action(9, 5, true, 0), Click_Sync_Action.Arm)
	testing.expect_value(t, click_sync_action(5, 5, true, 9), Click_Sync_Action.Wait)
	// A different window on the confirm tick re-arms instead of syncing.
	testing.expect_value(t, click_sync_action(8, 5, true, 9), Click_Sync_Action.Arm)
}

// --- activation guard (suppress OS-focus follow while a raise is in flight) --

@(test)
test_activation_guard :: proc(t: ^testing.T) {
	testing.expect(t, !activation_guard_done(42, 1, 0.0, 2.0)) // still activating: keep suppressing
	testing.expect(t, activation_guard_done(42, 42, 0.0, 2.0)) // frontmost now: guard lifts
	testing.expect(t, activation_guard_done(42, 1, 2.0, 2.0)) // deadline hit: give up
}
