package layout

import "core:testing"

// --- helpers ---------------------------------------------------------------

// Find the placement for a window id.
find :: proc(ps: []Placement, id: Window_Id) -> (Placement, bool) {
	for p in ps do if p.id == id do return p, true
	return {}, false
}

// Column tile ids, for compact assertions.
col_ids :: proc(s: ^Strip, ci: int, allocator := context.allocator) -> []Window_Id {
	out := make([]Window_Id, len(s.columns[ci].tiles), allocator)
	for t, i in s.columns[ci].tiles do out[i] = t.id
	return out
}

// --- structure -------------------------------------------------------------

@(test)
test_add_inserts_right_of_focus :: proc(t: ^testing.T) {
	s := make_strip()
	defer strip_destroy(&s)

	add_window(&s, 1)
	add_window(&s, 2)
	add_window(&s, 3)

	testing.expect_value(t, len(s.columns), 3)
	testing.expect_value(t, s.focused_col, 2)
	testing.expect_value(t, s.columns[0].tiles[0].id, Window_Id(1))
	testing.expect_value(t, s.columns[1].tiles[0].id, Window_Id(2))
	testing.expect_value(t, s.columns[2].tiles[0].id, Window_Id(3))

	// Focusing the middle and adding inserts between, without resizing others.
	focus_left(&s)
	add_window(&s, 4)
	testing.expect_value(t, len(s.columns), 4)
	testing.expect_value(t, s.focused_col, 2)
	testing.expect_value(t, s.columns[2].tiles[0].id, Window_Id(4))
}

@(test)
test_append_window_goes_to_far_right :: proc(t: ^testing.T) {
	s := make_strip()
	defer strip_destroy(&s)
	add_window(&s, 1)
	add_window(&s, 2)
	add_window(&s, 3) // [1,2,3]
	focus_left(&s);focus_left(&s) // focus the leftmost column

	append_window(&s, 9) // must land at the far right regardless of focus
	testing.expect_value(t, len(s.columns), 4)
	testing.expect_value(t, s.columns[3].tiles[0].id, Window_Id(9))
	testing.expect_value(t, s.focused_col, 3)
}

@(test)
test_regroup_into_docks_and_collapses :: proc(t: ^testing.T) {
	s := make_strip()
	defer strip_destroy(&s)
	add_window(&s, 1)
	add_window(&s, 2)
	add_window(&s, 3) // [1] [2] [3], each its own column

	// Dock the far-right window (3) into column 0 (alongside 1).
	ok := regroup_into(&s, 3, 0)
	testing.expect(t, ok)
	testing.expect_value(t, len(s.columns), 2) // 3's column collapsed
	testing.expect_value(t, len(s.columns[0].tiles), 2)
	testing.expect_value(t, s.columns[0].tiles[0].id, Window_Id(1))
	testing.expect_value(t, s.columns[0].tiles[1].id, Window_Id(3))
	testing.expect_value(t, s.focused_col, 0)
	testing.expect_value(t, s.columns[0].focused_tile, 1) // the moved tile is focused

	// No-op cases: unknown id, and already-in-dst.
	testing.expect(t, !regroup_into(&s, 999, 0))
	testing.expect(t, !regroup_into(&s, 1, 0))
}

@(test)
test_regroup_into_adjusts_dst_when_source_left_collapses :: proc(t: ^testing.T) {
	s := make_strip()
	defer strip_destroy(&s)
	add_window(&s, 1)
	add_window(&s, 2)
	add_window(&s, 3) // [1] [2] [3]

	// Move 1 (a column left of dst=2) into column 2. Column 0 collapses, so the
	// target shifts left to index 1; window 3 must end up holding both tiles.
	ok := regroup_into(&s, 1, 2)
	testing.expect(t, ok)
	testing.expect_value(t, len(s.columns), 2) // was [1][2][3] -> [2][3+1]
	testing.expect_value(t, s.columns[0].tiles[0].id, Window_Id(2))
	testing.expect_value(t, len(s.columns[1].tiles), 2)
	testing.expect_value(t, s.columns[1].tiles[0].id, Window_Id(3))
	testing.expect_value(t, s.columns[1].tiles[1].id, Window_Id(1))
	testing.expect_value(t, s.focused_col, 1)
}

@(test)
test_focus_bounds :: proc(t: ^testing.T) {
	s := make_strip()
	defer strip_destroy(&s)
	add_window(&s, 1)
	add_window(&s, 2)

	focus_left(&s);focus_left(&s) // clamp at 0
	testing.expect_value(t, s.focused_col, 0)
	focus_right(&s);focus_right(&s) // clamp at last
	testing.expect_value(t, s.focused_col, 1)
}

@(test)
test_focus_next_prev_wraps :: proc(t: ^testing.T) {
	s := make_strip()
	defer strip_destroy(&s)
	add_window(&s, 1)
	add_window(&s, 2)
	add_window(&s, 3) // focus col2

	focus_next(&s) // 2 -> wraps to 0
	testing.expect_value(t, s.focused_col, 0)
	focus_next(&s) // 0 -> 1
	testing.expect_value(t, s.focused_col, 1)
	focus_prev(&s) // 1 -> 0
	testing.expect_value(t, s.focused_col, 0)
	focus_prev(&s) // 0 -> wraps to 2
	testing.expect_value(t, s.focused_col, 2)
}

@(test)
test_remove_collapses_column_and_fixes_focus :: proc(t: ^testing.T) {
	s := make_strip()
	defer strip_destroy(&s)
	add_window(&s, 1)
	add_window(&s, 2)
	add_window(&s, 3) // focus on col 2

	remove_window(&s, 3)
	testing.expect_value(t, len(s.columns), 2)
	testing.expect_value(t, s.focused_col, 1) // clamped back

	// Removing a column left of focus shifts focus index down to track it.
	add_window(&s, 4) // [1,2,4] focus 2
	remove_window(&s, 1) // removes col 0
	testing.expect_value(t, len(s.columns), 2)
	testing.expect_value(t, s.focused_col, 1)
	testing.expect_value(t, s.columns[0].tiles[0].id, Window_Id(2))
}

@(test)
test_move_column :: proc(t: ^testing.T) {
	s := make_strip()
	defer strip_destroy(&s)
	add_window(&s, 1)
	add_window(&s, 2)
	add_window(&s, 3) // focus col 2 (id 3)

	move_column_left(&s)
	testing.expect_value(t, s.focused_col, 1)
	testing.expect_value(t, s.columns[1].tiles[0].id, Window_Id(3))
	testing.expect_value(t, s.columns[2].tiles[0].id, Window_Id(2))
}

@(test)
test_cycle_width :: proc(t: ^testing.T) {
	s := make_strip()
	defer strip_destroy(&s)
	add_window(&s, 1, 0.5)

	cycle_width(&s) // 1/2 -> 2/3
	testing.expect(t, near(s.columns[0].width_frac, 2.0 / 3.0))
	cycle_width(&s) // 2/3 -> 1/3
	testing.expect(t, near(s.columns[0].width_frac, 1.0 / 3.0))
	cycle_width(&s) // 1/3 -> 1/2
	testing.expect(t, near(s.columns[0].width_frac, 1.0 / 2.0))
}

@(test)
test_consume_and_expel :: proc(t: ^testing.T) {
	s := make_strip()
	defer strip_destroy(&s)
	add_window(&s, 1)
	add_window(&s, 2) // [1][2], focus col1
	focus_left(&s) // focus col0

	consume_into_column(&s) // pull id2 into col0
	testing.expect_value(t, len(s.columns), 1)
	ids := col_ids(&s, 0)
	defer delete(ids)
	testing.expect_value(t, len(ids), 2)
	testing.expect_value(t, ids[0], Window_Id(1))
	testing.expect_value(t, ids[1], Window_Id(2))
	testing.expect_value(t, s.focused_col, 0)

	expel_from_column(&s) // push focused tile (id2) back out to the right
	testing.expect_value(t, len(s.columns), 2)
	testing.expect_value(t, s.columns[0].tiles[0].id, Window_Id(1))
	testing.expect_value(t, s.columns[1].tiles[0].id, Window_Id(2))
	testing.expect_value(t, s.focused_col, 1)
}

// --- layout ----------------------------------------------------------------

VP :: Rect{0, 0, 1000, 1000}

@(test)
test_layout_two_columns_side_by_side :: proc(t: ^testing.T) {
	s := make_strip(0)
	defer strip_destroy(&s)
	add_window(&s, 1, 0.5)
	add_window(&s, 2, 0.5)

	ps := compute_layout(&s, VP)
	defer delete(ps)

	testing.expect_value(t, len(ps), 2)
	p1, _ := find(ps, 1)
	p2, _ := find(ps, 2)
	testing.expect_value(t, p1.rect, Rect{0, 0, 500, 1000})
	testing.expect_value(t, p2.rect, Rect{500, 0, 500, 1000})
	testing.expect(t, p1.visible && p2.visible)
}

@(test)
test_layout_scrolls_and_hides_offscreen :: proc(t: ^testing.T) {
	s := make_strip(0)
	defer strip_destroy(&s)
	add_window(&s, 1, 0.5)
	add_window(&s, 2, 0.5)
	add_window(&s, 3, 0.5) // focus col2 at strip x=1000, off the right edge

	ps := compute_layout(&s, VP)
	defer delete(ps)

	// View settled to view_x=500: col0 scrolls off-left (hidden),
	// col1 to x=0, col2 (focused) to x=500.
	testing.expect(t, near(s.view_x, 500))
	p1, _ := find(ps, 1)
	p2, _ := find(ps, 2)
	p3, _ := find(ps, 3)
	testing.expect(t, !p1.visible) // scrolled out
	testing.expect(t, p2.visible && p3.visible)
	testing.expect_value(t, p2.rect.x, 0)
	testing.expect_value(t, p3.rect.x, 500)
}

@(test)
test_layout_hide_side :: proc(t: ^testing.T) {
	s := make_strip(0)
	defer strip_destroy(&s)
	for id in 1 ..= 5 do add_window(&s, Window_Id(id), 0.5)
	focus_left(&s);focus_left(&s) // focus the middle column (id 3)

	ps := compute_layout(&s, VP)
	defer delete(ps)

	p1, _ := find(ps, 1)
	p3, _ := find(ps, 3)
	p4, _ := find(ps, 4)
	p5, _ := find(ps, 5)
	testing.expect_value(t, p1.side, Hide_Side.Left) // scrolled off the left
	testing.expect(t, p3.visible) // focused, on screen
	testing.expect_value(t, p3.side, Hide_Side.None)
	testing.expect_value(t, p4.side, Hide_Side.Right) // off the right
	testing.expect_value(t, p5.side, Hide_Side.Right)
}

@(test)
test_layout_stacked_tiles_split_height :: proc(t: ^testing.T) {
	s := make_strip(0)
	defer strip_destroy(&s)
	add_window(&s, 1, 1.0) // full-width column, focused
	add_tile(&s, 2) // stack into it

	ps := compute_layout(&s, VP)
	defer delete(ps)

	testing.expect_value(t, len(ps), 2)
	p1, _ := find(ps, 1)
	p2, _ := find(ps, 2)
	testing.expect_value(t, p1.rect, Rect{0, 0, 1000, 500})
	testing.expect_value(t, p2.rect, Rect{0, 500, 1000, 500})
}

@(test)
test_grid_layout :: proc(t: ^testing.T) {
	s := make_strip(0)
	defer strip_destroy(&s)
	for id in 1 ..= 4 do add_window(&s, Window_Id(id))

	ps := compute_grid(&s, VP) // 1000x1000, gap 0 -> 2x2 of 500x500
	defer delete(ps)

	testing.expect_value(t, len(ps), 4)
	for p in ps do testing.expect(t, p.visible)
	p1, _ := find(ps, 1)
	p4, _ := find(ps, 4)
	testing.expect_value(t, p1.rect, Rect{0, 0, 500, 500}) // top-left cell
	testing.expect_value(t, p4.rect, Rect{500, 500, 500, 500}) // bottom-right cell
}

@(test)
test_monocle_shows_only_focused_full_screen :: proc(t: ^testing.T) {
	s := make_strip(0)
	defer strip_destroy(&s)
	for id in 1 ..= 3 do add_window(&s, Window_Id(id), 0.5) // narrow columns...
	focus_left(&s) // ...focus the middle (id 2)

	ps := compute_monocle(&s, VP)
	defer delete(ps)

	p1, _ := find(ps, 1)
	p2, _ := find(ps, 2)
	p3, _ := find(ps, 3)
	// Only the focused column shows, filling the whole viewport regardless of
	// width_frac; the others are hidden off their respective sides.
	testing.expect(t, p2.visible)
	testing.expect_value(t, p2.rect, Rect{0, 0, 1000, 1000})
	testing.expect(t, !p1.visible && !p3.visible)
	testing.expect_value(t, p1.side, Hide_Side.Left)
	testing.expect_value(t, p3.side, Hide_Side.Right)
}

@(test)
test_layout_respects_gap :: proc(t: ^testing.T) {
	s := make_strip(10)
	defer strip_destroy(&s)
	add_window(&s, 1, 1.0) // 1.0 * (1000 - 2*10) = 980 wide

	ps := compute_layout(&s, VP)
	defer delete(ps)
	p1, _ := find(ps, 1)
	// Inset by the gap on all sides.
	testing.expect_value(t, p1.rect, Rect{10, 10, 980, 980})
}
