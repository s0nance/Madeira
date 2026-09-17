#!/bin/bash
# Build wineserver as a static library for iOS (aarch64), linked into
# Madeira.app and run as a THREAD rather than a process.
#
# Every file in wine/server's SOURCES list is compiled here, from source,
# in one pass. For each name, the source is build/wineserver/<name>_ios.c
# when that fork exists and wine/server/<name>.c otherwise.
#
# WHY THIS SHAPE: until 2026-09, this script only rebuilt ~19 files and
# injected them into a PREEXISTING libwineserver.a that no script in this
# repo could produce -- it was copied from app/Madeira/, which is
# gitignored and was never committed. A fresh clone therefore died on
# "No base libwineserver.a found", and the ~25 objects nobody rebuilt were
# untracked mystery code. That is exactly how the #79 forensics ended up
# reading a three-week-old hand-inserted sock.o whose source was lost.
# Two whole failure modes disappear with the base archive:
#   - "compiled OK but silently not archived" (the #61 trap: an entry had
#     to appear in BOTH a compile list AND a replacement list, and an entry
#     in only the first printed OK and was discarded).
#   - an object in the shipped archive whose source is unknown.
set -e

BUILD_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$BUILD_DIR/../.." && pwd)"
WINE_SRC="$REPO_ROOT/wine"
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
APP_LIB="$REPO_ROOT/app/Madeira/libwineserver.a"
SHIMS_DIR="$REPO_ROOT/build/ntdll-unix/shims"

OBJ_DIR="$BUILD_DIR/obj"
mkdir -p "$OBJ_DIR"

# Unchanged from the incremental script, deliberately: the 19 files that
# already built did so with exactly these flags, so same flags == same
# objects, and only the ~25 newly-compiled ones are new evidence.
CC_FLAGS=(
    -arch arm64 -isysroot "$SDK" -miphoneos-version-min=17.0 -O2
    -I"$WINE_SRC/include" -I"$WINE_SRC/include/wine"
    -I"$WINE_SRC/build-macos/include"
    -I"$BUILD_DIR" -I"$WINE_SRC/server"
    -I"$SHIMS_DIR"
    -include "$BUILD_DIR/config_ios.h"
    -include stdarg.h
    -include "$BUILD_DIR/unicode_fix.h"
    -include "$BUILD_DIR/wineserver_ios_kill.h"
    -DBINDIR=\"/usr/local/bin\" -DDATADIR=\"/usr/local/share\"
    -D__WINESRC__ -DWINE_IOS=1
    -Dmain=wineserver_main
    # Symbol collisions with win32u are NOT handled via -D macros -- that
    # rewrites macro args (e.g. DECL_HANDLER(name)) and breaks struct
    # name concatenation. Renames are done post-compile via objcopy below,
    # applied to EVERY .o so cross-file refs (e.g. clipboard.c calling
    # send_notify_message defined in queue.c) stay internal to the archive.
    -Wno-implicit-function-declaration
)

if [ ! -f "$WINE_SRC/build-macos/include/config.h" ]; then
    echo "ERROR: $WINE_SRC/build-macos/include/config.h is missing."
    echo "       Configure the macOS-host Wine tree first -- every build"
    echo "       script in build/ includes its config.h."
    exit 1
fi

# The authoritative file list is wine/server/Makefile.in's SOURCES, read
# rather than copied: a file added upstream must not need an edit here.
# Non-.c entries (security.h, the .man.in templates) are filtered out.
SERVER_SOURCES=$(sed -n '/^SOURCES = /,/^$/p' "$WINE_SRC/server/Makefile.in" \
    | grep -oE '[a-z0-9_]+\.c' | sort -u)
if [ -z "$SERVER_SOURCES" ]; then
    echo "ERROR: could not read SOURCES from $WINE_SRC/server/Makefile.in"
    exit 1
fi

SUCCEEDED=0
FAILED=0
FAILED_FILES=""

# Compiles $1 to $OBJ_DIR/$2.o. The object is named after the SOURCES
# entry, never after the fork file, so archive member names match upstream
# and a fork cannot end up shipped alongside the file it replaces.
compile_one() {
    local src=$1 name=$2
    printf "  %-16s %-14s " "$name" "$(basename "$src")"
    if xcrun -sdk iphoneos clang "${CC_FLAGS[@]}" -c "$src" -o "$OBJ_DIR/$name.o" 2>"$OBJ_DIR/err-$name.txt"; then
        echo "OK"
        SUCCEEDED=$((SUCCEEDED + 1))
    else
        echo "FAILED"
        FAILED=$((FAILED + 1))
        FAILED_FILES="$FAILED_FILES $name"
    fi
}

# No arg: full build. With args: recompile only those names and re-archive
# from obj/ (needs a previous full build to have populated it).
SELECT=("$@")
wanted() {
    [ ${#SELECT[@]} -eq 0 ] && return 0
    local n
    for n in "${SELECT[@]}"; do [ "$n" = "$1" ] && return 0; done
    return 1
}

echo "=== Building wineserver (iOS) ==="
for f in $SERVER_SOURCES; do
    name="${f%.c}"
    wanted "$name" || continue
    if [ -f "$BUILD_DIR/${name}_ios.c" ]; then
        compile_one "$BUILD_DIR/${name}_ios.c" "$name"
    else
        compile_one "$WINE_SRC/server/$f" "$name"
    fi
done

# iOS-only extras, not in upstream SOURCES.
if wanted wine_log_ios; then
    compile_one "$BUILD_DIR/wine_log_ios.c" "wine_log_ios"
fi
if wanted wineserver_ios_kill; then
    # Compiled WITHOUT -include wineserver_ios_kill.h: that header defines a
    # `kill` macro, and this file implements the wrapper it points at, so
    # including it here makes the macro recursive.
    printf "  %-16s %-14s " "wineserver_ios_kill" "wineserver_ios_kill.c"
    KILL_FLAGS=(-arch arm64 -isysroot "$SDK" -miphoneos-version-min=17.0 -O2
        -I"$BUILD_DIR" -DWINE_IOS=1 -Wno-implicit-function-declaration)
    if xcrun -sdk iphoneos clang "${KILL_FLAGS[@]}" -c "$BUILD_DIR/wineserver_ios_kill.c" \
            -o "$OBJ_DIR/wineserver_ios_kill.o" 2>"$OBJ_DIR/err-wineserver_ios_kill.txt"; then
        echo "OK"; SUCCEEDED=$((SUCCEEDED + 1))
    else
        echo "FAILED"; FAILED=$((FAILED + 1)); FAILED_FILES="$FAILED_FILES wineserver_ios_kill"
    fi
fi

echo ""
echo "Results: $SUCCEEDED succeeded, $FAILED failed"
# Hard fail. A partial object set used to be archived anyway, which ships
# either a stale object or none at all -- both silent.
if [ $FAILED -gt 0 ]; then
    echo "Failed:$FAILED_FILES"
    for n in $FAILED_FILES; do echo "  --- $OBJ_DIR/err-$n.txt"; done
    echo "(not archiving)"
    exit 1
fi

echo ""
echo "=== Renaming colliding symbols (objcopy sweep) ==="
# Renames are internal to the archive: every .o gets the same treatment, so
# definitions AND references move together and cross-file calls inside
# wineserver still resolve. Externals (win32u, ntdll) only ever see the
# ws_-prefixed names. Staged in a copy so obj/ keeps un-renamed objects for
# a selective rebuild.
# Homebrew's LLVM is keg-only, so llvm-objcopy is not on PATH by default.
# Look it up at its documented location rather than requiring the caller to
# export PATH first -- build/wine/build.sh does the same for bison 3, and
# build-all.sh would otherwise pass its preflight and fail here. NOT a
# versioned Cellar path: this script used to fall back to
# /opt/homebrew/Cellar/llvm/22.1.0/bin, which stopped existing the moment
# Homebrew shipped 23.1.1.
OBJCOPY=$(command -v llvm-objcopy || true)
if [ -z "$OBJCOPY" ] && [ -x /opt/homebrew/opt/llvm/bin/llvm-objcopy ]; then
    OBJCOPY=/opt/homebrew/opt/llvm/bin/llvm-objcopy
fi
if [ -z "$OBJCOPY" ]; then
    echo "ERROR: llvm-objcopy not found, on PATH or at"
    echo "       /opt/homebrew/opt/llvm/bin. Run: brew install llvm"
    exit 1
fi
COLLISIONS=(
    alloc_user_handle free_user_handle get_virtual_screen_rect
    destroy_thread_windows get_window_thread is_desktop_class
    is_message_class is_window_visible mirror_region send_notify_message
    # shared_session: BOTH wineserver and win32u-unix declare it as a
    # common global. The single-process iOS link merges them -- last writer
    # wins. win32u's shared_session_init() overwrites with the client-side
    # NtMapViewOfSection result (read-only), making wineserver's writes
    # silently fail since they go through the client's RO view. Renamed so
    # each side has its own pointer to its own mapping of the same file.
    shared_session
    # user_shared_data: the same defect one layer over, but it does NOT fail
    # silently. wineserver's create_user_data_mapping() sets it to a
    # writable alias, then the guest's ntdll init runs virtual_ios.c's
    # `user_shared_data = NULL; NtAllocateVirtualMemory(..., PAGE_READONLY)`
    # over the SAME variable, so the server's pointer ends up at the guest's
    # read-only page in the FEX guest band. The server's next store faults
    # and the main loop wedges forever -- which is why the shared clock
    # could never be published and every process hung in
    # server_init_process() as soon as a client connected.
    user_shared_data
)
RENAME_ARGS=()
for s in "${COLLISIONS[@]}"; do
    RENAME_ARGS+=(--redefine-sym "_${s}=_ws_${s}")
done
STAGE_DIR="$OBJ_DIR/stage"
rm -rf "$STAGE_DIR" && mkdir -p "$STAGE_DIR"
for f in "$OBJ_DIR"/*.o; do
    cp "$f" "$STAGE_DIR/"
    "$OBJCOPY" "${RENAME_ARGS[@]}" "$STAGE_DIR/$(basename "$f")"
done
echo "  $(ls "$STAGE_DIR"/*.o | wc -l | tr -d ' ') objects renamed"

echo ""
echo "=== Archiving libwineserver.a ==="
rm -f "$OBJ_DIR/libwineserver.a"
ar rcs "$OBJ_DIR/libwineserver.a" "$STAGE_DIR"/*.o
rm -rf "$STAGE_DIR"

# Verify by content, not by exit status, and against the EXPECTED member
# set rather than against obj/. Comparing to obj/ would pass happily after
# `./build.sh fd` on an empty obj/: one object, one member, archive
# complete -- and a libwineserver.a missing 45 of its 46 members would ship.
echo ""
echo "=== Verifying archive contents ==="
EXPECTED=()
for f in $SERVER_SOURCES; do EXPECTED+=("${f%.c}.o"); done
EXPECTED+=(wine_log_ios.o wineserver_ios_kill.o)
# grep -v SYMDEF: macOS ar lists its own symbol-table member
# ("__.SYMDEF SORTED") in `ar t` output.
ar t "$OBJ_DIR/libwineserver.a" | grep -v SYMDEF > "$OBJ_DIR/members.txt"
MISSING=""
for m in "${EXPECTED[@]}"; do
    grep -qx "$m" "$OBJ_DIR/members.txt" || MISSING="$MISSING $m"
done
if [ -n "$MISSING" ]; then
    echo "ERROR: archive is missing members:$MISSING"
    echo "       (a selective rebuild needs a full ./build.sh first)"
    exit 1
fi
MEMBERS=$(wc -l < "$OBJ_DIR/members.txt" | tr -d ' ')
if ! nm "$OBJ_DIR/libwineserver.a" 2>/dev/null | grep -q " _ws_user_shared_data"; then
    echo "ERROR: _ws_user_shared_data absent -- the objcopy sweep did not take"
    exit 1
fi
echo "  $MEMBERS members, renames verified"

cp "$OBJ_DIR/libwineserver.a" "$APP_LIB"
echo "Done! libwineserver.a: $(wc -c < "$APP_LIB" | tr -d ' ') bytes"
