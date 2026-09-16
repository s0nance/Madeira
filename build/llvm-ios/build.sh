#!/bin/bash
# Cross-build LLVM 15.0.7 for iOS-arm64. Consumed by build/dxmt-ios: airconv
# builds AIR through LLVM's IR API, and libdxmt_combined.a is DXMT's objects
# plus every static library this produces.
#
# WHY THIS EXISTS: build/dxmt-ios/README.md described this build in prose
# ("Two-stage build -- first llvm-tblgen for macOS host, then iOS target libs
# reusing it. Flags used (summary)") and no script implemented it. Following
# the prose was not enough: the README names ONE patch to AddLLVM.cmake and
# there are TWO sites with the same defect, so a build done from the document
# alone dies at 1786/1818 on every .dylib.
#
# Two stages because tablegen must run on the build machine: LLVM generates
# sources with llvm-tblgen, and an iOS binary cannot execute on macOS.
set -eu

BUILD_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$BUILD_DIR/../.." && pwd)"
SRC="$REPO_ROOT/toolchains/llvm-project"
HOST_BUILD="$REPO_ROOT/toolchains/llvm-host-build"
IOS_BUILD="$REPO_ROOT/toolchains/llvm-ios-build"
LLVM_TAG=llvmorg-15.0.7

# Must match build/dxmt-ios/build.sh and the app's IPHONEOS_DEPLOYMENT_TARGET.
# A mismatch is not fatal but produces one "object file was built for newer
# 'iOS' version" warning per member -- 654 of them when this was 18.0 against
# an app at 17.0 -- and would be a real runtime failure if any object used an
# API newer than the app's floor.
IOS_MIN=17.0

JOBS=$(sysctl -n hw.ncpu)

if [ ! -d "$SRC" ]; then
    echo "=== Cloning LLVM $LLVM_TAG ==="
    git clone --depth 1 --branch "$LLVM_TAG" \
        https://github.com/llvm/llvm-project.git "$SRC"
    # "warning: refs/tags/llvmorg-15.0.7 ... is not a commit" is expected --
    # it is an annotated tag, and the checkout is correct.
fi

# Both patches fix the same defect: a CMake test that lists Darwin but not
# iOS, so an iOS cross build takes the generic-Unix branch and feeds Apple's
# ld64 GNU-only flags. Applied idempotently so re-running is safe.
patch_darwin_match() {
    local file=$1 from=$2 to=$3 label=$4
    if grep -q "$to" "$file"; then
        echo "  $label: already patched"
    elif grep -q "$from" "$file"; then
        sed -i '' "s|$from|$to|" "$file"
        echo "  $label: patched"
    else
        echo "  ERROR: $label -- neither the original nor the patched form"
        echo "         found in $file. LLVM version drift; re-check by hand."
        exit 1
    fi
}

echo "=== Patching CMake for iOS ==="
# 1. AddLLVM.cmake: the one the README names. Picks --gc-sections on
#    non-Darwin; Apple's ld wants -dead_strip and rejects it.
patch_darwin_match "$SRC/llvm/cmake/modules/AddLLVM.cmake" \
    'MATCHES "Darwin"' 'MATCHES "Darwin|iOS"' "AddLLVM.cmake (dead_strip)"
# 2. HandleLLVMOptions.cmake: NOT in the README, and the reason a
#    by-the-document build fails. Adds -Wl,-z,defs to shared links; ld64
#    answers "unknown options: -z" and every .dylib fails, libLTO.dylib
#    first. Nothing here needs those dylibs, but ninja stops at the first
#    failure, so the static libraries built after them never get made.
patch_darwin_match "$SRC/llvm/cmake/modules/HandleLLVMOptions.cmake" \
    'MATCHES "Darwin|FreeBSD|OpenBSD|DragonFly|AIX|SunOS|OS390"' \
    'MATCHES "Darwin|iOS|FreeBSD|OpenBSD|DragonFly|AIX|SunOS|OS390"' \
    "HandleLLVMOptions.cmake (-z defs)"
# Two other `MATCHES "Darwin"` sites in HandleLLVMOptions.cmake are
# deliberately left alone: one only fires under LLVM_ENABLE_MODULES (off),
# the other adds -ffunction-sections/-fdata-sections, which iOS clang
# accepts (the configure reports C_SUPPORTS_FFUNCTION_SECTIONS - Success).

# Stage 1: llvm-tblgen for the build machine. LLVM_TARGETS_TO_BUILD is empty
# on purpose -- airconv emits AIR through the metallib writer, not through an
# LLVM backend, so no target backend is needed on either stage.
if [ ! -x "$HOST_BUILD/bin/llvm-tblgen" ]; then
    echo ""
    echo "=== Stage 1: llvm-tblgen (macOS host) ==="
    cmake -S "$SRC/llvm" -B "$HOST_BUILD" -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DLLVM_TARGETS_TO_BUILD= \
        > "$BUILD_DIR/configure-host.log" 2>&1 || {
        echo "  configure FAILED -- tail of $BUILD_DIR/configure-host.log:"
        tail -20 "$BUILD_DIR/configure-host.log"; exit 1
    }
    cmake --build "$HOST_BUILD" --target llvm-tblgen -- -j"$JOBS" \
        > "$BUILD_DIR/build-host.log" 2>&1 || {
        echo "  build FAILED -- errors from $BUILD_DIR/build-host.log:"
        grep -E "error:|FAILED" "$BUILD_DIR/build-host.log" | head -20; exit 1
    }
    echo "  $("$HOST_BUILD/bin/llvm-tblgen" --version | sed -n 's/.*LLVM version/llvm-tblgen/p')"
else
    echo ""
    echo "=== Stage 1: llvm-tblgen already built ==="
fi

echo ""
echo "=== Stage 2: LLVM static libraries (iOS arm64, min $IOS_MIN) ==="
cmake -S "$SRC/llvm" -B "$IOS_BUILD" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_SYSROOT=iphoneos \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$IOS_MIN" \
    -DLLVM_TABLEGEN="$HOST_BUILD/bin/llvm-tblgen" \
    -DLLVM_TARGETS_TO_BUILD= \
    -DLLVM_BUILD_UTILS=Off \
    -DLLVM_BUILD_TOOLS=Off \
    -DLLVM_INCLUDE_TESTS=Off \
    -DLLVM_ENABLE_ZSTD=Off \
    -DLLVM_ENABLE_TERMINFO=Off \
    > "$BUILD_DIR/configure-ios.log" 2>&1 || {
    echo "  configure FAILED -- tail of $BUILD_DIR/configure-ios.log:"
    tail -20 "$BUILD_DIR/configure-ios.log"; exit 1
}
echo "  configure OK"
cmake --build "$IOS_BUILD" -- -j"$JOBS" > "$BUILD_DIR/build-ios.log" 2>&1 || {
    echo "  build FAILED -- errors from $BUILD_DIR/build-ios.log:"
    grep -E "error:|FAILED|unknown option" "$BUILD_DIR/build-ios.log" | head -20
    exit 1
}
echo "  build OK"

# Verify by content: name the libraries airconv actually links, and check the
# recorded platform in a real member. "arm64" alone proves nothing -- a macOS
# arm64 archive is indistinguishable to lipo and would link but fail on device.
echo ""
echo "=== Verifying ==="
NEEDED=(
    libLLVMCore.a libLLVMSupport.a libLLVMBitWriter.a libLLVMBitReader.a
    libLLVMAnalysis.a libLLVMTransformUtils.a libLLVMScalarOpts.a
    libLLVMIRReader.a libLLVMAsmParser.a libLLVMBinaryFormat.a
    libLLVMRemarks.a libLLVMDemangle.a
)
MISSING=""
for l in "${NEEDED[@]}"; do
    [ -f "$IOS_BUILD/lib/$l" ] || MISSING="$MISSING $l"
done
[ -z "$MISSING" ] || { echo "ERROR: missing libraries:$MISSING"; exit 1; }
[ -f "$IOS_BUILD/include/llvm/Config/llvm-config.h" ] || {
    echo "ERROR: generated headers absent -- airconv includes them via -I"
    exit 1
}
PROBE="$BUILD_DIR/.probe"
rm -rf "$PROBE" && mkdir -p "$PROBE"
(cd "$PROBE" && ar x "$IOS_BUILD/lib/libLLVMSupport.a" APFloat.cpp.o 2>/dev/null \
    || ar x "$IOS_BUILD/lib/libLLVMSupport.a")
PROBE_OBJ=$(ls "$PROBE"/*.o | head -1)
PLATFORM=$(vtool -show-build "$PROBE_OBJ" 2>/dev/null | awk '/platform/ {print $2}')
MINOS=$(vtool -show-build "$PROBE_OBJ" 2>/dev/null | awk '/minos/ {print $2}')
rm -rf "$PROBE"
[ "$PLATFORM" = "IOS" ] || { echo "ERROR: platform '$PLATFORM', expected IOS"; exit 1; }
[ "$MINOS" = "$IOS_MIN" ] || {
    echo "ERROR: minos $MINOS, expected $IOS_MIN. Linking these into an app"
    echo "       with a lower floor produces one warning per member."
    exit 1
}
echo "  $(ls "$IOS_BUILD"/lib/*.a | wc -l | tr -d ' ') static libraries, platform IOS, minos $MINOS"

echo ""
echo "Done. Next: build/dxmt-ios/build.sh."
