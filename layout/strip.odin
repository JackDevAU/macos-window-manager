// The niri scrollable-tiling model, as pure data + operations.
//
// A Strip is an unbounded horizontal row of Columns. Each Column has a width
// (as a fraction of the usable viewport width) and a vertical stack of Tiles
// (windows). The Strip remembers which column/tile is focused and a horizontal
// scroll offset (`view_x`, in strip-local pixels).
//
// Opening a window never resizes the others — it inserts a new column to the
// right of the focus. Navigation scrolls the view the minimum amount needed to
// keep the focused column on screen. compute_layout() turns this logical model
// into concrete on-screen rectangles, flagging columns scrolled out of view as
// hidden (the macOS effector will minimize those, since windows can't be parked
// fully off-screen — see M2 findings).
package layout

// Opaque handle for a managed window (on macOS this maps to a CGWindowID or an
// AX element key; the engine doesn't care which).
Window_Id :: distinct u64

Tile :: struct {
	id: Window_Id,
}

Column :: struct {
	tiles:        [dynamic]Tile,
	focused_tile: int,
	width_frac:   f64, // fraction of the usable viewport width (e.g. 0.5)
	// Learned actual width (px) when the window won't grow to width_frac (e.g.
	// System Settings caps its width). 0 = honour width_frac. The effector sets
	// this so neighbouring columns pack against the real width, not the slot.
	// Cleared whenever width_frac changes, to re-probe at the new size.
	eff_w:        f64,
}

Strip :: struct {
	columns:     [dynamic]Column,
	focused_col: int,
	view_x:      f64, // left edge of the viewport in strip-local pixels
	gap:         f64, // gap between columns, between tiles, and around the edges
}

// niri-style width presets cycled by cycle_width.
@(rodata)
WIDTH_PRESETS := [3]f64{1.0 / 3.0, 1.0 / 2.0, 2.0 / 3.0}

DEFAULT_WIDTH :: 0.5

make_strip :: proc(gap: f64 = 0) -> Strip {
	return Strip{gap = gap}
}

strip_destroy :: proc(s: ^Strip) {
	for &col in s.columns {
		delete(col.tiles)
	}
	delete(s.columns)
}

// --- structural operations --------------------------------------------------

// Insert `id` as a new single-tile column to the right of the focus and focus it.
add_window :: proc(s: ^Strip, id: Window_Id, width_frac: f64 = DEFAULT_WIDTH) {
	col: Column
	col.width_frac = width_frac
	append(&col.tiles, Tile{id = id})

	if len(s.columns) == 0 {
		append(&s.columns, col)
		s.focused_col = 0
	} else {
		inject_at(&s.columns, s.focused_col + 1, col)
		s.focused_col += 1
	}
}

// Append `id` as a new single-tile column at the far right of the strip and
// focus it. (Newly-opened windows land here, regardless of where focus was.)
append_window :: proc(s: ^Strip, id: Window_Id, width_frac: f64 = DEFAULT_WIDTH) {
	col: Column
	col.width_frac = width_frac
	append(&col.tiles, Tile{id = id})
	append(&s.columns, col)
	s.focused_col = len(s.columns) - 1
}

// Stack `id` as a new tile at the bottom of the focused column and focus it.
add_tile :: proc(s: ^Strip, id: Window_Id) {
	if len(s.columns) == 0 {
		add_window(s, id)
		return
	}
	col := &s.columns[s.focused_col]
	append(&col.tiles, Tile{id = id})
	col.focused_tile = len(col.tiles) - 1
}

// Remove tile `ti` from column `ci`, collapsing the column if it empties and
// keeping the strip's focus indices valid. Returns whether the column collapsed
// (callers holding column indices right of `ci` must shift them down by one).
@(private = "file")
remove_tile_at :: proc(s: ^Strip, ci, ti: int) -> (collapsed: bool) {
	col := &s.columns[ci]
	ordered_remove(&col.tiles, ti)
	if len(col.tiles) == 0 {
		delete(col.tiles)
		ordered_remove(&s.columns, ci)
		if ci < s.focused_col do s.focused_col -= 1
		if s.focused_col >= len(s.columns) {
			s.focused_col = max(0, len(s.columns) - 1)
		}
		return true
	}
	if col.focused_tile >= len(col.tiles) {
		col.focused_tile = len(col.tiles) - 1
	}
	return false
}

// Remove the tile holding `id`, collapsing its column if it becomes empty.
remove_window :: proc(s: ^Strip, id: Window_Id) -> bool {
	for ci in 0 ..< len(s.columns) {
		for ti in 0 ..< len(s.columns[ci].tiles) {
			if s.columns[ci].tiles[ti].id != id do continue
			remove_tile_at(s, ci, ti)
			return true
		}
	}
	return false
}

// --- focus ------------------------------------------------------------------

focus_left :: proc(s: ^Strip) {
	if s.focused_col > 0 do s.focused_col -= 1
}

focus_right :: proc(s: ^Strip) {
	if s.focused_col < len(s.columns) - 1 do s.focused_col += 1
}

// Cycle focus to the next / previous column, wrapping around (for Alt+Tab).
focus_next :: proc(s: ^Strip) {
	if len(s.columns) == 0 do return
	s.focused_col = (s.focused_col + 1) % len(s.columns)
}

focus_prev :: proc(s: ^Strip) {
	if len(s.columns) == 0 do return
	s.focused_col = (s.focused_col - 1 + len(s.columns)) % len(s.columns)
}

focus_up :: proc(s: ^Strip) {
	if len(s.columns) == 0 do return
	col := &s.columns[s.focused_col]
	if col.focused_tile > 0 do col.focused_tile -= 1
}

focus_down :: proc(s: ^Strip) {
	if len(s.columns) == 0 do return
	col := &s.columns[s.focused_col]
	if col.focused_tile < len(col.tiles) - 1 do col.focused_tile += 1
}

// Window id currently focused, if any.
focused_window :: proc(s: ^Strip) -> (Window_Id, bool) {
	if len(s.columns) == 0 do return 0, false
	col := s.columns[s.focused_col]
	if len(col.tiles) == 0 do return 0, false
	return col.tiles[col.focused_tile].id, true
}

// --- reorder ----------------------------------------------------------------

move_column_left :: proc(s: ^Strip) {
	i := s.focused_col
	if i > 0 {
		s.columns[i], s.columns[i - 1] = s.columns[i - 1], s.columns[i]
		s.focused_col -= 1
	}
}

move_column_right :: proc(s: ^Strip) {
	i := s.focused_col
	if i < len(s.columns) - 1 {
		s.columns[i], s.columns[i + 1] = s.columns[i + 1], s.columns[i]
		s.focused_col += 1
	}
}

// --- width ------------------------------------------------------------------

set_width :: proc(s: ^Strip, frac: f64) {
	if len(s.columns) == 0 do return
	s.columns[s.focused_col].width_frac = frac
	s.columns[s.focused_col].eff_w = 0 // re-probe the real width at the new fraction
}

// Set the width of the column holding `id`, wherever it is (focused or not).
set_window_width :: proc(s: ^Strip, id: Window_Id, frac: f64) -> bool {
	for &col in s.columns {
		for t in col.tiles {
			if t.id != id do continue
			col.width_frac = frac
			col.eff_w = 0 // re-probe the real width at the new fraction
			return true
		}
	}
	return false
}

// Cycle the focused column through WIDTH_PRESETS (1/3 -> 1/2 -> 2/3 -> 1/3).
cycle_width :: proc(s: ^Strip) {
	if len(s.columns) == 0 do return
	col := &s.columns[s.focused_col]
	best := 0
	for i in 1 ..< len(WIDTH_PRESETS) {
		if abs(WIDTH_PRESETS[i] - col.width_frac) < abs(WIDTH_PRESETS[best] - col.width_frac) {
			best = i
		}
	}
	col.width_frac = WIDTH_PRESETS[(best + 1) % len(WIDTH_PRESETS)]
	col.eff_w = 0 // re-probe the real width at the new fraction
}

// --- consume / expel --------------------------------------------------------

// Pull the focused tile of the next column into the focused column.
consume_into_column :: proc(s: ^Strip) {
	if s.focused_col + 1 >= len(s.columns) do return
	next := &s.columns[s.focused_col + 1]
	if len(next.tiles) == 0 do return

	moved := next.tiles[next.focused_tile]
	remove_tile_at(s, s.focused_col + 1, next.focused_tile)

	cur := &s.columns[s.focused_col]
	append(&cur.tiles, moved)
	cur.focused_tile = len(cur.tiles) - 1
}

// Push the focused tile out into its own new column to the right.
expel_from_column :: proc(s: ^Strip) {
	if len(s.columns) == 0 do return
	cur := &s.columns[s.focused_col]
	if len(cur.tiles) <= 1 do return // already alone

	moved := cur.tiles[cur.focused_tile]
	width := cur.width_frac
	ordered_remove(&cur.tiles, cur.focused_tile)
	if cur.focused_tile >= len(cur.tiles) do cur.focused_tile = len(cur.tiles) - 1

	newcol: Column
	newcol.width_frac = width
	append(&newcol.tiles, moved)
	inject_at(&s.columns, s.focused_col + 1, newcol)
	s.focused_col += 1
}

// Move the tile holding `id` out of its column and stack it into column `dst`,
// focusing it there. Used to (re)group a window with others — e.g. dock a torn-off
// browser window back beside its siblings. Returns false if `id` isn't found or is
// already in `dst`.
regroup_into :: proc(s: ^Strip, id: Window_Id, dst_in: int) -> bool {
	if dst_in < 0 || dst_in >= len(s.columns) do return false
	dst := dst_in

	// Locate the tile.
	src, ti := -1, -1
	find: for ci in 0 ..< len(s.columns) {
		for k in 0 ..< len(s.columns[ci].tiles) {
			if s.columns[ci].tiles[k].id == id {
				src, ti = ci, k
				break find
			}
		}
	}
	if src < 0 || src == dst do return false

	moved := s.columns[src].tiles[ti]

	// A collapse left of `dst` shifts `dst` one to the left.
	if remove_tile_at(s, src, ti) && src < dst do dst -= 1

	dcol := &s.columns[dst]
	append(&dcol.tiles, moved)
	dcol.focused_tile = len(dcol.tiles) - 1
	s.focused_col = dst
	return true
}

// --- layout -----------------------------------------------------------------

Placement :: struct {
	id:      Window_Id,
	rect:    Rect,
	visible: bool, // false => scrolled out of view; effector should hide it
}

// Lay out ALL windows in the workspace as a grid filling the viewport (every
// window visible — no scrolling/hiding). Column-major strip order, row by row.
compute_grid :: proc(s: ^Strip, viewport: Rect, allocator := context.allocator) -> []Placement {
	out := make([dynamic]Placement, 0, 8, allocator)
	ids := make([dynamic]Window_Id, 0, 8, allocator)
	defer delete(ids)
	for col in s.columns do for tile in col.tiles do append(&ids, tile.id)

	n := len(ids)
	if n == 0 do return out[:]

	gap := s.gap
	cols := 1
	for cols * cols < n do cols += 1 // ceil(sqrt(n))
	rows := (n + cols - 1) / cols
	cw := (viewport.w - gap * f64(cols + 1)) / f64(cols)
	ch := (viewport.h - gap * f64(rows + 1)) / f64(rows)

	for id, i in ids {
		r := i / cols
		c := i % cols
		x := viewport.x + gap + f64(c) * (cw + gap)
		y := viewport.y + gap + f64(r) * (ch + gap)
		append(&out, Placement{id = id, rect = {x, y, cw, ch}, visible = true})
	}
	return out[:]
}

// Monocle: show only the focused column, filling the whole viewport (its tiles
// stacked vertically if it holds several); every other column is hidden off to
// its side. One window (column) per screen. Caller deletes the returned slice.
compute_monocle :: proc(s: ^Strip, viewport: Rect, allocator := context.allocator) -> []Placement {
	out := make([dynamic]Placement, 0, 8, allocator)
	if len(s.columns) == 0 do return out[:]

	gap := s.gap
	x := viewport.x + gap
	w := viewport.w - 2 * gap
	content_h := viewport.h - 2 * gap

	for col, ci in s.columns {
		nt := len(col.tiles)
		if nt == 0 do continue
		visible := ci == s.focused_col
		tile_h := (content_h - f64(nt - 1) * gap) / f64(nt)
		for tile, j in col.tiles {
			ty := viewport.y + gap + f64(j) * (tile_h + gap)
			append(&out, Placement{id = tile.id, rect = {x, ty, w, tile_h}, visible = visible})
		}
	}
	return out[:]
}

// Map the logical strip onto `viewport` (a display's usable visibleFrame).
// Settles `view_x` so the focused column is fully visible (minimal scroll),
// then emits one Placement per tile. Caller deletes the returned slice.
compute_layout :: proc(s: ^Strip, viewport: Rect, allocator := context.allocator) -> []Placement {
	out := make([dynamic]Placement, 0, 8, allocator)
	if len(s.columns) == 0 do return out[:]

	gap := s.gap
	content_w := viewport.w - 2 * gap
	content_h := viewport.h - 2 * gap

	n := len(s.columns)
	widths := make([]f64, n, allocator)
	defer delete(widths, allocator)
	xs := make([]f64, n, allocator)
	defer delete(xs, allocator)

	cursor := 0.0
	for col, i in s.columns {
		w := col.width_frac * content_w
		if col.eff_w > 0 do w = min(col.eff_w, content_w) // pack against the real width
		widths[i] = w
		xs[i] = cursor
		cursor += widths[i] + gap
	}

	// Settle the scroll position: scroll the minimum amount so the focused
	// column is fully on screen, but never left of the first column.
	f := s.focused_col
	f_left := xs[f]
	f_right := xs[f] + widths[f]
	if f_left < s.view_x do s.view_x = f_left
	if f_right > s.view_x + content_w do s.view_x = f_right - content_w
	// Never overscroll past the content's right edge (e.g. after closing the
	// rightmost column) — that strands columns off-left beside dead space.
	max_view := cursor - gap - content_w
	if s.view_x > max_view do s.view_x = max_view
	if s.view_x < 0 do s.view_x = 0

	left_edge := viewport.x + gap
	for col, i in s.columns {
		screen_x := left_edge + (xs[i] - s.view_x)
		w := widths[i]
		visible := (screen_x + w > viewport.x) && (screen_x < viewport.x + viewport.w)

		nt := len(col.tiles)
		if nt == 0 do continue
		tile_h := (content_h - f64(nt - 1) * gap) / f64(nt)
		for tile, j in col.tiles {
			ty := viewport.y + gap + f64(j) * (tile_h + gap)
			append(&out, Placement{id = tile.id, rect = {screen_x, ty, w, tile_h}, visible = visible})
		}
	}
	return out[:]
}
