#!/bin/bash
set -e

BUILD_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$BUILD_DIR/../.." && pwd)"
WINE_SRC="$REPO_ROOT/wine"
WINE_BUILD="$WINE_SRC/build-macos"
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
OBJ_DIR="$BUILD_DIR/obj"
APP_LIB="$REPO_ROOT/app/Madeira/libntdll_unix.a"

mkdir -p "$OBJ_DIR"

SUCCEEDED=0
FAILED=0
FAILED_FILES=""
# Every object this run produced. The archive is built from THIS, not from
# a hand-maintained list and not from obj/*.o -- see the note above `ar`.
BUILT_OBJS=()

compile_one() {
    local src=$1
    local name=$2
    echo -n "  $name... "

    if xcrun -sdk iphoneos clang \
        -arch arm64 -isysroot "$SDK" -miphoneos-version-min=17.0 \
        -O2 -fPIC -fvisibility=hidden -fno-stack-protector -fno-strict-aliasing \
        -Wno-implicit-function-declaration -Wno-int-conversion \
        -include "$WINE_BUILD/include/config.h" \
        -include "$BUILD_DIR/shims/wine_ios_exit.h" \
        -I"$BUILD_DIR/shims" \
        -I"$WINE_BUILD/dlls/ntdll" -I"$WINE_SRC/dlls/ntdll" -I"$WINE_SRC/dlls/ntdll/unix" \
        -I"$WINE_BUILD/include" -I"$WINE_SRC/include" \
        -D__WINESRC__ -DLTC_NO_PROTOTYPES -DLTC_SOURCE -D_NTSYSTEM_ \
        -D_ACRTIMP= -DWINBASEAPI= \
        -DBINDIR=\"/usr/local/bin\" -DLIBDIR=\"/usr/local/lib\" \
        -DDATADIR=\"/usr/local/share\" -DSYSTEMDLLPATH=\"\" \
        -DWINE_UNIX_LIB -DWINE_IOS=1 \
        -Dget_thread_context=ntdll_get_thread_context \
        -Dset_thread_context=ntdll_set_thread_context \
        -c "$src" -o "$OBJ_DIR/$name.o" 2>"$OBJ_DIR/$name.err"; then
        echo "OK"
        SUCCEEDED=$((SUCCEEDED + 1))
        BUILT_OBJS+=("$OBJ_DIR/$name.o")
    else
        echo "FAILED"
        FAILED=$((FAILED + 1))
        FAILED_FILES="$FAILED_FILES $name"
    fi
}

# iOS-Madeira 2026-07-05 (Steam S0): compile a DLL's unix side into
# libntdll_unix.a. Args: src, obj-name, funcs-prefix, extra flags...
# The __wine_unix_call_funcs tables are renamed per-lib (they'd collide
# in one archive) and registered by name in virtual_ios.c's
# load_builtin_unixlib. GnuTLS-backed libs add ios_gnutls_shim.h to
# route dlopen/dlsym at the static symtab (gnutls_symtab_ios.c).
CRYPTO_DIR="$REPO_ROOT/build/crypto-unix"
GNUTLS_PREFIX="$REPO_ROOT/toolchains/gnutls-ios"
compile_unixlib() {
    local src=$1 name=$2 prefix=$3
    shift 3
    echo -n "  $name... "
    if xcrun -sdk iphoneos clang \
        -arch arm64 -isysroot "$SDK" -miphoneos-version-min=17.0 \
        -O2 -fPIC -fvisibility=hidden -fno-stack-protector -fno-strict-aliasing \
        -Wno-implicit-function-declaration -Wno-int-conversion \
        -include "$WINE_BUILD/include/config.h" \
        -include "$BUILD_DIR/shims/wine_ios_exit.h" \
        -I"$BUILD_DIR/shims" \
        -I"$WINE_BUILD/include" -I"$WINE_SRC/include" \
        -D__WINESRC__ -D_NTSYSTEM_ -D_ACRTIMP= -DWINBASEAPI= \
        -DWINE_UNIX_LIB -DWINE_IOS=1 \
        -D__wine_unix_call_funcs=${prefix}_unix_call_funcs \
        -D__wine_unix_call_wow64_funcs=${prefix}_unix_call_wow64_funcs \
        "$@" \
        -c "$src" -o "$OBJ_DIR/$name.o" 2>"$OBJ_DIR/$name.err"; then
        echo "OK"
        SUCCEEDED=$((SUCCEEDED + 1))
        BUILT_OBJS+=("$OBJ_DIR/$name.o")
    else
        echo "FAILED"
        FAILED=$((FAILED + 1))
        FAILED_FILES="$FAILED_FILES $name"
    fi
}

echo "=== Building ntdll unix (iOS) ==="

# iOS-Madeira 2026-05-13: silent audio driver — provides a null
# IAudioClock that advances at real time so FMOD's audio-gated rhythm
# logic in Thumper et al. advances past intro music.
compile_one "$BUILD_DIR/audio_null_ios.c" "audio_null_ios"

# iOS-Madeira 2026-07-05 (Steam S0): network + crypto unix sides.
echo "=== Building crypto/network unixlibs ==="
"$CRYPTO_DIR/gen_gnutls_symtab.sh" > /dev/null
compile_one "$CRYPTO_DIR/gnutls_symtab_ios.c" "gnutls_symtab_ios"
compile_unixlib "$WINE_SRC/dlls/ws2_32/unixlib.c" "ws2_32_unixlib" "ws2_32" \
    -I"$WINE_SRC/dlls/ws2_32"
compile_unixlib "$WINE_SRC/dlls/bcrypt/gnutls.c" "bcrypt_unixlib" "bcrypt" \
    -I"$WINE_SRC/dlls/bcrypt" -I"$GNUTLS_PREFIX/include" \
    -include "$CRYPTO_DIR/ios_gnutls_shim.h"
compile_unixlib "$WINE_SRC/dlls/secur32/schannel_gnutls.c" "secur32_unixlib" "secur32" \
    -I"$WINE_SRC/dlls/secur32" -I"$GNUTLS_PREFIX/include" \
    -include "$CRYPTO_DIR/ios_gnutls_shim.h"
# iOS-Madeira ml494 (#61 text wall): dwrite had NO unixlib, so every
# __wine_unix_call from dwrite.dll failed and get_glyph_bbox never ran —
# every glyph run reported an EMPTY bbox and Chromium drew no text at all.
# freetype is static here, so dwrite_freetype_ios.c rewrites dlopen/dlsym.
# dwrite.h/dwrite_3.h are widl-generated and only exist in the arm64ec
# build tree, so that include dir is named explicitly here.
compile_unixlib "$BUILD_DIR/dwrite_freetype_ios.c" "dwrite_unixlib" "dwrite" \
    -I"$WINE_SRC/dlls/dwrite" -I"$REPO_ROOT/research/freetype/include" \
    -I"$REPO_ROOT/wine/build-arm64ec/include"
compile_unixlib "$CRYPTO_DIR/crypt32_unixlib_ios.c" "crypt32_unixlib" "crypt32" \
    -I"$WINE_SRC/dlls/crypt32" -I"$GNUTLS_PREFIX/include" \
    -include "$CRYPTO_DIR/ios_gnutls_shim.h"
# iOS-Madeira 2026-08-03 (#79 transport): in-process NSI TCP connection
# tables (nsiproxy.sys is not shipped; PE nsi.dll falls back to this).
compile_one "$BUILD_DIR/nsi_unixlib_ios.c" "nsi_unixlib_ios"

for src in $WINE_SRC/dlls/ntdll/unix/*.c; do
    name=$(basename "$src" .c)

    # Use patched versions for specific files
    case "$name" in
        loader)
            compile_one "$BUILD_DIR/loader_ios.c" "loader"
            ;;
        process)
            compile_one "$BUILD_DIR/process_ios.c" "process"
            ;;
        server)
            compile_one "$BUILD_DIR/server_ios.c" "server"
            ;;
        env)
            compile_one "$BUILD_DIR/env_ios.c" "env"
            ;;
        cdrom)
            compile_one "$BUILD_DIR/cdrom_stub.c" "cdrom"
            ;;
        virtual)
            compile_one "$BUILD_DIR/virtual_ios.c" "virtual"
            ;;
        signal_arm64)
            compile_one "$BUILD_DIR/signal_arm64_ios.c" "signal_arm64"
            ;;
        thread)
            compile_one "$BUILD_DIR/thread_ios.c" "thread"
            ;;
        *)
            compile_one "$src" "$name"
            ;;
    esac
done

echo ""
echo "Results: $SUCCEEDED succeeded, $FAILED failed"
# Hard fail. This script used to print the failures and archive anyway,
# which ships either a stale object from a previous run or none at all --
# both silent. win32u-unix/build.sh has always done this; ntdll had not.
if [ $FAILED -gt 0 ]; then
    echo "Failed:$FAILED_FILES"
    for n in $FAILED_FILES; do echo "  --- $OBJ_DIR/$n.err"; done
    echo ""
    echo "(not archiving)"
    exit 1
fi

echo ""
echo "=== Building libntdll_unix.a ==="
# Derived from what was just compiled, never hand-maintained. The old
# explicit list is how #61 happened: the dwrite unixlib compiled fine,
# printed OK, and was simply absent from the `ar` line -- so every
# __wine_unix_call from dwrite.dll failed, get_glyph_bbox never ran, every
# glyph reported an empty bbox, and Steam drew NO TEXT AT ALL with no error
# anywhere. "Compiled OK" says nothing about shipping.
# Not obj/*.o either: obj/ is gitignored and survives across runs, so a
# glob would also pick up objects this file set no longer builds.
if [ ${#BUILT_OBJS[@]} -eq 0 ]; then
    echo "ERROR: nothing was compiled"
    exit 1
fi
rm -f "$OBJ_DIR/libntdll_unix.a"
ar rcs "$OBJ_DIR/libntdll_unix.a" "${BUILT_OBJS[@]}"

# Verify by content, per the project's own rule 6. A member count that
# disagrees with the object count means the archive dropped something.
# macOS ar lists its own symbol-table member ("__.SYMDEF SORTED") in
# `ar t` output, so it must be filtered or every count is off by one.
MEMBERS=$(ar t "$OBJ_DIR/libntdll_unix.a" | grep -v SYMDEF | wc -l | tr -d ' ')
if [ "$MEMBERS" != "${#BUILT_OBJS[@]}" ]; then
    echo "ERROR: archive has $MEMBERS members but ${#BUILT_OBJS[@]} objects were built"
    exit 1
fi
# The #61 regression guard, named explicitly: every unixlib's renamed call
# table must actually be in the archive.
for sym in dwrite ws2_32 bcrypt secur32 crypt32; do
    if ! nm "$OBJ_DIR/libntdll_unix.a" 2>/dev/null | grep -q "_${sym}_unix_call_funcs"; then
        echo "ERROR: ${sym}_unix_call_funcs absent from the archive"
        exit 1
    fi
done
echo "  $MEMBERS members, unixlib call tables verified"

echo "Copying to app..."
cp "$OBJ_DIR/libntdll_unix.a" "$APP_LIB"
echo "libntdll_unix.a: $(wc -c < "$APP_LIB" | tr -d ' ') bytes"
echo "Done!"
