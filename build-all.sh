#!/bin/bash
# Build everything Madeira.app links, in dependency order, from a fresh clone.
#
# Each stage is a script under build/ that verifies its own output by content;
# this file only encodes the ORDER and the prerequisites, which until now
# existed nowhere. Run it whole, or resume at a stage with --from <name>.
#
#   ./build-all.sh                 every stage
#   ./build-all.sh --from dxmt     that stage and everything after
#   ./build-all.sh --only wine     that stage alone
#   ./build-all.sh --list          stage names, in order
#
# Not included: the ARM64EC PE modules and the aarch64-windows DLLs. Those are
# committed under app/Madeira/{arm64ec,aarch64}-windows and rebuilding them is
# a separate chain (meson for DXMT's PE side, `make -C dlls/ntdll` plus strip
# and pad for the EC ntdll). Nor the Microsoft VC++ runtime, which is not ours
# to fetch -- see tools/fetch-vcruntime.md.
set -eu

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$REPO_ROOT"

MINGW_VER=llvm-mingw-20260421-ucrt-macos-universal
MINGW="$REPO_ROOT/toolchains/$MINGW_VER/bin"
FREETYPE_TAG=VER-2-13-3

# Ordered. Each entry is "name:script-or-function:one-line description".
STAGES=(
    "mingw:stage_mingw:llvm-mingw toolchain (PE compilers)"
    "freetype-src:stage_freetype_src:freetype $FREETYPE_TAG clone"
    "dxmt-link:stage_dxmt_link:toolchains symlink for DXMT's meson cross files"
    "wine:build/wine/build.sh:Wine trees (build-macos + build-arm64ec)"
    "gnutls:build/gnutls-ios/build.sh:GMP, nettle, GnuTLS for iOS"
    "freetype:build/freetype-ios/build.sh:freetype for iOS"
    "llvm:build/llvm-ios/build.sh:LLVM 15.0.7 for iOS"
    "ntdll:build/ntdll-unix/build.sh:libntdll_unix.a"
    "win32u:build/win32u-unix/build.sh:libwin32u_unix.a"
    "wineserver:build/wineserver/build.sh:libwineserver.a"
    "fex:build/fex-ios/build.sh:FEXCore for iOS"
    "dxmt:build/dxmt-ios/build.sh:libdxmt_combined.a"
)

stage_mingw() {
    if [ -x "$MINGW/aarch64-w64-mingw32-clang" ]; then
        echo "  already present"
        return
    fi
    mkdir -p toolchains
    echo "  downloading $MINGW_VER (~116 MB)"
    curl -fL "https://github.com/mstorsjo/llvm-mingw/releases/download/20260421/$MINGW_VER.tar.xz" \
        | tar -xJ -C toolchains/
    [ -x "$MINGW/aarch64-w64-mingw32-clang" ] || {
        echo "  ERROR: extraction did not produce $MINGW"; exit 1; }
    echo "  OK"
}

stage_freetype_src() {
    if [ -d research/freetype ]; then
        echo "  already present"
        return
    fi
    git clone --depth 1 --branch "$FREETYPE_TAG" \
        https://github.com/freetype/freetype.git research/freetype
    echo "  OK"
}

stage_dxmt_link() {
    # DXMT's meson cross files reference @GLOBAL_SOURCE_ROOT@/toolchains/...,
    # which resolves inside the submodule rather than here.
    if [ -e research/dxmt/toolchains ]; then
        echo "  already present"
        return
    fi
    ln -s ../../toolchains research/dxmt/toolchains
    echo "  OK"
}

# ---------------------------------------------------------------- preflight

preflight() {
    local fatal=0
    echo "=== Preflight ==="

    if [ ! -f wine/configure ] || [ ! -f FEX/CMakeLists.txt ] || [ ! -f research/dxmt/meson.build ]; then
        echo "  submodules: MISSING -- run git submodule update --init --recursive"
        fatal=1
    else
        echo "  submodules: OK"
    fi

    xcrun --sdk iphoneos --show-sdk-path > /dev/null 2>&1 \
        && echo "  iPhoneOS SDK: $(xcrun --sdk iphoneos --show-sdk-version)" \
        || { echo "  iPhoneOS SDK: MISSING -- install Xcode and run xcode-select"; fatal=1; }

    # DXMT compiles .metal shaders to AIR. The toolchain is a separate download.
    if xcodebuild -showComponent MetalToolchain 2>/dev/null | grep -q "installed"; then
        echo "  Metal toolchain: OK"
    else
        echo "  Metal toolchain: MISSING -- xcodebuild -downloadComponent MetalToolchain"
        fatal=1
    fi

    # bison >= 3: macOS ships 2.3 and Wine rejects it (wine/configure.ac:265).
    # build/wine/build.sh puts the Homebrew one first itself, so only its
    # presence is checked here, not the PATH order.
    if [ -x /opt/homebrew/opt/bison/bin/bison ] || \
       { command -v bison > /dev/null && ! bison --version | head -1 | grep -qE ' (1|2)\.'; }; then
        echo "  bison >= 3: OK"
    else
        echo "  bison >= 3: MISSING -- brew install bison"
        fatal=1
    fi

    # llvm-objcopy: build/wineserver/build.sh renames the symbols that collide
    # with win32u in the single-process link.
    # Both locations are accepted because that script looks in both. Checking
    # only that the file exists somewhere would be the wrong test -- an early
    # version of this preflight did exactly that, reported OK, and the
    # wineserver stage then died on "llvm-objcopy not found" because Homebrew's
    # LLVM is keg-only and was not on PATH.
    if command -v llvm-objcopy > /dev/null || [ -x /opt/homebrew/opt/llvm/bin/llvm-objcopy ]; then
        echo "  llvm-objcopy: OK"
    else
        echo "  llvm-objcopy: MISSING -- brew install llvm"
        fatal=1
    fi

    for t in cmake ninja git curl; do
        command -v "$t" > /dev/null && echo "  $t: OK" \
            || { echo "  $t: MISSING"; fatal=1; }
    done

    # Needed only to rebuild DXMT's PE side, which this script does not do.
    command -v meson > /dev/null && echo "  meson: OK (PE side only)" \
        || echo "  meson: absent -- fine unless you rebuild DXMT's PE modules"

    # Not fatal: the app links without it, but any MSVC-built game will fail
    # to start, and xcodebuild warns about the missing resource directory.
    local n=0
    [ -d app/Madeira/x86_64-vcruntime ] && \
        n=$(find app/Madeira/x86_64-vcruntime -name '*.dll' | wc -l | tr -d ' ')
    if [ "$n" = "12" ]; then
        echo "  vcruntime: OK (12 DLLs)"
    else
        echo "  vcruntime: $n/12 DLLs -- see tools/fetch-vcruntime.md"
        echo "             (not fatal here; MSVC-built games need them at runtime)"
    fi

    [ $fatal -eq 0 ] || { echo ""; echo "Preflight failed."; exit 1; }
}

# ---------------------------------------------------------------- driver

usage() {
    echo "usage: $0 [--from <stage>] [--only <stage>] [--list]"
    echo ""
    echo "stages, in order:"
    for s in "${STAGES[@]}"; do
        local n="${s%%:*}" rest="${s#*:}"
        printf "  %-14s %s\n" "$n" "${rest#*:}"
    done
}

FROM=""
ONLY=""
while [ $# -gt 0 ]; do
    case "$1" in
        --from) FROM="${2:?--from needs a stage name}"; shift 2 ;;
        --only) ONLY="${2:?--only needs a stage name}"; shift 2 ;;
        --list|-l) usage; exit 0 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown argument: $1"; usage; exit 1 ;;
    esac
done

stage_exists() {
    local s
    for s in "${STAGES[@]}"; do [ "${s%%:*}" = "$1" ] && return 0; done
    return 1
}
for n in $FROM $ONLY; do
    stage_exists "$n" || { echo "no such stage: $n"; usage; exit 1; }
done

preflight

STARTED=$([ -n "$FROM" ] && echo 0 || echo 1)
RUN=0
SECONDS=0
for entry in "${STAGES[@]}"; do
    name="${entry%%:*}"
    rest="${entry#*:}"
    action="${rest%%:*}"
    desc="${rest#*:}"

    [ -n "$ONLY" ] && [ "$name" != "$ONLY" ] && continue
    if [ -n "$FROM" ] && [ "$STARTED" = "0" ]; then
        [ "$name" = "$FROM" ] && STARTED=1 || continue
    fi

    echo ""
    echo "################ $name -- $desc"
    t0=$SECONDS
    if [ "${action#stage_}" != "$action" ]; then
        "$action"
    else
        "$REPO_ROOT/$action"
    fi
    echo "################ $name OK ($((SECONDS - t0))s)"
    RUN=$((RUN + 1))
done

echo ""
echo "=== $RUN stage(s) in $((SECONDS / 60))m$((SECONDS % 60))s ==="

# Only meaningful after a full run.
if [ -z "$ONLY" ]; then
    echo ""
    echo "=== What Madeira.app links ==="
    ok=1
    for l in libntdll_unix.a libwineserver.a libwin32u_unix.a libdxmt_combined.a; do
        if [ -f "app/Madeira/$l" ]; then
            printf "  %-22s %10d bytes\n" "$l" "$(wc -c < "app/Madeira/$l")"
        else
            printf "  %-22s MISSING\n" "$l"; ok=0
        fi
    done
    for l in FEXCore/Source/libFEXCore.a FEXCore/Source/libFEXCore_Base.a \
             FEXCore/Source/libJemallocLibs.a External/fmt/libfmt.a \
             External/cephes/libcephes_128bit.a \
             External/xxhash/cmake_unofficial/libxxhash.a \
             External/SoftFloat-3e/libsoftfloat_3e.a; do
        [ -f "FEX/build-ios/$l" ] || { printf "  %-22s MISSING\n" "$l"; ok=0; }
    done
    [ $ok -eq 1 ] && echo "  FEX/build-ios          7 archives" || exit 1

    echo ""
    echo "Next: build the app."
    echo "  xcodebuild -project app/Madeira.xcodeproj -scheme Madeira \\"
    echo "    -configuration Release -destination 'generic/platform=iOS' build"
    echo ""
    echo "Signing needs your own team and a bundle id under your own prefix;"
    echo "add CODE_SIGNING_ALLOWED=NO to check the link without signing."
fi
