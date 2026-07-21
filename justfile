# niri-mac task runner.
# Run `just` (or `just --list`) to see all recipes.
# Tip: run `just build` once; the ./wm wrappers below don't rebuild on their own.

# Show available recipes
default:
    @just --list

# --- build / check / test ---------------------------------------------------

# Compile the AppKit shim + the Odin app -> ./wm
build:
    ./build.sh

# Compile just the Objective-C shim (macos/screens.o)
shim:
    clang -c -fobjc-arc -o macos/screens.o macos/screens.m

# Type-check the whole program without producing a binary
check: shim
    odin check .

# Run the unit tests (pure layout engine + daemon tick decisions)
test: shim
    odin test layout
    odin test .

# Remove build artifacts
clean:
    rm -f wm macos/screens.o

# Clean, then build
rebuild: clean build

# --- running ----------------------------------------------------------------

# Run ./wm with arbitrary args, e.g. `just run snap left`
run *ARGS:
    ./wm {{ARGS}}

# Enumerate all on-screen windows (CGWindowList + AX)
list:
    ./wm list

# Show the focused window and the display it sits on
focused:
    ./wm focused

# List displays and their usable (visibleFrame) areas
displays:
    ./wm displays

# Snap focused window. PRESET: maximize|center|left|right|top|bottom|tl|tr|bl|br|l3|c3|r3|l23|r23
snap PRESET:
    ./wm snap {{PRESET}}

# Maximize the focused window
maximize:
    ./wm maximize

# Center the focused window at 60%
center:
    ./wm center

# Move the focused window to another display (DIR: next|prev)
move-monitor DIR="next":
    ./wm move-monitor {{DIR}}

# Demo: move/resize/maximize/park/restore a window (default TextEdit)
poke APP="TextEdit":
    ./wm poke {{APP}}

# Visualize the niri scrollable-strip engine in the terminal (moves nothing)
strip-demo:
    ./wm strip-demo

# Run the window-manager daemon in the foreground (Ctrl-C to stop)
daemon:
    ./wm daemon

# Run the daemon DETACHED (survives closing this terminal); logs to /tmp/niri-mac.log
daemon-bg: build
    nohup {{justfile_directory()}}/wm daemon >/tmp/niri-mac.log 2>&1 &
    @sleep 1; echo "daemon detached. attach with: just state | just logs ; stop: wm stop"

# Follow the (detached/service) daemon's output
logs:
    tail -f /tmp/niri-mac.log

# Install a login LaunchAgent so the daemon runs headless and starts at login
service-install: build
    #!/usr/bin/env bash
    set -euo pipefail
    plist="$HOME/Library/LaunchAgents/com.niri-mac.wm.plist"
    printf '%s\n' \
      '<?xml version="1.0" encoding="UTF-8"?>' \
      '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
      '<plist version="1.0"><dict>' \
      '<key>Label</key><string>com.niri-mac.wm</string>' \
      '<key>ProgramArguments</key><array>' \
      "<string>{{justfile_directory()}}/wm</string><string>daemon</string>" \
      '</array>' \
      '<key>RunAtLoad</key><true/>' \
      '<key>StandardOutPath</key><string>/tmp/niri-mac.log</string>' \
      '<key>StandardErrorPath</key><string>/tmp/niri-mac.log</string>' \
      '</dict></plist>' > "$plist"
    launchctl bootout "gui/$(id -u)/com.niri-mac.wm" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$plist"
    echo "service installed + started (logs: just logs). NOTE: grant 'wm' itself"
    echo "Accessibility + Input Monitoring if hotkeys/AX don't work under launchd."

# Stop + remove the LaunchAgent
service-uninstall:
    -launchctl bootout "gui/$(id -u)/com.niri-mac.wm"
    rm -f "$HOME/Library/LaunchAgents/com.niri-mac.wm.plist"
    @echo "service uninstalled"

# Restart the service (after a rebuild)
service-restart: service-uninstall service-install

# Build the strip from current windows (daemon must be running)
sync:
    ./wm sync

# Show the strip + the layout the effector would apply
state:
    ./wm state

# --- dev convenience --------------------------------------------------------

# Open a throwaway TextEdit window, WAIT until it is frontmost, then snap it.
# Guards against snapping whatever else is focused while TextEdit cold-starts.
demo-snap PRESET="left":
    #!/usr/bin/env bash
    set -euo pipefail
    touch /tmp/wm-canary.txt
    open -a TextEdit /tmp/wm-canary.txt
    for _ in $(seq 1 50); do
      if ./wm focused | grep -q wm-canary; then
        ./wm snap {{PRESET}}
        ./wm focused
        exit 0
      fi
      sleep 0.2
    done
    echo "TextEdit canary never became frontmost — aborting, nothing moved." >&2
    exit 1
