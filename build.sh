#!/bin/sh
# Build niri-mac. Compiles the small AppKit shim (visibleFrame) then the Odin app.
set -e
cd "$(dirname "$0")"

clang -c -fobjc-arc -mmacosx-version-min=14.0 -o macos/screens.o macos/screens.m
odin build . -out:wm -minimum-os-version:14.0 -extra-linker-flags:"-framework AppKit -framework IOKit -framework CoreWLAN -framework ScreenCaptureKit -framework QuartzCore -framework CoreMedia -framework CoreVideo"

echo "built ./wm"
