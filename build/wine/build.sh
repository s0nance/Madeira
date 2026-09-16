#!/bin/bash
# Configure and build the two Wine trees every other build script depends on.
#
#   wine/build-macos     --enable-archs=aarch64   -> aarch64-windows
#   wine/build-arm64ec   --enable-archs=arm64ec   -> arm64ec-windows (+ x86_64-windows)
#
# WHY THIS EXISTS: these two trees were prerequisites of literally every
# script in build/ (each one does -include "$WINE_BUILD/include/config.h")
# and the invocation that produced them was committed NOWHERE -- not in this
# repo, not in the wine fork, not in any commit message, not in the history.
# A fresh clone could not get past step one. The two configure lines below
# are the ones verified working on 2026-09-16 (Xcode 27 / iPhoneOS 27.0 SDK,
# llvm-mingw 20260421, bison 3.8.2).
#
# Who consumes what:
#   build-macos    include/config.h + generated headers -> ntdll-unix,
#                  win32u-unix, wineserver
#                  tools/winebuild/winebuild, dlls/ntdll/aarch64-windows/
#                  libntdll.a, libs+dlls/winecrt0/aarch64-windows/,
#                  dlls/dbghelp/aarch64-windows/ -> DXMT's winemetal
#                  (research/dxmt/src/winemetal/meson.build, via
#                  -Dwine_build_path)
#   build-arm64ec  include/ -> the widl-generated dwrite.h/dwrite_3.h that
#                  ntdll-unix's dwrite unixlib includes; the ARM64EC PE
#                  modules; xtajit64 (FEX's entry point, enabled for
#                  arm64ec by default -- wine/configure.ac:2388)
#
# NOT `make all`. The host-side .so files are deliberately never built:
#   - Nothing on the iOS path consumes them. The app compiles its OWN unix
#     halves (build/ntdll-unix, build/win32u-unix, build/wineserver).
#   - dlls/win32u/win32u.so does not LINK on a macOS host. The srcwatch
#     probes in dlls/win32u/dibdrv/bitblt.c:1038-1066 declare three
#     iOS-only externs (ios_srcwatch_arm, ios_srcwatch_arm_geom,
#     winios_dump_srcbits) that only Madeira.app defines, and the `if
#     (winios_dump_srcbits)` guards around them cannot help: a plain
#     `extern void f()` is never NULL, so the linker demands the symbol
#     regardless. Declaring them __attribute__((weak)) in the fork would
#     make those guards real and let `make all` work -- worth doing, but
#     it is a change to the wine submodule, not to this build.
#   - Skipping them also cuts most of the build time.
#
# Usage: ./build.sh [macos|arm64ec|all] [--reconfigure]
set -eu

BUILD_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$BUILD_DIR/../.." && pwd)"
WINE_SRC="$REPO_ROOT/wine"
MINGW="$REPO_ROOT/toolchains/llvm-mingw-20260421-ucrt-macos-universal/bin"
JOBS=$(sysctl -n hw.ncpu)

TARGET="${1:-all}"
RECONFIGURE=0
for a in "$@"; do [ "$a" = "--reconfigure" ] && RECONFIGURE=1; done

# bison 3 must come FIRST: macOS ships bison 2.3 at /usr/bin and Wine
# rejects anything below 3.0 (wine/configure.ac:265). llvm-mingw must be on
# PATH for the build too, not just for configure -- the generated Makefile
# records the PE compilers by BARE NAME (arm64ec_CC = arm64ec-w64-mingw32-clang),
# so they are resolved from PATH at compile time.
export PATH="/opt/homebrew/opt/bison/bin:$MINGW:$PATH"
# Deliberately NOT adding /opt/homebrew/opt/llvm/bin here. The unix side is
# built with `CC = gcc` -> /usr/bin/gcc -> Apple clang, which is what
# configure probed. Homebrew's LLVM is needed only by
# build/wineserver/build.sh, for llvm-objcopy.

preflight() {
    [ -f "$WINE_SRC/configure" ] || {
        echo "ERROR: $WINE_SRC/configure missing -- run"
        echo "       git submodule update --init --recursive"
        exit 1
    }
    local bison_ver
    bison_ver=$(bison --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+' | head -1)
    case "$bison_ver" in
        ""|2.*|1.*)
            echo "ERROR: bison $bison_ver is too old (Wine needs >= 3.0)."
            echo "       brew install bison  -- it is keg-only, which is why"
            echo "       this script puts /opt/homebrew/opt/bison/bin first."
            exit 1
            ;;
    esac
    local missing=""
    for t in aarch64-w64-mingw32-clang arm64ec-w64-mingw32-clang x86_64-w64-mingw32-gcc; do
        command -v "$t" >/dev/null || missing="$missing $t"
    done
    [ -z "$missing" ] || {
        echo "ERROR: missing PE compilers:$missing"
        echo "       expected llvm-mingw at $MINGW"
        exit 1
    }
    echo "  bison $bison_ver, llvm-mingw OK, -j$JOBS"
}

# $1 = tree suffix (macos|arm64ec), $2... = configure args.
# The make targets come from the TARGETS array, set by the caller.
build_tree() {
    local name=$1; shift
    local tree="$WINE_SRC/build-$name"
    echo ""
    echo "=== wine/build-$name ==="
    mkdir -p "$tree"
    if [ $RECONFIGURE -eq 1 ] || [ ! -f "$tree/include/config.h" ]; then
        echo "  configuring: ../configure $*"
        ( cd "$tree" && ../configure "$@" > configure.log 2>&1 ) || {
            echo "  configure FAILED -- tail of $tree/configure.log:"
            tail -20 "$tree/configure.log"
            exit 1
        }
        # The "not found" lines in configure.log are expected and harmless
        # here: Wayland, ALSA, PulseAudio, GStreamer, v4l2, libudev,
        # Vulkan/MoltenVK. None of them are on the iOS path -- audio goes
        # through build/ntdll-unix/audio_null_ios.c and graphics through
        # DXMT/Metal.
        echo "  configure OK"
    else
        echo "  already configured (--reconfigure to redo)"
    fi
    echo "  building: ${TARGETS[*]}"
    make -C "$tree" -j"$JOBS" "${TARGETS[@]}" > "$tree/build.log" 2>&1 || {
        echo "  make FAILED -- errors from $tree/build.log:"
        grep -iE "error:|Error [0-9]|Undefined symbols" "$tree/build.log" | head -20
        exit 1
    }
    echo "  make OK"
}

# Verify by content rather than by exit status: name the artefacts the other
# build scripts actually open, so a tree that built "successfully" without
# producing them fails HERE and not three scripts later.
verify_macos() {
    local tree="$WINE_SRC/build-macos" bad=""
    for f in include/config.h tools/winebuild/winebuild \
             dlls/ntdll/aarch64-windows/libntdll.a; do
        [ -e "$tree/$f" ] || bad="$bad $f"
    done
    [ -z "$bad" ] || { echo "ERROR: build-macos is missing:$bad"; exit 1; }
    echo "  build-macos artefacts OK"
}

verify_arm64ec() {
    local tree="$WINE_SRC/build-arm64ec" bad=""
    for f in include/config.h include/dwrite.h include/dwrite_3.h; do
        [ -e "$tree/$f" ] || bad="$bad $f"
    done
    [ -z "$bad" ] || { echo "ERROR: build-arm64ec is missing:$bad"; exit 1; }
    echo "  build-arm64ec artefacts OK"
}

# build-macos: the host tools, every widl-generated header, and the three
# aarch64-windows import libraries DXMT's winemetal links against
# (research/dxmt/src/winemetal/meson.build:19-25).
MACOS_TARGETS=(
    tools/winebuild/winebuild
    include/all
    dlls/ntdll/aarch64-windows/libntdll.a
    dlls/dbghelp/aarch64-windows/libdbghelp.a
    libs/winecrt0/aarch64-windows/libwinecrt0.a
)
# build-arm64ec: the app build needs only the generated headers from here --
# dwrite.h/dwrite_3.h, which exist in NO other tree and which
# build/ntdll-unix's dwrite unixlib includes. The ARM64EC PE modules
# themselves are committed under app/Madeira/arm64ec-windows/; rebuilding
# them is a separate job (make -C dlls/ntdll, then strip + pad).
ARM64EC_TARGETS=(
    include/all
)

echo "=== Wine trees for Madeira ==="
preflight

case "$TARGET" in
    macos)
        TARGETS=("${MACOS_TARGETS[@]}")
        build_tree macos --enable-archs=aarch64 --disable-tests --without-x
        verify_macos
        ;;
    arm64ec)
        TARGETS=("${ARM64EC_TARGETS[@]}")
        build_tree arm64ec --enable-archs=arm64ec --disable-tests --without-x
        verify_arm64ec
        ;;
    all|--reconfigure)
        TARGETS=("${MACOS_TARGETS[@]}")
        build_tree macos --enable-archs=aarch64 --disable-tests --without-x
        verify_macos
        TARGETS=("${ARM64EC_TARGETS[@]}")
        build_tree arm64ec --enable-archs=arm64ec --disable-tests --without-x
        verify_arm64ec
        ;;
    *)
        echo "usage: $0 [macos|arm64ec|all] [--reconfigure]"
        exit 1
        ;;
esac

echo ""
echo "Done. Next: build/gnutls-ios, build/freetype-ios, then"
echo "build/ntdll-unix, build/win32u-unix, build/wineserver, build/dxmt-ios."
