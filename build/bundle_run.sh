#!/usr/bin/env bash

# Get the directory of this script (MacOS directory)
SCRIPT_DIR="$(dirname "$0")"

# Determine the directory containing the .app bundle
APP_DIR="$(cd "$SCRIPT_DIR/../../" && pwd)"

# Define the path to the app executable relative to the MacOS directory.
# Prefer the universal (x86_64 + arm64) binary; fall back to per-arch names.
APP_EXEC=""
for candidate in Ikemen_GO_MacOS_universal Ikemen_GO_MacOSARM Ikemen_GO_MacOS; do
    if [ -x "$SCRIPT_DIR/$candidate" ]; then
        APP_EXEC="$SCRIPT_DIR/$candidate"
        break
    fi
done

# Output for debugging
echo "SCRIPT_DIR: $SCRIPT_DIR"
echo "APP_DIR: $APP_DIR"
echo "APP_EXEC: $APP_EXEC"

if [ -z "$APP_EXEC" ]; then
    echo "Executable not found or not executable in $SCRIPT_DIR." >&2
    exit 1
fi

# Change directory to the parent directory of the .app bundle
cd "$APP_DIR/../" || {
    echo "Failed to change directory to $APP_DIR/../"
    exit 1
}

# Output the current working directory for debugging
echo "Current working directory: $(pwd)"

# Launch the macOS app executable
"$APP_EXEC" "$@" -AppleMagnifiedMode YES