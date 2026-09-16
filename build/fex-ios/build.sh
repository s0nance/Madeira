#!/bin/bash
# Build FEXCore and its vendored dependencies as iOS-arm64 static libraries,
# for the seven archives Madeira.app links (see the LIBRARY_SEARCH_PATHS in
# app/Madeira.xcodeproj/project.pbxproj).
#
# WHY THIS EXISTS: the Xcode project pointed at FEX/build-ios/** for six
# libraries, and the cmake invocation that produced that directory was
# committed nowhere -- not in this repo, not in the FEX fork, not in any
# commit message. There is no toolchain_ios.cmake in FEX/Data/CMake either,
# only aarch64/mingw/x86. A fresh clone had no way to produce these.
#
# NOT the ARM64EC PE build. That one is a separate cross build via
# Data/CMake/toolchain_mingw.cmake and produces xtajit64.dll /
# libarm64ecfex.dll, shipped under app/Madeira/arm64ec-windows/. This build
# is the iOS-host side: FEXBridge.mm links it for fex_initialize(),
# fex_test_execute() and fex_get_jit_write_offset().
#
# Do NOT define FEX_IOS_HOST here. Despite the name it is the ARM64EC flag:
# the iOS code paths key off `defined(__APPLE__) || defined(FEX_IOS_HOST)`
# (FEXCore/include/FEXCore/Utils/DualMap.h:7), and the macro exists so the
# EC PE -- which has its own statically linked copy of FEXCore and no
# __APPLE__ -- gets them too. On this build __APPLE__ already does.
set -eu

BUILD_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$BUILD_DIR/../.." && pwd)"
FEX_SRC="$REPO_ROOT/FEX"
FEX_BUILD="$FEX_SRC/build-ios"
JOBS=$(sysctl -n hw.ncpu)

RECONFIGURE=0
for a in "$@"; do [ "$a" = "--reconfigure" ] && RECONFIGURE=1; done

# The archives the Xcode project links, as <path-under-build-ios>.
ARCHIVES=(
    FEXCore/Source/libFEXCore.a
    FEXCore/Source/libFEXCore_Base.a
    FEXCore/Source/libJemallocLibs.a
    External/fmt/libfmt.a
    External/cephes/libcephes_128bit.a
    External/xxhash/cmake_unofficial/libxxhash.a
    External/SoftFloat-3e/libsoftfloat_3e.a
)
TARGETS=(FEXCore FEXCore_Base JemallocLibs fmt cephes_128bit xxhash softfloat_3e)

[ -f "$FEX_SRC/CMakeLists.txt" ] || {
    echo "ERROR: $FEX_SRC/CMakeLists.txt missing -- run"
    echo "       git submodule update --init --recursive"
    exit 1
}

echo "=== FEXCore for iOS ==="
if [ $RECONFIGURE -eq 1 ] || [ ! -f "$FEX_BUILD/build.ninja" ]; then
    echo "  configuring..."
    # Every -D here is load-bearing:
    #
    # CMAKE_SYSTEM_PROCESSOR -- CMake does NOT set it for an iOS target, and
    #   CMakeLists.txt:89 does string(TOLOWER ${CMAKE_SYSTEM_PROCESSOR} ...)
    #   then requires a ^aarch64|^arm64 match. Without it the configure dies
    #   with "string no output variable specified" and "Unsupported processor
    #   type ." -- an empty processor, not a wrong one.
    #
    # TUNE_CPU=none -- the default is "native", which on arm64 runs
    #   Scripts/aarch64_fit_native.py against /proc/cpuinfo
    #   (CMakeLists.txt:507). There is no /proc on macOS, the script returns
    #   nothing, and string(STRIP) fails on the empty result. `none` skips the
    #   whole block and emits no -mcpu at all. apple-a15 is also accepted and
    #   would likely be faster on an A15+ target, but it sets a device
    #   compatibility floor, so it is a deliberate choice and not a default.
    #
    # BUILD_TESTING=Off -- CMakeLists.txt:381 does include(CTest), which
    #   defaults BUILD_TESTING to ON, which pulls in unittests/ and vixl.
    #
    # BUILD_FEXCONFIG=Off -- defaults TRUE and builds a desktop GUI tool.
    #
    # ENABLE_LTO=Off -- defaults TRUE. LTO bitcode in a .a that Xcode links
    #   conventionally is asking for trouble; nothing here needs it.
    #
    # Source/ needs no exclusion: the root CMakeLists already guards it with
    # `if (NOT APPLE)`, so an Apple build gets only External/*,
    # FEXHeaderUtils, CodeEmitter and FEXCore -- exactly these seven.
    cmake -S "$FEX_SRC" -B "$FEX_BUILD" -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_SYSTEM_NAME=iOS \
        -DCMAKE_SYSTEM_PROCESSOR=aarch64 \
        -DCMAKE_OSX_ARCHITECTURES=arm64 \
        -DCMAKE_OSX_SYSROOT=iphoneos \
        -DCMAKE_OSX_DEPLOYMENT_TARGET=17.0 \
        -DTUNE_CPU=none \
        -DBUILD_TESTING=Off \
        -DBUILD_FEXCONFIG=Off \
        -DENABLE_LTO=Off \
        -DENABLE_CCACHE=Off \
        > "$BUILD_DIR/configure.log" 2>&1 || {
        echo "  configure FAILED -- tail of $BUILD_DIR/configure.log:"
        tail -20 "$BUILD_DIR/configure.log"
        exit 1
    }
    echo "  configure OK"
else
    echo "  already configured (--reconfigure to redo)"
fi

echo "  building: ${TARGETS[*]}"
cmake --build "$FEX_BUILD" --target "${TARGETS[@]}" -- -j"$JOBS" > "$BUILD_DIR/build.log" 2>&1 || {
    echo "  build FAILED -- errors from $BUILD_DIR/build.log:"
    grep -E "error:" "$BUILD_DIR/build.log" | head -20
    exit 1
}
echo "  build OK"

# Verify by content. "arm64" alone is NOT enough: a macOS arm64 archive looks
# identical to lipo and would link into the app only to fail at runtime, so
# check the Mach-O platform recorded in an actual member.
echo ""
echo "=== Verifying archives ==="
MISSING=""
for a in "${ARCHIVES[@]}"; do
    [ -f "$FEX_BUILD/$a" ] || MISSING="$MISSING $a"
done
if [ -n "$MISSING" ]; then
    echo "ERROR: missing archives:$MISSING"
    exit 1
fi
PROBE_DIR="$BUILD_DIR/.probe"
rm -rf "$PROBE_DIR" && mkdir -p "$PROBE_DIR"
(cd "$PROBE_DIR" && ar x "$FEX_BUILD/FEXCore/Source/libFEXCore_Base.a")
PROBE_OBJ=$(ls "$PROBE_DIR"/*.o | head -1)
PLATFORM=$(vtool -show-build "$PROBE_OBJ" 2>/dev/null | awk '/platform/ {print $2}')
rm -rf "$PROBE_DIR"
if [ "$PLATFORM" != "IOS" ]; then
    echo "ERROR: objects report platform '$PLATFORM', expected IOS."
    echo "       An arm64 macOS build looks the same to lipo and would link"
    echo "       into the app but fail on device."
    exit 1
fi
for a in "${ARCHIVES[@]}"; do
    printf "  %-48s %9d bytes\n" "$a" "$(wc -c < "$FEX_BUILD/$a")"
done
echo "  platform IOS confirmed"

echo ""
echo "Done. The Xcode project reads these in place from FEX/build-ios --"
echo "nothing is copied into app/Madeira."
