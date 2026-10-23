#!/usr/bin/env bash
# build_macos.sh — build Intel (x86_64), ARM (arm64) and/or universal macOS
# binaries + app bundles for Ikemen-GO. See _agent/PLAN_P03_01.md and
# _agent/MOP_BUILD_MACOS.md.
#
# Usage:
#   bash build/build_macos.sh intel       # x86_64 only  -> bin/Ikemen_GO_MacOS
#   bash build/build_macos.sh arm         # arm64 only   -> bin/Ikemen_GO_MacOSARM
#   bash build/build_macos.sh universal   # both + lipo  -> bin/Ikemen_GO_MacOS_universal
#   bash build/build_macos.sh all         # intel + arm bundles, final = universal
#   append --deploy to also copy I.K.E.M.E.N-Go.app into ../Ikemen_GO_game/
#
# MOP (what it does, in order):
#   1. Ensure build/universal-deps/ exists (build/make_universal_deps.sh;
#      first run downloads the arm64 bottles, ~5 min).
#   2. Refresh lib/ with the universal dylibs (they get bundled into
#      Contents/Frameworks and linked via @rpath).
#   3. Build each requested slice with build/build.sh: BUILD_FFMPEG=no,
#      pkg-config from the universal prefix, rpaths prepended so
#      @executable_path/../Frameworks wins over /usr/local/lib.
#   4. universal mode: lipo the two slices, ad-hoc sign.
#   5. make appbundle + deep ad-hoc codesign (required on Apple Silicon).
#   6. Verify: archs present, no /usr/local refs left in the binary.
#   7. --deploy: move the previous game-folder app aside (timestamped),
#      copy the new one in.
#
# Env: DEBUG=1 for trace; APP_VERSION overrides the version string (default 1.0.0).

set -euo pipefail
[[ "${DEBUG:-0}" == "1" ]] && set -x

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

DEPS="$REPO_ROOT/build/universal-deps"
LIBOUT="$DEPS/lib"
GAME_DIR="$(cd "$REPO_ROOT/.." && pwd)/Ikemen_GO_game"

log() { printf '==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

MODE="${1:-universal}"
DEPLOY=0
[[ "${2:-}" == "--deploy" ]] && DEPLOY=1

case "$MODE" in
	intel|arm|universal|all) ;;
	*) die "usage: $0 {intel|arm|universal|all} [--deploy]" ;;
esac

# --- 0. toolchain -----------------------------------------------------------
command -v go >/dev/null 2>&1 || export PATH="/usr/local/go/bin:$PATH"
command -v go >/dev/null 2>&1 || die "go not found (expected /usr/local/go/bin)"
command -v lipo >/dev/null 2>&1 || die "lipo not found (install Xcode command line tools)"

# --- 1. universal dependency prefix -----------------------------------------
if ! compgen -G "$LIBOUT/*.dylib" > /dev/null; then
	log "Building universal dependency prefix (first run downloads bottles)..."
	bash "$REPO_ROOT/build/make_universal_deps.sh"
else
	log "Using existing universal dependency prefix."
fi

# --- 2. refresh lib/ (bundled into Contents/Frameworks) ----------------------
log "Refreshing lib/ from $LIBOUT"
mkdir -p lib
cp -Pf "$LIBOUT"/*.dylib* lib/

# --- 3. build one slice -------------------------------------------------------
build_slice() { # $1=arch (x86_64|arm64)  $2=build.sh target (MacOS|MacOSARM)
	local arch="$1" target="$2"
	log "Building $arch slice (this may take a while)..."
	BUILD_FFMPEG=no \
	PKG_CONFIG_PATH="$LIBOUT/pkgconfig" \
	CGO_LDFLAGS="-Wl,-rpath,@executable_path/../Frameworks -Wl,-rpath,@executable_path/../lib -L$LIBOUT" \
	CC="clang -target ${arch}-apple-macos15" CXX="clang++ -target ${arch}-apple-macos15" \
	bash build/build.sh "$target" | grep -vE '^ld: warning' || die "build failed for $arch"
}

# --- 4. app bundle + sign + verify -------------------------------------------
make_bundle() { # $1=BINNAME (e.g. bin/Ikemen_GO_MacOS_universal)
	local binname="$1" base
	base="$(basename "$binname")"
	log "Creating app bundle for $base..."
	make clean_appbundle appbundle BINNAME="$binname" > /dev/null
	codesign --force --deep --sign - I.K.E.M.E.N-Go.app > /dev/null
	local bin="I.K.E.M.E.N-Go.app/Contents/MacOS/$base"
	log "Binary archs: $(lipo -info "$bin" | sed 's/.*are: //')"
	if otool -L "$bin" | awk 'NR > 1 { print $1 }' | grep -q '^/usr/local'; then
		die "$base still references /usr/local paths (not portable)"
	fi
}

# --- 5. deploy -----------------------------------------------------------------
deploy_app() {
	[[ -d "$GAME_DIR" ]] || die "game folder not found: $GAME_DIR"
	local stamp; stamp="$(date +%Y%m%d-%H%M%S)"
	if [[ -d "$GAME_DIR/I.K.E.M.E.N-Go.app" ]]; then
		mv "$GAME_DIR/I.K.E.M.E.N-Go.app" "$GAME_DIR/I.K.E.M.E.N-Go.app-old-$stamp"
		log "Moved previous app to I.K.E.M.E.N-Go.app-old-$stamp"
	fi
	cp -Rf I.K.E.M.E.N-Go.app "$GAME_DIR/"
	log "Deployed to $GAME_DIR/I.K.E.M.E.N-Go.app"
}

# --- 6. modes -------------------------------------------------------------------
case "$MODE" in
	intel)
		build_slice x86_64 MacOS
		make_bundle bin/Ikemen_GO_MacOS
		;;
	arm)
		build_slice arm64 MacOSARM
		make_bundle bin/Ikemen_GO_MacOSARM
		;;
	universal)
		build_slice x86_64 MacOS
		build_slice arm64 MacOSARM
		log "Creating universal binary..."
		lipo -create bin/Ikemen_GO_MacOS bin/Ikemen_GO_MacOSARM \
			-output bin/Ikemen_GO_MacOS_universal
		codesign --force --sign - bin/Ikemen_GO_MacOS_universal > /dev/null
		make_bundle bin/Ikemen_GO_MacOS_universal
		;;
	all)
		build_slice x86_64 MacOS
		make_bundle bin/Ikemen_GO_MacOS
		cp -Rf I.K.E.M.E.N-Go.app I.K.E.M.E.N-Go.app-intel
		build_slice arm64 MacOSARM
		make_bundle bin/Ikemen_GO_MacOSARM
		cp -Rf I.K.E.M.E.N-Go.app I.K.E.M.E.N-Go.app-arm
		log "Creating universal binary..."
		lipo -create bin/Ikemen_GO_MacOS bin/Ikemen_GO_MacOSARM \
			-output bin/Ikemen_GO_MacOS_universal
		codesign --force --sign - bin/Ikemen_GO_MacOS_universal > /dev/null
		make_bundle bin/Ikemen_GO_MacOS_universal
		log "Bundles: I.K.E.M.E.N-Go.app (universal), -app-intel, -app-arm"
		;;
esac

[[ $DEPLOY -eq 1 ]] && deploy_app

log "Done. Test: open I.K.E.M.E.N-Go.app   (or: $GAME_DIR/I.K.E.M.E.N-Go.app if --deploy)"
