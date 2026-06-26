// Package layout: pure window-geometry math with zero macOS dependencies.
//
// Everything here is deterministic and unit-testable. The macOS side converts
// its CGRects to layout.Rect, calls these functions, and converts back. This is
// the seam the niri scrollable-strip engine (M4+) will grow from; for M3 it
// provides the Rectangle/Magnet-style snap presets and the cross-monitor remap.
package layout

// A rectangle in the global, top-left-origin, y-down coordinate space that the
// macOS AX / CoreGraphics APIs use.
Rect :: struct {
	x, y, w, h: f64,
}

// Snap targets. "Area" is always the destination display's usable rect
// (visibleFrame: menu bar / Dock already excluded).
Preset :: enum {
	Maximize,
	Center, // centered, 60% of the area
	Left_Half,
	Right_Half,
	Top_Half,
	Bottom_Half,
	Top_Left,
	Top_Right,
	Bottom_Left,
	Bottom_Right,
	Left_Third,
	Center_Third,
	Right_Third,
	Left_Two_Thirds,
	Right_Two_Thirds,
}

CENTER_FRACTION :: 0.6

// Compute the target rect for a snap preset within `area`.
apply_preset :: proc(area: Rect, p: Preset) -> Rect {
	x, y, w, h := area.x, area.y, area.w, area.h
	half_w := w / 2
	half_h := h / 2
	third := w / 3

	switch p {
	case .Maximize:
		return area
	case .Center:
		cw := w * CENTER_FRACTION
		ch := h * CENTER_FRACTION
		return {x + (w - cw) / 2, y + (h - ch) / 2, cw, ch}
	case .Left_Half:
		return {x, y, half_w, h}
	case .Right_Half:
		return {x + half_w, y, half_w, h}
	case .Top_Half:
		return {x, y, w, half_h}
	case .Bottom_Half:
		return {x, y + half_h, w, half_h}
	case .Top_Left:
		return {x, y, half_w, half_h}
	case .Top_Right:
		return {x + half_w, y, half_w, half_h}
	case .Bottom_Left:
		return {x, y + half_h, half_w, half_h}
	case .Bottom_Right:
		return {x + half_w, y + half_h, half_w, half_h}
	case .Left_Third:
		return {x, y, third, h}
	case .Center_Third:
		return {x + third, y, third, h}
	case .Right_Third:
		return {x + 2 * third, y, third, h}
	case .Left_Two_Thirds:
		return {x, y, 2 * third, h}
	case .Right_Two_Thirds:
		return {x + third, y, 2 * third, h}
	}
	return area
}

// Remap a window's rect from a source display area onto a destination display
// area, preserving its fractional position and size (used by move-to-monitor).
remap :: proc(win: Rect, src: Rect, dst: Rect) -> Rect {
	fx := (win.x - src.x) / src.w
	fy := (win.y - src.y) / src.h
	fw := win.w / src.w
	fh := win.h / src.h
	return {dst.x + fx * dst.w, dst.y + fy * dst.h, fw * dst.w, fh * dst.h}
}

// True if `p` lies within `r` (half-open on the far edges).
contains :: proc(r: Rect, px, py: f64) -> bool {
	return px >= r.x && px < r.x + r.w && py >= r.y && py < r.y + r.h
}

center_of :: proc(r: Rect) -> (f64, f64) {
	return r.x + r.w / 2, r.y + r.h / 2
}
