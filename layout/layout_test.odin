package layout

import "core:testing"

// A 1000x800 usable area at origin (100, 50) — deliberately offset so tests
// catch functions that ignore the area's origin.
AREA :: Rect{100, 50, 1000, 800}

@(test)
test_maximize :: proc(t: ^testing.T) {
	testing.expect_value(t, apply_preset(AREA, .Maximize), AREA)
}

@(test)
test_left_half :: proc(t: ^testing.T) {
	testing.expect_value(t, apply_preset(AREA, .Left_Half), Rect{100, 50, 500, 800})
}

@(test)
test_right_half :: proc(t: ^testing.T) {
	testing.expect_value(t, apply_preset(AREA, .Right_Half), Rect{600, 50, 500, 800})
}

@(test)
test_bottom_right_quarter :: proc(t: ^testing.T) {
	testing.expect_value(t, apply_preset(AREA, .Bottom_Right), Rect{600, 450, 500, 400})
}

@(test)
test_center :: proc(t: ^testing.T) {
	// 60% of 1000x800 = 600x480, centred in the area.
	testing.expect_value(t, apply_preset(AREA, .Center), Rect{300, 210, 600, 480})
}

@(test)
test_left_two_thirds :: proc(t: ^testing.T) {
	got := apply_preset(AREA, .Left_Two_Thirds)
	testing.expectf(t, near(got.w, 2000.0 / 3.0), "want w~666.67, got %v", got.w)
	testing.expect_value(t, got.x, 100)
}

@(test)
test_right_third_position :: proc(t: ^testing.T) {
	got := apply_preset(AREA, .Right_Third)
	testing.expectf(t, near(got.x, 100 + 2000.0 / 3.0), "want x~766.67, got %v", got.x)
}

@(test)
test_remap_preserves_fraction :: proc(t: ^testing.T) {
	src := Rect{0, 0, 1000, 1000}
	dst := Rect{2000, -500, 500, 500} // smaller display, offset (incl. negative y)
	// A window covering the top-left quarter of src...
	win := Rect{0, 0, 500, 500}
	got := remap(win, src, dst)
	// ...should cover the top-left quarter of dst.
	testing.expect_value(t, got, Rect{2000, -500, 250, 250})
}

@(test)
test_contains :: proc(t: ^testing.T) {
	r := Rect{0, 0, 100, 100}
	testing.expect(t, contains(r, 50, 50))
	testing.expect(t, !contains(r, 100, 50)) // far edge is exclusive
	testing.expect(t, !contains(r, -1, 50))
}

near :: proc(a, b: f64) -> bool {
	d := a - b
	return d < 0.001 && d > -0.001
}
