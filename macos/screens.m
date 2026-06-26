// Tiny Objective-C shim: the one thing the pure C APIs can't give us is each
// display's visibleFrame (the usable area with the menu bar and Dock excluded).
// NSScreen exposes it, so we reach into AppKit here and hand the result back to
// Odin as plain C structs in CoreGraphics coordinates (top-left origin, y-down,
// global), keyed by CGDirectDisplayID so the Odin side can match it to the
// display a window sits on. Compiled to screens.o and linked by build.sh.
#import <AppKit/AppKit.h>
#import <stdint.h>
#import <CoreWLAN/CoreWLAN.h>
#import <IOKit/ps/IOPowerSources.h>
#import <IOKit/ps/IOPSKeys.h>
#import <math.h>
#import <ifaddrs.h>
#import <net/if.h>
#import <net/if_dl.h>

typedef struct {
	uint32_t display_id;
	uint32_t _pad;
	double x, y, w, h; // visibleFrame, CG top-left global coords
} WMVisibleFrame;

// Fill `out` with up to `max` displays' visible frames. Returns the count.
int wm_visible_frames(WMVisibleFrame *out, int max) {
	NSArray<NSScreen *> *screens = [NSScreen screens];
	if (screens.count == 0) {
		return 0;
	}
	// AppKit's global space has its origin at the bottom-left of the primary
	// screen (screens[0]) with y pointing up; CG/AX use top-left, y down. Flip
	// using the primary screen's full height.
	double primaryH = [(NSScreen *)screens[0] frame].size.height;

	int n = (int)screens.count;
	if (n > max) {
		n = max;
	}
	for (int i = 0; i < n; i++) {
		NSScreen *s = screens[i];
		NSRect vf = [s visibleFrame];
		NSNumber *num = [[s deviceDescription] objectForKey:@"NSScreenNumber"];
		out[i].display_id = (uint32_t)[num unsignedIntValue];
		out[i]._pad = 0;
		out[i].x = vf.origin.x;
		out[i].y = primaryH - (vf.origin.y + vf.size.height);
		out[i].w = vf.size.width;
		out[i].h = vf.size.height;
	}
	return n;
}

// The pid of the application the user currently sees as frontmost. The AX
// "system-wide focused application" attribute is unavailable to a background
// CLI process, so we ask NSWorkspace directly. Returns 0 if none.
int32_t wm_frontmost_pid(void) {
	NSRunningApplication *app = [[NSWorkspace sharedWorkspace] frontmostApplication];
	if (app == nil) {
		return 0;
	}
	return (int32_t)app.processIdentifier;
}

// --- focus ring overlay -----------------------------------------------------
// A borderless, transparent, click-through window that draws a coloured border
// around the focused window so the user can see focus changes (even in dry-run).

static NSWindow *gRing = nil;

static void ensure_ring(void) {
	if (gRing != nil) {
		return;
	}
	// A CLI tool must bootstrap AppKit to create windows; accessory policy
	// keeps us out of the Dock / menu bar.
	[NSApplication sharedApplication];
	[NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];

	NSWindow *w = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 64, 64)
	                                          styleMask:NSWindowStyleMaskBorderless
	                                            backing:NSBackingStoreBuffered
	                                              defer:NO];
	w.opaque = NO;
	w.backgroundColor = [NSColor clearColor];
	w.hasShadow = NO;
	w.ignoresMouseEvents = YES;
	w.level = NSScreenSaverWindowLevel;
	w.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
	                       NSWindowCollectionBehaviorStationary |
	                       NSWindowCollectionBehaviorIgnoresCycle;

	NSView *v = [[NSView alloc] initWithFrame:w.contentView.bounds];
	v.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
	v.wantsLayer = YES;
	v.layer.borderWidth = 4.0;
	v.layer.cornerRadius = 9.0;
	v.layer.borderColor = [NSColor colorWithCalibratedRed:0.20 green:0.65 blue:1.0 alpha:0.95].CGColor;
	v.layer.backgroundColor = [NSColor clearColor].CGColor;
	w.contentView = v;

	gRing = w;
}

// Position the ring around a window frame given in CG coordinates (top-left
// origin, y-down) and show it.
void wm_ring_show(double x, double y, double w, double h) {
	ensure_ring();
	NSArray<NSScreen *> *screens = [NSScreen screens];
	if (screens.count == 0) {
		return;
	}
	double primaryH = [(NSScreen *)screens[0] frame].size.height;
	double nsY = primaryH - (y + h); // flip top-left -> AppKit bottom-left
	[gRing setFrame:NSMakeRect(x, nsY, w, h) display:YES];
	[gRing orderFront:nil];
}

void wm_ring_hide(void) {
	if (gRing != nil) {
		[gRing orderOut:nil];
	}
}

// --- status bar -------------------------------------------------------------
// A thin always-on-top strip across the top, drawn as segments (one per window
// + a status prefix). The focused window's segment gets a coloured background.
// Clicks are handled by the daemon's event tap via wm_bar_hit (the window itself
// ignores mouse events). Sentinel id ~0 marks a non-clickable segment.

#define WM_BAR_NONE 0xFFFFFFFFFFFFFFFFULL
#define WM_BAR_MODE 0xFFFFFFFFFFFFFFFEULL     // layout-mode toggle segment
#define WM_BAR_SETTINGS 0xFFFFFFFFFFFFFFFDULL // settings (gear) segment
#define WM_BAR_PAD 12.0

typedef struct {
	const char *app;
	const char *title;
	unsigned long long window_id;
	int focused;
	int index; // 1-based position (matches Alt+<n>); 0 = none
} WMBarSeg;

@interface WMBarView : NSView
- (void)setSegs:(const WMBarSeg *)segs count:(int)count;
- (void)updateStatusWifi:(int)on text:(const char *)text battery:(int)pct charging:(int)charging clock:(const char *)clock;
- (unsigned long long)hitAtX:(double)x;
@end

@implementation WMBarView {
	NSMutableArray<NSAttributedString *> *_attrs;
	NSMutableArray<NSNumber *> *_ids;
	NSMutableArray<NSNumber *> *_focused;
	NSMutableArray<NSNumber *> *_x0;
	NSMutableArray<NSNumber *> *_x1;
	// Right-aligned system cluster, built from real subviews so they pick up the
	// vibrant material's tint (a hand-tinted bitmap does not and washes out).
	NSImageView *_wifiIcon, *_battIcon;
	NSTextField *_wifiLabel, *_battLabel, *_clockLabel;
	// SF-Symbol icons for the gear/mode segments (subviews, same vibrancy reason).
	NSMutableArray<NSImageView *> *_segIcons;
}
- (BOOL)isFlipped {
	return YES;
}

// Two-tone styled segment text: app name emphasised, title secondary.
- (NSAttributedString *)styled:(const WMBarSeg *)seg isStatus:(BOOL)status {
	NSString *app = [NSString stringWithUTF8String:(seg->app ? seg->app : "")];
	NSString *title = [NSString stringWithUTF8String:(seg->title ? seg->title : "")];
	if (app == nil) app = @"";
	if (title == nil) title = @"";

	NSColor *appColor, *titleColor;
	NSFontWeight appWeight = status ? NSFontWeightRegular : NSFontWeightSemibold;
	if (seg->focused) {
		appColor = [NSColor whiteColor];
		titleColor = [NSColor colorWithCalibratedWhite:1.0 alpha:0.82];
	} else if (status) {
		appColor = [NSColor colorWithCalibratedWhite:1.0 alpha:0.50];
		titleColor = appColor;
	} else {
		appColor = [NSColor colorWithCalibratedWhite:1.0 alpha:0.90];
		titleColor = [NSColor colorWithCalibratedWhite:1.0 alpha:0.48];
	}

	NSMutableAttributedString *s = [[NSMutableAttributedString alloc] init];
	// Leading [n] index hint (matches Alt+<n>).
	if (seg->index > 0) {
		NSColor *numColor = seg->focused ? [NSColor colorWithCalibratedWhite:1.0 alpha:0.95]
		                                 : [NSColor colorWithCalibratedWhite:1.0 alpha:0.40];
		[s appendAttributedString:[[NSAttributedString alloc] initWithString:[NSString stringWithFormat:@"[%d] ", seg->index] attributes:@{
			NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightSemibold],
			NSForegroundColorAttributeName: numColor,
		}]];
	}
	[s appendAttributedString:[[NSAttributedString alloc] initWithString:app attributes:@{
		NSFontAttributeName: [NSFont systemFontOfSize:13 weight:appWeight],
		NSForegroundColorAttributeName: appColor,
	}]];
	if (title.length > 0) {
		[s appendAttributedString:[[NSAttributedString alloc] initWithString:[@"  " stringByAppendingString:title] attributes:@{
			NSFontAttributeName: [NSFont systemFontOfSize:13 weight:NSFontWeightRegular],
			NSForegroundColorAttributeName: titleColor,
		}]];
	}
	return s;
}

// A vibrancy-tinted SF Symbol image view for the gear / mode segments.
- (NSImageView *)segIcon:(NSString *)name {
	NSImage *img = [NSImage imageWithSystemSymbolName:name accessibilityDescription:nil];
	NSImageView *iv = [NSImageView imageViewWithImage:(img ?: [[NSImage alloc] init])];
	if (img) {
		img.template = YES;
		iv.image = img;
	}
	iv.symbolConfiguration = [NSImageSymbolConfiguration configurationWithPointSize:14 weight:NSFontWeightRegular];
	iv.contentTintColor = [NSColor secondaryLabelColor];
	iv.imageScaling = NSImageScaleProportionallyDown;
	return iv;
}

- (void)setSegs:(const WMBarSeg *)segs count:(int)count {
	_attrs = [NSMutableArray array];
	_ids = [NSMutableArray array];
	_focused = [NSMutableArray array];
	_x0 = [NSMutableArray array];
	_x1 = [NSMutableArray array];
	for (NSImageView *iv in _segIcons) [iv removeFromSuperview];
	_segIcons = [NSMutableArray array];

	CGFloat h = self.bounds.size.height;
	CGFloat x = 8;
	for (int i = 0; i < count; i++) {
		unsigned long long wid = segs[i].window_id;

		// Gear / mode segments render as crisp SF Symbols, not Unicode glyphs.
		NSString *sym = nil;
		if (wid == WM_BAR_SETTINGS) {
			sym = @"gearshape";
		} else if (wid == WM_BAR_MODE) {
			if (segs[i].app && strcmp(segs[i].app, "grid") == 0)        sym = @"square.grid.2x2";
			else if (segs[i].app && strcmp(segs[i].app, "monocle") == 0) sym = @"rectangle";
			else                                                          sym = @"rectangle.split.3x1";
		}
		if (sym != nil) {
			CGFloat segW = 30;
			NSImageView *iv = [self segIcon:sym];
			iv.frame = NSMakeRect(x + 7, (h - 16) / 2.0, 16, 16);
			[self addSubview:iv];
			[_segIcons addObject:iv];
			[_attrs addObject:(NSAttributedString *)[NSNull null]]; // drawn as an icon, no text
			[_ids addObject:@(wid)];
			[_focused addObject:@(0)];
			[_x0 addObject:@(x)];
			[_x1 addObject:@(x + segW)];
			x += segW + 2;
			continue;
		}

		BOOL status = (wid == WM_BAR_NONE);
		NSAttributedString *as = [self styled:&segs[i] isStatus:status];
		CGFloat w = [as size].width + 2 * WM_BAR_PAD;
		[_attrs addObject:as];
		[_ids addObject:@(wid)];
		[_focused addObject:@(segs[i].focused)];
		[_x0 addObject:@(x)];
		[_x1 addObject:@(x + w)];
		x += w + 2; // small gap between segments
	}
	[self setNeedsDisplay:YES];
}

// Lazily create the status subviews (icons + labels). They live inside the
// vibrant effect view's subtree, so template images and label colours adapt to
// the material automatically.
- (void)ensureStatusViews {
	if (_clockLabel != nil) return;
	NSFont *font = [NSFont systemFontOfSize:12.5 weight:NSFontWeightMedium];
	NSFont *mono = [NSFont monospacedDigitSystemFontOfSize:12.5 weight:NSFontWeightMedium];

	_wifiIcon = [NSImageView imageViewWithImage:[NSImage imageWithSystemSymbolName:@"wifi" accessibilityDescription:nil] ?: [[NSImage alloc] init]];
	_wifiIcon.contentTintColor = [NSColor secondaryLabelColor];
	_battIcon = [NSImageView imageViewWithImage:[[NSImage alloc] init]];

	_wifiLabel = [NSTextField labelWithString:@""];
	_battLabel = [NSTextField labelWithString:@""];
	_clockLabel = [NSTextField labelWithString:@""];
	for (NSTextField *t in @[_wifiLabel, _battLabel, _clockLabel]) {
		t.font = (t == _clockLabel || t == _battLabel) ? mono : font;
		t.textColor = (t == _clockLabel) ? [NSColor labelColor] : [NSColor secondaryLabelColor];
		t.backgroundColor = [NSColor clearColor];
		t.drawsBackground = NO;
	}
	for (NSView *vw in @[_wifiIcon, _wifiLabel, _battIcon, _battLabel, _clockLabel]) {
		[self addSubview:vw];
	}
}

// Right-to-left layout of the cluster, vertically centred, pinned to the right
// edge. Called on every refresh (cheap) so it tracks width/content changes.
- (void)layoutStatus {
	CGFloat h = self.bounds.size.height;
	__block CGFloat x = self.bounds.size.width - WM_BAR_PAD;
	CGFloat gap = 5, group = 14;

	// `spacer` is the gap inserted to the LEFT of the placed view (i.e. before the
	// next, further-left item) — `group` between clusters, `gap` within one.
	void (^place)(NSView *, CGFloat) = ^(NSView *vw, CGFloat lead) {
		if (vw.hidden) return;
		NSSize sz = vw.frame.size;
		if ([vw isKindOfClass:[NSTextField class]]) {
			[(NSTextField *)vw sizeToFit];
			sz = vw.frame.size;
		}
		x -= sz.width;
		vw.frame = NSMakeRect(x, (h - sz.height) / 2.0, sz.width, sz.height);
		x -= lead;
	};

	place(_clockLabel, group); // clock (anchor) at the far right
	place(_battLabel, gap);
	place(_battIcon, group);   // gap before the wifi cluster
	place(_wifiLabel, gap);
	place(_wifiIcon, 0);
}

- (void)updateStatusWifi:(int)on text:(const char *)text battery:(int)pct charging:(int)charging clock:(const char *)clock {
	[self ensureStatusViews];

	_clockLabel.stringValue = (clock && clock[0]) ? [NSString stringWithUTF8String:clock] : @"";

	// Wi-Fi: icon + throughput text (↑up ↓down).
	NSImage *wsym = [NSImage imageWithSystemSymbolName:(on ? @"wifi" : @"wifi.slash") accessibilityDescription:nil];
	if (wsym) { wsym.template = YES; _wifiIcon.image = wsym; }
	_wifiIcon.contentTintColor = on ? [NSColor secondaryLabelColor] : [NSColor tertiaryLabelColor];
	[_wifiIcon.image setSize:NSMakeSize(16, 12)];
	_wifiIcon.frame = NSMakeRect(0, 0, 16, 12);
	_wifiIcon.hidden = NO;
	if (text && text[0]) {
		_wifiLabel.stringValue = [NSString stringWithUTF8String:text];
		_wifiLabel.hidden = NO;
	} else {
		_wifiLabel.hidden = YES;
	}

	// Battery
	if (pct >= 0) {
		NSString *name;
		if (charging) name = @"battery.100.bolt";
		else if (pct >= 88) name = @"battery.100";
		else if (pct >= 63) name = @"battery.75";
		else if (pct >= 38) name = @"battery.50";
		else if (pct >= 13) name = @"battery.25";
		else name = @"battery.0";
		NSImage *bsym = [NSImage imageWithSystemSymbolName:name accessibilityDescription:nil];
		if (bsym) { bsym.template = YES; _battIcon.image = bsym; }
		_battIcon.contentTintColor = charging ? [NSColor controlAccentColor] : [NSColor secondaryLabelColor];
		[_battIcon.image setSize:NSMakeSize(22, 12)];
		_battIcon.frame = NSMakeRect(0, 0, 22, 12);
		_battIcon.hidden = NO;
		_battLabel.stringValue = [NSString stringWithFormat:@"%d%%", pct];
		_battLabel.textColor = charging ? [NSColor labelColor] : [NSColor secondaryLabelColor];
		_battLabel.hidden = NO;
	} else {
		_battIcon.hidden = YES;
		_battLabel.hidden = YES;
	}

	[self layoutStatus];
}

- (void)drawRect:(NSRect)dirty {
	CGFloat h = self.bounds.size.height;
	for (NSUInteger i = 0; i < _attrs.count; i++) {
		CGFloat x0 = [_x0[i] doubleValue], x1 = [_x1[i] doubleValue];
		if ([_focused[i] intValue]) {
			NSRect r = NSInsetRect(NSMakeRect(x0, 0, x1 - x0, h), 0, 3);
			[[NSColor controlAccentColor] set];
			NSRectFill(r); // square highlight (no rounded corners)
		}
		if (_attrs[i] == (id)[NSNull null]) continue; // icon segment, drawn as a subview
		NSAttributedString *as = _attrs[i];
		NSSize sz = [as size];
		[as drawAtPoint:NSMakePoint(x0 + WM_BAR_PAD, (h - sz.height) / 2)];
	}
	// The status cluster is drawn by its subviews (added above), which render on
	// top of this content and stay legible over any long window title.
}

- (unsigned long long)hitAtX:(double)x {
	for (NSUInteger i = 0; i < _x0.count; i++) {
		if (x >= [_x0[i] doubleValue] && x < [_x1[i] doubleValue]) {
			return [_ids[i] unsignedLongLongValue];
		}
	}
	return WM_BAR_NONE;
}
@end

// One bar per monitor, indexed by the daemon's monitor index. Grown on demand.
static NSMutableArray<NSWindow *> *gBars = nil;
static NSMutableArray<WMBarView *> *gBarViews = nil;

// Ensure a bar window exists for monitor `idx` (creating any up to it), and
// return its view. Each bar is an identical borderless vibrant strip.
static WMBarView *ensure_bar(int idx) {
	if (gBars == nil) {
		gBars = [NSMutableArray array];
		gBarViews = [NSMutableArray array];
	}
	[NSApplication sharedApplication];
	[NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
	while ((int)gBars.count <= idx) {
		NSWindow *w = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 800, 28)
		                                          styleMask:NSWindowStyleMaskBorderless
		                                            backing:NSBackingStoreBuffered
		                                              defer:NO];
		w.opaque = NO;
		w.backgroundColor = [NSColor clearColor];
		w.hasShadow = NO;
		w.ignoresMouseEvents = YES; // clicks come through the daemon's event tap
		// Sit just below the native menu bar (level 24) so that when the auto-hidden
		// menu bar is revealed on hover it draws on top of ours — the native wifi /
		// clock / per-app menus stay reachable. Still above tiled windows (level 0).
		w.level = NSMainMenuWindowLevel - 1;
		w.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
		                       NSWindowCollectionBehaviorStationary |
		                       NSWindowCollectionBehaviorIgnoresCycle;

		// Native blurred background (vibrancy), dark.
		NSVisualEffectView *fx = [[NSVisualEffectView alloc] initWithFrame:w.contentView.bounds];
		fx.material = NSVisualEffectMaterialHUDWindow;
		fx.blendingMode = NSVisualEffectBlendingModeBehindWindow;
		fx.state = NSVisualEffectStateActive;
		fx.appearance = [NSAppearance appearanceNamed:NSAppearanceNameVibrantDark];
		fx.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

		WMBarView *v = [[WMBarView alloc] initWithFrame:fx.bounds];
		v.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
		[fx addSubview:v];
		w.contentView = fx;
		[gBars addObject:w];
		[gBarViews addObject:v];
	}
	return gBarViews[idx];
}

// Position bar `idx` (CG top-left coords) and set its segments.
void wm_bar_set(int idx, const WMBarSeg *segs, int count, double x, double y, double w, double h) {
	WMBarView *view = ensure_bar(idx);
	NSArray<NSScreen *> *screens = [NSScreen screens];
	if (screens.count == 0) {
		return;
	}
	double primaryH = [(NSScreen *)screens[0] frame].size.height;
	double nsY = primaryH - (y + h);
	[gBars[idx] setFrame:NSMakeRect(x, nsY, w, h) display:YES];
	[view setSegs:segs count:count];
	[gBars[idx] orderFront:nil];
}

// Window id of the segment at bar-local x on bar `idx` (or WM_BAR_NONE).
unsigned long long wm_bar_hit(int idx, double local_x) {
	if (gBarViews == nil || idx < 0 || idx >= (int)gBarViews.count) {
		return WM_BAR_NONE;
	}
	return [gBarViews[idx] hitAtX:local_x];
}

void wm_bar_hide(void) {
	for (NSWindow *w in gBars) {
		[w orderOut:nil];
	}
}

// Hide bars from index `from` onward — used when a display is unplugged so its
// now-orphaned bar doesn't linger.
void wm_bar_hide_from(int from) {
	for (int i = from; gBars != nil && i < (int)gBars.count; i++) {
		[gBars[i] orderOut:nil];
	}
}

// --- status cluster (clock / battery / wifi) --------------------------------
// Read here and pushed into the bar view's right-aligned subviews, so the WM's
// bar shows what the (now-below-the-menu-bar) native menu bar used to surface.

// Locale-aware "Mon 9:41 PM" / "Mon 21:41".
static NSString *bar_clock(void) {
	static NSDateFormatter *fmt = nil;
	if (fmt == nil) {
		fmt = [[NSDateFormatter alloc] init];
		fmt.locale = [NSLocale currentLocale];
		fmt.dateFormat = [NSDateFormatter dateFormatFromTemplate:@"EEE jmm" options:0 locale:[NSLocale currentLocale]];
	}
	return [fmt stringFromDate:[NSDate date]];
}

// Internal battery percent (0..100), or -1 if the machine has no battery.
// *charging is set to 1 while charging / plugged in.
static int bar_battery(int *charging) {
	*charging = 0;
	int pct = -1;
	CFTypeRef info = IOPSCopyPowerSourcesInfo();
	if (info) {
		CFArrayRef list = IOPSCopyPowerSourcesList(info);
		if (list) {
			for (CFIndex i = 0; i < CFArrayGetCount(list); i++) {
				CFDictionaryRef d = IOPSGetPowerSourceDescription(info, CFArrayGetValueAtIndex(list, i));
				if (!d) continue;
				CFStringRef type = CFDictionaryGetValue(d, CFSTR(kIOPSTypeKey));
				if (!(type && CFEqual(type, CFSTR(kIOPSInternalBatteryType)))) continue;
				int cur = 0, mx = 0;
				CFNumberRef c = CFDictionaryGetValue(d, CFSTR(kIOPSCurrentCapacityKey));
				CFNumberRef m = CFDictionaryGetValue(d, CFSTR(kIOPSMaxCapacityKey));
				if (c) CFNumberGetValue(c, kCFNumberIntType, &cur);
				if (m) CFNumberGetValue(m, kCFNumberIntType, &mx);
				if (mx > 0) pct = (int)lround((double)cur / (double)mx * 100.0);
				CFBooleanRef ch = CFDictionaryGetValue(d, CFSTR(kIOPSIsChargingKey));
				if (ch && CFBooleanGetValue(ch)) *charging = 1;
				break;
			}
			CFRelease(list);
		}
		CFRelease(info);
	}
	return pct;
}

// Wi-Fi power state (1 on / 0 off or absent); fills *ssid (may stay empty if the
// process lacks Location permission — then we show the symbol only).
static int bar_wifi(char *ssid, int cap) {
	ssid[0] = 0;
	CWWiFiClient *client = [CWWiFiClient sharedWiFiClient];
	if (client == nil) return 0;
	CWInterface *iface = [client interface];
	if (iface == nil) return 0;
	NSString *name = iface.ssid;
	if (name != nil && name.length > 0) {
		strncpy(ssid, name.UTF8String, cap - 1);
		ssid[cap - 1] = 0;
	}
	return iface.powerOn ? 1 : 0;
}

// Per-second network throughput across all up, non-loopback interfaces, computed
// from the delta in byte counters since the last call. First call returns 0/0
// (it only establishes the baseline).
static void bar_net_rates(double *up_bps, double *down_bps) {
	static unsigned long long lastIn = 0, lastOut = 0;
	static CFAbsoluteTime lastT = 0;
	*up_bps = 0;
	*down_bps = 0;

	unsigned long long inB = 0, outB = 0;
	struct ifaddrs *list = NULL;
	if (getifaddrs(&list) == 0) {
		for (struct ifaddrs *p = list; p != NULL; p = p->ifa_next) {
			if (p->ifa_addr == NULL || p->ifa_addr->sa_family != AF_LINK) continue;
			if (!(p->ifa_flags & IFF_UP) || (p->ifa_flags & IFF_LOOPBACK)) continue;
			struct if_data *d = (struct if_data *)p->ifa_data;
			if (d == NULL) continue;
			inB += d->ifi_ibytes;
			outB += d->ifi_obytes;
		}
		freeifaddrs(list);
	}

	CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
	if (lastT > 0) {
		double dt = now - lastT;
		if (dt > 0.05) {
			if (outB >= lastOut) *up_bps = (double)(outB - lastOut) / dt;
			if (inB >= lastIn) *down_bps = (double)(inB - lastIn) / dt;
		}
	}
	lastIn = inB;
	lastOut = outB;
	lastT = now;
}

// Compact human rate: "1.2M" / "340K" / "12B" (no "/s" — the arrows imply rate).
static NSString *fmt_rate(double bps) {
	if (bps >= 1024.0 * 1024.0) return [NSString stringWithFormat:@"%.1fM", bps / (1024.0 * 1024.0)];
	if (bps >= 1024.0) return [NSString stringWithFormat:@"%.0fK", bps / 1024.0];
	return [NSString stringWithFormat:@"%.0fB", bps];
}

// Height of the system menu bar (so the WM can reserve the strip the auto-hidden
// menu bar reveals into). ~24pt; falls back to the status-bar thickness.
double wm_menu_bar_height(void) {
	double h = [[NSApplication sharedApplication] mainMenu].menuBarHeight;
	if (h < 1) h = [NSStatusBar systemStatusBar].thickness;
	if (h < 1) h = 24;
	return h;
}

// Read clock/battery/wifi once and push them into every bar's right-aligned
// cluster (same data on each display, like the native menu bar). Cheap; call it
// on the daemon's tick. No-op until at least one bar exists.
void wm_bar_status_refresh(void) {
	if (gBarViews == nil || gBarViews.count == 0) return;

	char ssid[64];
	int on = bar_wifi(ssid, sizeof ssid);
	int charging = 0;
	int pct = bar_battery(&charging);

	double up = 0, down = 0;
	bar_net_rates(&up, &down);
	NSString *wifiText = @"";
	if (on) {
		NSString *rates = [NSString stringWithFormat:@"↑%@ ↓%@", fmt_rate(up), fmt_rate(down)];
		// Prepend the SSID when the process is allowed to read it.
		wifiText = ssid[0] ? [NSString stringWithFormat:@"%s  %@", ssid, rates] : rates;
	}

	for (WMBarView *v in gBarViews) {
		[v updateStatusWifi:on text:wifiText.UTF8String battery:pct charging:charging clock:bar_clock().UTF8String];
	}
}

// --- settings window --------------------------------------------------------
// A real AppKit window (gear on the bar / Alt+S opens it) showing the current
// config, the hotkey reference, and a live list of open windows each with an
// Ignore / Unignore button. Button clicks are forwarded to the daemon as command
// strings via gSettingsCmd (registered from Odin); the daemon re-pushes the rows.

typedef struct {
	const char *app;
	const char *title;
	int ignored; // 1 if the owning app is in the never-tile set
} WMSettingsRow;

static void (*gSettingsCmd)(const char *) = NULL;

void wm_settings_set_handler(void (*fn)(const char *)) { gSettingsCmd = fn; }

@interface WMFlipped : NSView
@end
@implementation WMFlipped
- (BOOL)isFlipped { return YES; }
@end

@interface WMSettingsWin : NSObject <NSWindowDelegate> {
	NSWindow *_win;
	NSScrollView *_scroll;
	WMFlipped *_doc;
	NSString *_cfg, *_hk;
	NSArray<NSDictionary *> *_rows;
}
@property (assign) BOOL open;
+ (instancetype)shared;
- (void)show;
- (void)setConfig:(NSString *)cfg hotkeys:(NSString *)hk;
- (void)setRowsArray:(NSArray<NSDictionary *> *)rows;
@end

@implementation WMSettingsWin

+ (instancetype)shared {
	static WMSettingsWin *s = nil;
	if (s == nil) s = [[WMSettingsWin alloc] init];
	return s;
}

- (void)ensureWin {
	if (_win != nil) return;
	[NSApplication sharedApplication];
	NSRect frame = NSMakeRect(0, 0, 540, 660);
	_win = [[NSWindow alloc] initWithContentRect:frame
	                                   styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable
	                                     backing:NSBackingStoreBuffered
	                                       defer:NO];
	_win.title = @"niri-mac settings";
	_win.releasedWhenClosed = NO;
	_win.delegate = self;
	_win.level = NSFloatingWindowLevel;
	[_win center];

	_scroll = [[NSScrollView alloc] initWithFrame:((NSView *)_win.contentView).bounds];
	_scroll.hasVerticalScroller = YES;
	_scroll.drawsBackground = NO;
	_scroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
	_doc = [[WMFlipped alloc] initWithFrame:NSMakeRect(0, 0, frame.size.width, frame.size.height)];
	_scroll.documentView = _doc;
	_win.contentView = _scroll;
}

// A section header label.
- (NSTextField *)header:(NSString *)s at:(CGFloat)y width:(CGFloat)w {
	NSTextField *t = [NSTextField labelWithString:s];
	t.font = [NSFont systemFontOfSize:11 weight:NSFontWeightSemibold];
	t.textColor = [NSColor secondaryLabelColor];
	t.frame = NSMakeRect(16, y, w - 32, 16);
	return t;
}

- (NSTextField *)body:(NSString *)s at:(CGFloat)y width:(CGFloat)w {
	NSTextField *t = [NSTextField wrappingLabelWithString:s];
	t.font = [NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightRegular];
	t.textColor = [NSColor labelColor];
	t.frame = NSMakeRect(16, y, w - 32, 0);
	[t sizeToFit];
	NSRect f = t.frame;
	f.size.width = w - 32;
	t.frame = f;
	return t;
}

- (void)relayout {
	[self ensureWin];
	CGFloat w = _scroll.contentSize.width;
	if (w < 100) w = 540;
	for (NSView *v in [_doc.subviews copy]) [v removeFromSuperview];

	CGFloat y = 16;

	// Config + action buttons.
	[_doc addSubview:[self header:@"CONFIG" at:y width:w]];
	y += 22;
	NSTextField *cfg = [self body:(_cfg ?: @"") at:y width:w];
	[_doc addSubview:cfg];
	y += cfg.frame.size.height + 10;

	NSArray *acts = @[@[@"Toggle tiling", @"live toggle"], @[@"Grid / columns", @"mode toggle"], @[@"Fullscreen: one window", @"monocle toggle"], @[@"Hide mode", @"hide-mode toggle"]];
	CGFloat bx = 16;
	for (NSArray *a in acts) {
		NSButton *btn = [NSButton buttonWithTitle:a[0] target:self action:@selector(action:)];
		btn.identifier = a[1];
		btn.bezelStyle = NSBezelStyleRounded;
		[btn sizeToFit];
		NSRect bf = btn.frame;
		bf.origin = NSMakePoint(bx, y);
		btn.frame = bf;
		[_doc addSubview:btn];
		bx += bf.size.width + 8;
	}
	y += 36;

	// Hotkeys.
	[_doc addSubview:[self header:@"HOTKEYS" at:y width:w]];
	y += 22;
	NSTextField *hk = [self body:(_hk ?: @"") at:y width:w];
	[_doc addSubview:hk];
	y += hk.frame.size.height + 14;

	// Window list.
	[_doc addSubview:[self header:@"WINDOWS — ignore keeps an app out of tiling" at:y width:w]];
	y += 24;
	for (NSDictionary *row in _rows) {
		NSString *app = row[@"app"];
		NSString *title = row[@"title"];
		BOOL ignored = [row[@"ignored"] boolValue];

		NSTextField *lbl = [NSTextField labelWithString:[NSString stringWithFormat:@"%@  —  %@", app, title]];
		lbl.font = [NSFont systemFontOfSize:12 weight:NSFontWeightRegular];
		lbl.textColor = ignored ? [NSColor tertiaryLabelColor] : [NSColor labelColor];
		lbl.lineBreakMode = NSLineBreakByTruncatingTail;
		lbl.frame = NSMakeRect(16, y + 3, w - 32 - 104, 18);
		[_doc addSubview:lbl];

		NSButton *btn = [NSButton buttonWithTitle:(ignored ? @"Unignore" : @"Ignore") target:self action:@selector(action:)];
		btn.bezelStyle = NSBezelStyleRounded;
		btn.identifier = [NSString stringWithFormat:@"%@ %@", (ignored ? @"unignore" : @"ignore"), app];
		btn.frame = NSMakeRect(w - 16 - 96, y, 96, 24);
		btn.autoresizingMask = NSViewMinXMargin;
		[_doc addSubview:btn];
		y += 30;
	}
	y += 16;

	CGFloat docH = MAX(y, _scroll.contentSize.height);
	_doc.frame = NSMakeRect(0, 0, w, docH);
}

- (void)action:(NSButton *)sender {
	if (gSettingsCmd && sender.identifier.length > 0) {
		gSettingsCmd(sender.identifier.UTF8String);
	}
}

- (void)setConfig:(NSString *)cfg hotkeys:(NSString *)hk {
	_cfg = cfg;
	_hk = hk;
	if (_win != nil) [self relayout];
}

- (void)setRowsArray:(NSArray<NSDictionary *> *)rows {
	_rows = rows;
	if (_win != nil) [self relayout];
}

- (void)show {
	[self ensureWin];
	[self relayout];
	self.open = YES;
	[NSApp activateIgnoringOtherApps:YES];
	[_win makeKeyAndOrderFront:nil];
}

- (void)windowWillClose:(NSNotification *)n {
	self.open = NO;
}
@end

void wm_settings_open(void) { [[WMSettingsWin shared] show]; }
int wm_settings_is_open(void) { return [WMSettingsWin shared].open ? 1 : 0; }

void wm_settings_set_info(const char *config, const char *hotkeys) {
	[[WMSettingsWin shared] setConfig:(config ? [NSString stringWithUTF8String:config] : @"")
	                         hotkeys:(hotkeys ? [NSString stringWithUTF8String:hotkeys] : @"")];
}

// --- app event loop ---------------------------------------------------------
// The daemon must run the real AppKit event loop (not a bare CFRunLoopRun) so
// that windows it shows — the settings window — actually receive mouse events
// for their buttons and title-bar controls. [NSApp run] still services every
// CFRunLoop source/timer the daemon added to the main run loop (the event tap,
// the IPC socket FD, the reconcile/focus timers), so nothing else changes.
void wm_app_run(void) {
	[NSApplication sharedApplication];
	[NSApp run];
}

void wm_app_stop(void) {
	[NSApp stop:nil];
	// -run only checks the stop flag after it dispatches an event, so post a
	// no-op event to make it return promptly.
	NSEvent *wake = [NSEvent otherEventWithType:NSEventTypeApplicationDefined
	                                   location:NSZeroPoint
	                              modifierFlags:0
	                                  timestamp:0
	                               windowNumber:0
	                                    context:nil
	                                    subtype:0
	                                      data1:0
	                                      data2:0];
	[NSApp postEvent:wake atStart:YES];
}

void wm_settings_set_rows(const WMSettingsRow *rows, int count) {
	NSMutableArray *arr = [NSMutableArray arrayWithCapacity:count];
	for (int i = 0; i < count; i++) {
		[arr addObject:@{
			@"app": rows[i].app ? [NSString stringWithUTF8String:rows[i].app] : @"",
			@"title": rows[i].title ? [NSString stringWithUTF8String:rows[i].title] : @"",
			@"ignored": @(rows[i].ignored),
		}];
	}
	[[WMSettingsWin shared] setRowsArray:arr];
}

// --- share stage (live window mirror) ---------------------------------------
// A normal titled window ("Niri Stage") you share ONCE in MS Teams. A hotkey
// points it at the focused window; ScreenCaptureKit live-mirrors that window's
// pixels into the stage window's CALayer contents, so you swap what's shared
// without unshare/reshare in Teams. One source at a time; works even if the
// source is occluded or on another Space.

#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <IOSurface/IOSurface.h>
#import <QuartzCore/QuartzCore.h>

@interface WMShareStage : NSObject <SCStreamOutput, SCStreamDelegate, NSWindowDelegate>
@property (strong) NSWindow *win;
@property (strong) CALayer *contentLayer;
@property (assign) CVPixelBufferRef shownBuffer; // retained; the frame CA is displaying now
@property (strong) SCStream *stream;
@property (strong) dispatch_queue_t frameQueue;
@property (assign) BOOL running;
+ (instancetype)shared;
@end

@implementation WMShareStage

+ (instancetype)shared {
	static WMShareStage *s = nil;
	if (s == nil) s = [[WMShareStage alloc] init];
	return s;
}

- (void)ensureWin {
	if (_win != nil) return;
	[NSApplication sharedApplication];
	[NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];

	NSRect frame = NSMakeRect(0, 0, 1280, 720);
	_win = [[NSWindow alloc] initWithContentRect:frame
	                                   styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable | NSWindowStyleMaskMiniaturizable
	                                     backing:NSBackingStoreBuffered
	                                       defer:NO];
	_win.title = @"Niri Stage";
	_win.releasedWhenClosed = NO;
	_win.level = NSNormalWindowLevel; // a normal shareable window, not an overlay
	_win.contentAspectRatio = NSMakeSize(16, 9);
	_win.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces;
	_win.delegate = self; // closing the window stops the capture (see windowWillClose:)
	[_win center];

	// Layer-hosting view: a plain CALayer whose `contents` we set to each frame's
	// IOSurface. Unlike AVSampleBufferDisplayLayer, this lives in the window's
	// normal backing store, so window-capture screen sharing (Teams/Zoom) follows
	// it live instead of freezing on the first frame. ResizeAspect + black
	// background letterboxes any source.
	NSView *host = [[NSView alloc] initWithFrame:frame];
	_contentLayer = [CALayer layer];
	_contentLayer.contentsGravity = kCAGravityResizeAspect;
	_contentLayer.backgroundColor = NSColor.blackColor.CGColor;
	host.layer = _contentLayer;
	host.wantsLayer = YES;
	_win.contentView = host;

	_frameQueue = dispatch_queue_create("info.pettit.niri.stage", DISPATCH_QUEUE_SERIAL);
}

- (void)captureWindow:(CGWindowID)wid {
	[self ensureWin];
	[_win orderFront:nil]; // show without stealing focus from the source window

	if (wid == 0 || wid == (CGWindowID)_win.windowNumber) return; // never mirror ourselves

	// Async; also triggers the Screen Recording prompt on first run.
	[SCShareableContent getShareableContentExcludingDesktopWindows:YES
	                                          onScreenWindowsOnly:NO
	                                            completionHandler:^(SCShareableContent *content, NSError *error) {
		if (error || content == nil) return; // keep showing the last source
		SCWindow *target = nil;
		for (SCWindow *w in content.windows) {
			if (w.windowID == wid) { target = w; break; }
		}
		if (target == nil) return; // window gone — keep last source
		dispatch_async(dispatch_get_main_queue(), ^{ [self applyFilterForWindow:target]; });
	}];
}

- (void)applyFilterForWindow:(SCWindow *)target {
	SCContentFilter *filter = [[SCContentFilter alloc] initWithDesktopIndependentWindow:target];

	SCStreamConfiguration *cfg = [[SCStreamConfiguration alloc] init];
	CGFloat scale = filter.pointPixelScale > 0 ? filter.pointPixelScale : 2.0;
	CGSize pts = filter.contentRect.size;
	cfg.width = (size_t)lround(pts.width * scale);   // device pixels, not points
	cfg.height = (size_t)lround(pts.height * scale);
	if (cfg.width == 0) cfg.width = 1280;
	if (cfg.height == 0) cfg.height = 720;
	cfg.minimumFrameInterval = CMTimeMake(1, 60);
	cfg.pixelFormat = kCVPixelFormatType_32BGRA;
	cfg.queueDepth = 6;
	cfg.showsCursor = YES;
	cfg.scalesToFit = YES;

	if (_stream && _running) { // hot-swap source: no teardown, no black flash
		[_stream updateConfiguration:cfg completionHandler:^(NSError *e){}];
		[_stream updateContentFilter:filter completionHandler:^(NSError *e){}];
		return;
	}
	SCStream *s = [[SCStream alloc] initWithFilter:filter configuration:cfg delegate:self];
	NSError *addErr = nil;
	[s addStreamOutput:self type:SCStreamOutputTypeScreen sampleHandlerQueue:_frameQueue error:&addErr];
	if (addErr) return;
	_stream = s;
	[s startCaptureWithCompletionHandler:^(NSError *e){ self.running = (e == nil); }];
}

- (void)stream:(SCStream *)stream didOutputSampleBuffer:(CMSampleBufferRef)sb ofType:(SCStreamOutputType)type {
	if (type != SCStreamOutputTypeScreen) return;
	if (!CMSampleBufferIsValid(sb)) return;

	// Only complete frames carry fresh pixels; drop idle/blank/suspended.
	CFArrayRef info = CMSampleBufferGetSampleAttachmentsArray(sb, NO);
	if (info && CFArrayGetCount(info) > 0) {
		CFDictionaryRef d = CFArrayGetValueAtIndex(info, 0);
		NSNumber *st = (__bridge NSNumber *)CFDictionaryGetValue(d, (__bridge const void *)SCStreamFrameInfoStatus);
		if (st && st.intValue != SCFrameStatusComplete) return;
	}

	CVPixelBufferRef pb = CMSampleBufferGetImageBuffer(sb);
	if (pb == NULL) return;
	IOSurfaceRef surf = CVPixelBufferGetIOSurface(pb);
	if (surf == NULL) return;

	// CA retains the IOSurface while it's the layer's contents, but SCK recycles
	// the backing CVPixelBuffer from its pool — hold a strong ref to the frame on
	// screen so it isn't overwritten mid-display, releasing the prior one.
	CVPixelBufferRetain(pb);
	dispatch_async(dispatch_get_main_queue(), ^{
		[CATransaction begin];
		[CATransaction setDisableActions:YES]; // no implicit fade between frames
		self.contentLayer.contents = (__bridge id)surf;
		[CATransaction commit];
		if (_shownBuffer) CVPixelBufferRelease(_shownBuffer);
		_shownBuffer = pb;
	});
}

- (void)stream:(SCStream *)stream didStopWithError:(NSError *)error {
	self.running = NO; // source closed/crashed; next capture recreates the stream
}

// Fully disable: stop the capture stream (frees CPU + the Screen Recording
// indicator), clear the last frame, and hide the window.
- (void)stop {
	if (_win == nil) return;
	if (_stream) {
		[_stream stopCaptureWithCompletionHandler:^(NSError *e){}];
		_stream = nil;
	}
	_running = NO;
	dispatch_async(dispatch_get_main_queue(), ^{
		self.contentLayer.contents = nil; // clear the last frame
		if (_shownBuffer) { CVPixelBufferRelease(_shownBuffer); _shownBuffer = NULL; }
	});
	[_win orderOut:nil];
}

- (void)windowWillClose:(NSNotification *)n {
	[self stop]; // red close button = disable sharing
}
@end

void wm_stage_capture_window(uint32_t cg_window_id) {
	[[WMShareStage shared] captureWindow:(CGWindowID)cg_window_id];
}

void wm_stage_hide(void) {
	[[WMShareStage shared] stop];
}

uint32_t wm_stage_window_id(void) {
	WMShareStage *s = [WMShareStage shared];
	return s.win ? (uint32_t)s.win.windowNumber : 0;
}

int wm_screen_capture_authorized(void) {
	return CGPreflightScreenCaptureAccess() ? 1 : 0;
}

void wm_screen_capture_request(void) {
	CGRequestScreenCaptureAccess();
}
