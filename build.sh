#!/bin/sh
# Build niri-mac. Compiles the small AppKit shim (visibleFrame) then the Odin app.
set -e
cd "$(dirname "$0")"

clang -c -fobjc-arc -mmacosx-version-min=14.0 -o macos/screens.o macos/screens.m
odin build . -out:wm -minimum-os-version:14.0 -extra-linker-flags:"-framework AppKit -framework IOKit -framework CoreWLAN -framework ScreenCaptureKit -framework QuartzCore -framework CoreMedia -framework CoreVideo"

# Sign with a stable identity so TCC grants (Accessibility, Input Monitoring)
# survive rebuilds; ad-hoc signatures change every build and revoke them.
# Set WM_CODESIGN_ID to a "Apple Development: ..." identity (see `security
# find-identity -p codesigning`); unset skips signing.
if [ -n "${WM_CODESIGN_ID:-}" ]; then
	codesign -f -s "$WM_CODESIGN_ID" wm
fi

echo "built ./wm"
