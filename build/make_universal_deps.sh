#!/usr/bin/env bash
# make_universal_deps.sh — build a universal (x86_64 + arm64) dependency prefix
# for the macOS app bundle. See _agent/PLAN_P03_01.md (Phase 3).
#
# The local Homebrew install (/usr/local, x86_64) uses ABSOLUTE install names
# (not @rpath), so a portable app must bundle the full runtime closure and
# rewrite every install name / reference to @rpath. This script:
#   1. computes the non-system dylib closure of FFmpeg + libxmp + SDL2/SDL3
#      + MoltenVK (otool -L, recursive),
#   2. downloads the matching arm64_sequoia Homebrew bottle for each formula,
#   3. lipo's local x86_64 + bottle arm64 slices into universal dylibs,
#   4. rewrites install names and cross-references to @rpath/<basename>,
#   5. emits pkg-config files + C headers for a self-contained prefix,
#   6. ad-hoc codesigns and verifies every artifact.
#
# Output:
#   build/universal-deps/lib/*.dylib        universal dylibs (@rpath ids)
#   build/universal-deps/lib/pkgconfig/*.pc libav*, libxmp, sdl2, sdl3
#   build/universal-deps/include/...        C headers (ffmpeg/libxmp/sdl2/sdl3)
#
# Usage: bash build/make_universal_deps.sh [--force]   (DEBUG=1 for trace)

set -euo pipefail
[[ "${DEBUG:-0}" == "1" ]] && set -x

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEPS="$REPO_ROOT/build/universal-deps"
BOTTLES="$DEPS/bottles"
LIBOUT="$DEPS/lib"
PCOUT="$DEPS/lib/pkgconfig"
INCOUT="$DEPS/include"

log() { printf '==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

FORCE=0
[[ "${1:-}" == "--force" ]] && FORCE=1

if [[ $FORCE -eq 1 ]]; then
	rm -rf "$DEPS"
fi
mkdir -p "$BOTTLES" "$LIBOUT" "$PCOUT" "$INCOUT"

# Verification-only path when reusing an existing prefix.
verify_only() {
	log "Verifying..."
	local fail=0 d archs
	for d in "$LIBOUT"/*; do
		[[ -f "$d" && ! -L "$d" ]] || continue
		archs="$(lipo -info "$d" 2>/dev/null || true)"
		if [[ "$archs" != *"x86_64"* || "$archs" != *"arm64"* ]]; then
			echo "BAD ARCH: $d ($archs)" >&2; fail=1
		fi
		if otool -L "$d" | awk 'NR > 1 { print $1 }' | grep -q '^/usr/local'; then
			echo "UNREWRITTEN /usr/local REF in: $d" >&2; fail=1
		fi
	done
	[[ $fail -eq 0 ]] || die "verification failed"
	log "OK: $(ls "$LIBOUT" | grep -cv '^\.' ) files in $LIBOUT (all universal, @rpath-only)."
}

if compgen -G "$LIBOUT/*.dylib" > /dev/null; then
	log "Reusing existing $DEPS (pass --force to rebuild)."
	verify_only
	exit 0
fi

# ---------------------------------------------------------------------------
# 1. Runtime closure (realpaths of every non-system dylib we must bundle)
# ---------------------------------------------------------------------------
log "Computing runtime dylib closure (otool -L, recursive)..."
CLOSURE_LIST="$(mktemp)"
trap 'rm -f "$CLOSURE_LIST"' EXIT
python3 - "$CLOSURE_LIST" <<'PYEOF'
import subprocess, os, collections, sys

def deps(path):
    r = subprocess.run(["otool", "-L", path], capture_output=True, text=True)
    return [l.strip().split()[0] for l in r.stdout.splitlines()[1:] if l.strip()]

roots = ["/usr/local/opt/ffmpeg/lib/%s.dylib" % n for n in
         ["libavcodec.63", "libavformat.63", "libavutil.61",
          "libswscale.10", "libswresample.7", "libavfilter.12"]]
roots += ["/usr/local/lib/libxmp.4.dylib",
          "/usr/local/opt/sdl2-compat/lib/libSDL2-2.0.0.dylib",
          "/usr/local/lib/libSDL3.0.dylib",
          "/usr/local/lib/libMoltenVK.dylib"]

seen, queue, order = set(), collections.deque(roots), []
while queue:
    p = queue.popleft()
    rp = os.path.realpath(p)
    if rp in seen:
        continue
    seen.add(rp)
    order.append(rp)
    for d in deps(p):
        if d.startswith("/usr/local"):
            queue.append(d)

with open(sys.argv[1], "w") as out:
    for p in order:
        out.write(p + "\n")
PYEOF
CLOSURE=()
while IFS= read -r line; do CLOSURE+=("$line"); done < "$CLOSURE_LIST"
log "Closure: ${#CLOSURE[@]} dylibs."

formula_of() { # realpath -> Homebrew formula name
	local p="$1"
	[[ "$p" == */Cellar/* ]] || die "cannot map formula for $p"
	local rest="${p#*/Cellar/}"
	echo "${rest%%/*}"
}

FORMULA_LIST="$(for p in "${CLOSURE[@]}"; do formula_of "$p"; done | sort -u)"

# ---------------------------------------------------------------------------
# 2. Download + extract arm64_sequoia bottles (version-checked)
# ---------------------------------------------------------------------------
for f in $FORMULA_LIST; do
	dest="$BOTTLES/$f"
	if [[ -n "$(find "$dest" -maxdepth 2 -type d -name lib 2>/dev/null | head -1)" ]]; then
		log "Bottle present: $f (skipping download)"
		continue
	fi
	json="$(curl -fsSL "https://formulae.brew.sh/api/formula/$f.json")"
	url="$(jq -r '.bottle.stable.files.arm64_sequoia.url' <<<"$json")"
	sha="$(jq -r '.bottle.stable.files.arm64_sequoia.sha256' <<<"$json")"
	[[ "$url" != "null" && -n "$sha" ]] || die "no arm64_sequoia bottle for $f"
	log "Downloading bottle: $f ($url)"
	# ghcr.io requires a pull token; formula "openssl@4" lives in repo
	# "homebrew/core/openssl/4" (@ maps to /).
	repo="homebrew/core/${f//@//}"
	token="$(curl -fsSL "https://ghcr.io/token?scope=repository:$repo:pull" | jq -r .token)"
	[[ "$token" != "null" && -n "$token" ]] || die "could not get ghcr token for $f ($repo)"
	curl -fsSL -H "Authorization: Bearer $token" "$url" -o "$dest.tar.zst"
	[[ "$(shasum -a 256 "$dest.tar.zst" | awk '{print $1}')" == "$sha" ]] \
		|| die "sha256 mismatch for $f bottle"
	mkdir -p "$dest"
	zstd -dc "$dest.tar.zst" | tar -x -C "$dest"
	rm -f "$dest.tar.zst"
done

# ---------------------------------------------------------------------------
# 3. lipo local x86_64 + bottle arm64 -> universal dylibs
# ---------------------------------------------------------------------------
log "Creating universal dylibs (lipo)..."
for p in "${CLOSURE[@]}"; do
	f="$(formula_of "$p")"
	base="$(basename "$p")"
	arm64_src="$(find "$BOTTLES/$f" -type f -name "$base" | head -1)"
	[[ -n "$arm64_src" ]] || die "arm64 copy of $base not found in $f bottle"
	lipo -create "$p" "$arm64_src" -output "$LIBOUT/$base"
done

# Recreate the bottle's lib/ symlink structure (needed for -l<name> at link
# time). Two passes: some links chain through other links (libSDL2.dylib ->
# libSDL2-2.0.dylib -> libSDL2-2.0.0.dylib).
for pass in 1 2; do
	for f in $FORMULA_LIST; do
		libdir="$(find "$BOTTLES/$f" -type d -name lib | head -1)"
		[[ -n "$libdir" ]] || continue
		while IFS= read -r link; do
			target="$(readlink "$link")"
			[[ -e "$LIBOUT/$(basename "$target")" ]] || continue
			ln -sf "$target" "$LIBOUT/$(basename "$link")"
		done < <(find "$libdir" -maxdepth 1 -type l)
	done
done

# ---------------------------------------------------------------------------
# 4. Rewrite install names + cross-references to @rpath/<basename>
# ---------------------------------------------------------------------------
log "Rewriting install names and references to @rpath..."
for d in "$LIBOUT"/*; do
	[[ -f "$d" && ! -L "$d" ]] || continue
	base="$(basename "$d")"
	install_name_tool -id "@rpath/$base" "$d"
	while IFS= read -r dep; do
		[[ "$dep" == /usr/local/* ]] || continue
		target="$(realpath "$dep")"
		grep -qxF "$target" "$CLOSURE_LIST" || continue
		install_name_tool -change "$dep" "@rpath/$(basename "$target")" "$d"
	done < <(otool -L "$d" | awk 'NR > 1 { print $1 }')
done

# ---------------------------------------------------------------------------
# 5. pkg-config files + headers for a self-contained prefix
# ---------------------------------------------------------------------------
log "Writing pkg-config files and extracting headers..."
rewrite_pc() { # $1=src  $2=dst
	sed -e "s|^prefix=.*|prefix=$DEPS|" \
	    -e "s|^exec_prefix=.*|exec_prefix=\${prefix}|" \
	    -e "s|^libdir=.*|libdir=\${prefix}/lib|" \
	    -e "s|^includedir=.*|includedir=\${prefix}/include|" \
	    "$1" > "$2"
}
for pc in libavcodec libavformat libavutil libswscale libswresample libavfilter; do
	rewrite_pc "/usr/local/opt/ffmpeg/lib/pkgconfig/$pc.pc" "$PCOUT/$pc.pc"
done
rewrite_pc "/usr/local/opt/libxmp/lib/pkgconfig/libxmp.pc" "$PCOUT/libxmp.pc"
rewrite_pc "/usr/local/opt/sdl2-compat/lib/pkgconfig/sdl2.pc" "$PCOUT/sdl2.pc"
rewrite_pc "/usr/local/opt/sdl3/lib/pkgconfig/sdl3.pc" "$PCOUT/sdl3.pc"

for f in ffmpeg libxmp sdl2-compat sdl3; do
	inc="$(find "$BOTTLES/$f" -type d -name include | head -1)"
	[[ -n "$inc" ]] && cp -R "$inc/." "$INCOUT/"
done

# ---------------------------------------------------------------------------
# 6. Codesign (install_name_tool invalidates signatures; arm64 slices require one)
# ---------------------------------------------------------------------------
log "Ad-hoc codesigning..."
codesign --force --sign - "$LIBOUT"/* 2>/dev/null || true

# ---------------------------------------------------------------------------
# 7. Verify
# ---------------------------------------------------------------------------
verify_only
