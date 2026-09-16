#!/bin/bash
# Build DXMT winemetal unix side + airconv + dxbc_parser as iOS-aarch64
# static library, for linking into Madeira.app.
#
# Produces: libdxmt_unix.a
set -eu

BUILD_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$BUILD_DIR/../.." && pwd)"
DXMT_SRC="$REPO_ROOT/research/dxmt/src"
DXMT_ROOT="$REPO_ROOT/research/dxmt"
LLVM_SRC="$REPO_ROOT/toolchains/llvm-project/llvm"
LLVM_BUILD="$REPO_ROOT/toolchains/llvm-ios-build"
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
OBJ_DIR="$BUILD_DIR/obj"
OUT_LIB="$BUILD_DIR/libdxmt_unix.a"

mkdir -p "$OBJ_DIR"

COMMON_FLAGS="-arch arm64 -isysroot $SDK -miphoneos-version-min=17.0 -fblocks -O2"
INCLUDES="-I$DXMT_ROOT/include -I$DXMT_ROOT/libs -I$DXMT_SRC/winemetal -I$DXMT_SRC/airconv"
INCLUDES_DIRECTX="-I$DXMT_ROOT/include/native/directx -I$DXMT_ROOT/include/native/windows"
INCLUDES_SHADERS="-I$BUILD_DIR/shader-headers"
LLVM_INCLUDES="-I$LLVM_BUILD/include -I$LLVM_SRC/include"
AIRCONV_DEFS="-D_FILE_OFFSET_BITS=64 -D__STDC_CONSTANT_MACROS -D__STDC_FORMAT_MACROS -D__STDC_LIMIT_MACROS"
CXX_FLAGS="-std=c++20 -fno-exceptions -fno-rtti"

# airconv links three precompiled Metal shaders into every module it emits
# (airconv_context.cpp:188 does linkShader(M, air_msad) and friends), and it
# reaches them as C byte arrays via -I$INCLUDES_SHADERS. Nothing generated
# them: the directory is gitignored as a build artefact, the README does not
# mention it, and a clean tree failed with "fatal error: 'air_msad.h' file
# not found". The recipe is DXMT's own, lifted from research/dxmt/meson.build
# lines 127-142 (metalir_generator then hexdump_generator) rather than
# invented -- including --target=air64-apple-macos14.0, which is what upstream
# uses for these link-time AIR modules.
#
# `xxd -n <name>` is what makes the array name match the symbol airconv
# expects; without it xxd derives the name from the file path.
gen_shader_headers() {
    local shader_src="$DXMT_ROOT/src/airconv/shaders"
    local out="$BUILD_DIR/shader-headers"
    mkdir -p "$out"
    echo "=== AIR shader headers ==="
    local n regen=0
    for n in air_msad air_samplepos air_tessellation; do
        if [ -f "$out/$n.h" ] && [ "$out/$n.h" -nt "$shader_src/$n.metal" ]; then
            printf "  %-40s up to date\n" "$n.h"
            continue
        fi
        regen=1
        printf "  %-40s " "$n.h"
        if xcrun -sdk macosx metal -o "$out/$n.air" -c "$shader_src/$n.metal" \
                -std=metal3.1 --target=air64-apple-macos14.0 2>"$out/$n.err" \
           && xxd -n "$n" -i "$out/$n.air" "$out/$n.h"; then
            echo "OK"
        else
            echo "FAILED"
            head -10 "$out/$n.err"
            echo "  (needs the Metal toolchain: xcodebuild -downloadComponent MetalToolchain)"
            exit 1
        fi
    done
    [ $regen -eq 0 ] || echo "  regenerated"
}

SUCCEEDED=0
FAILED=0
FAILED_FILES=""

compile_objc() {
    local src=$1 name=$2
    printf "  %-40s " "$name"
    if xcrun -sdk iphoneos clang $COMMON_FLAGS -x objective-c $INCLUDES \
        -c "$src" -o "$OBJ_DIR/$name.o" 2>"$OBJ_DIR/$name.err"; then
        echo "OK"; SUCCEEDED=$((SUCCEEDED+1))
    else
        echo "FAILED"; FAILED=$((FAILED+1)); FAILED_FILES="$FAILED_FILES $name"
    fi
}

compile_cxx() {
    local src=$1 name=$2 extra="${3:-}"
    printf "  %-40s " "$name"
    if xcrun -sdk iphoneos clang++ $COMMON_FLAGS $CXX_FLAGS $INCLUDES $INCLUDES_DIRECTX $INCLUDES_SHADERS $LLVM_INCLUDES $AIRCONV_DEFS $extra \
        -c "$src" -o "$OBJ_DIR/$name.o" 2>"$OBJ_DIR/$name.err"; then
        echo "OK"; SUCCEEDED=$((SUCCEEDED+1))
    else
        echo "FAILED"; FAILED=$((FAILED+1)); FAILED_FILES="$FAILED_FILES $name"
    fi
}

gen_shader_headers

echo ""
echo "=== winemetal unix (Objective-C) ==="
compile_objc "$DXMT_SRC/winemetal/unix/winemetal_unix.c" winemetal_unix
compile_objc "$DXMT_SRC/winemetal/unix/cache.c"          cache

echo "=== airconv (C++ 20, needs LLVM headers) ==="
for cpp in airconv_context.cpp air_type.cpp air_signature.cpp air_operations.cpp \
           dxbc_converter.cpp dxbc_converter_gs.cpp dxbc_converter_ts.cpp \
           dxbc_converter_basicblock.cpp dxbc_converter_cfg.cpp \
           dxbc_instructions.cpp dxbc_signature.cpp metallib_writer.cpp; do
    name=$(basename "$cpp" .cpp)
    compile_cxx "$DXMT_SRC/airconv/$cpp" "$name"
done
compile_cxx "$DXMT_SRC/airconv/nt/air_builder.cpp" air_builder
compile_cxx "$DXMT_SRC/airconv/nt/dxbc_converter_base.cpp" dxbc_converter_base
compile_cxx "$DXMT_SRC/airconv/transforms/lower_16bit_texread.cpp" lower_16bit_texread

echo "=== DXBCParser (uses exceptions — override) ==="
for cpp in BlobContainer.cpp DXBCUtils.cpp ShaderBinary.cpp; do
    name=dxbc_$(basename "$cpp" .cpp)
    # ShaderBinary uses `throw`, so we can't use -fno-exceptions from CXX_FLAGS.
    printf "  %-40s " "$name"
    if xcrun -sdk iphoneos clang++ $COMMON_FLAGS -std=c++20 -fno-rtti \
            $INCLUDES $INCLUDES_DIRECTX $AIRCONV_DEFS \
            -c "$DXMT_ROOT/libs/DXBCParser/$cpp" -o "$OBJ_DIR/$name.o" 2>"$OBJ_DIR/$name.err"; then
        echo "OK"; SUCCEEDED=$((SUCCEEDED+1))
    else
        echo "FAILED"; FAILED=$((FAILED+1)); FAILED_FILES="$FAILED_FILES $name"
    fi
done

echo ""
echo "Results: $SUCCEEDED succeeded, $FAILED failed"
if [ -n "$FAILED_FILES" ]; then
    echo "Failed:$FAILED_FILES"
    echo "See .err files in $OBJ_DIR/"
    exit 1
fi

echo ""
echo "=== Archiving libdxmt_unix.a ==="
rm -f "$OUT_LIB"
xcrun -sdk iphoneos ar rcs "$OUT_LIB" "$OBJ_DIR"/*.o
echo "Built: $OUT_LIB ($(wc -c < "$OUT_LIB" | tr -d ' ') bytes)"

# Combine with the iOS LLVM static libraries and install. This was a manual
# libtool line in build/dxmt-ios/README.md, which meant the one artefact the
# Xcode project actually links was produced by a command nobody ran twice the
# same way. airconv is LLVM IR construction, so the LLVM libraries are not an
# optional extra -- without them the app link fails on hundreds of llvm::
# symbols.
LLVM_IOS="$REPO_ROOT/toolchains/llvm-ios-build"
COMBINED="$BUILD_DIR/libdxmt_combined.a"
APP_LIB="$REPO_ROOT/app/Madeira/libdxmt_combined.a"
if [ ! -d "$LLVM_IOS/lib" ]; then
    echo ""
    echo "ERROR: $LLVM_IOS/lib is missing -- run build/llvm-ios/build.sh first."
    exit 1
fi
echo ""
echo "=== Combining with LLVM iOS ==="
rm -f "$COMBINED"
# "has no symbols" is expected for a handful of LLVM members and is not an error.
xcrun -sdk iphoneos libtool -static -o "$COMBINED" \
    "$OBJ_DIR"/*.o "$LLVM_IOS"/lib/*.a 2>&1 | grep -vE "has no symbols" || true
[ -f "$COMBINED" ] || { echo "ERROR: libtool produced nothing"; exit 1; }

# Verify by content rather than by exit status: one member per DXMT object
# plus the LLVM ones, and the deployment target must match the app's floor --
# a mismatch is one linker warning per member (654 of them when LLVM was
# built at 18.0 against an app at 17.0).
MEMBERS=$(ar t "$COMBINED" | grep -v SYMDEF | wc -l | tr -d ' ')
for o in winemetal_unix.o airconv_context.o metallib_writer.o; do
    ar t "$COMBINED" | grep -qx "$o" || {
        echo "ERROR: $o absent from the combined archive"; exit 1; }
done
PROBE="$BUILD_DIR/.probe"
rm -rf "$PROBE" && mkdir -p "$PROBE"
(cd "$PROBE" && ar x "$COMBINED" winemetal_unix.o)
PLATFORM=$(vtool -show-build "$PROBE/winemetal_unix.o" 2>/dev/null | awk '/platform/ {print $2}')
MINOS=$(vtool -show-build "$PROBE/winemetal_unix.o" 2>/dev/null | awk '/minos/ {print $2}')
rm -rf "$PROBE"
[ "$PLATFORM" = "IOS" ] || { echo "ERROR: platform '$PLATFORM', expected IOS"; exit 1; }
echo "  $MEMBERS members, platform IOS, minos $MINOS"

cp "$COMBINED" "$APP_LIB"
echo "Installed: $APP_LIB ($(wc -c < "$APP_LIB" | tr -d ' ') bytes)"
