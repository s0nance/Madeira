#!/bin/bash
# Push a Windows game directory into Madeira's app container, where Wine sees
# it as C:\Program Files\<name>\.
#
# Nothing here is hardcoded to one machine or one game, which the previous
# version of this script was: a DEVICE_ID for an iPhone 13 Pro that is not
# yours, a SRC_DIR under another user's home, and a BUNDLE_ID of
# com.madeira.emulator that matched neither the Xcode project (which said
# com.willfaust.mythicemu) nor anything installed. It pushed into the
# container of an app that did not exist, and said "Done".
#
# The bundle id is READ FROM THE XCODE PROJECT rather than repeated here, so
# the two cannot drift apart again.
#
# Usage: ./scripts/deploy-game.sh <local-game-dir> [name-under-Program-Files]
#        ./scripts/deploy-game.sh ~/Games/Thumper
#        ./scripts/deploy-game.sh ~/Games/Thumper Thumper
#        MADEIRA_DEVICE=<udid> ./scripts/deploy-game.sh ~/Games/Thumper
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PBXPROJ="$REPO_ROOT/app/Madeira.xcodeproj/project.pbxproj"

if [[ $# -lt 1 ]]; then
    sed -n '/^# Usage:/,/^set -/p' "$0" | sed 's/^# \{0,1\}//; /^set -/d'
    exit 1
fi
SRC_DIR="${1%/}"
GAME_NAME="${2:-$(basename "$SRC_DIR")}"

[[ -d "$SRC_DIR" ]] || { echo "error: not a directory: $SRC_DIR" >&2; exit 1; }

BUNDLE_ID=$(grep -m1 -oE 'PRODUCT_BUNDLE_IDENTIFIER = [^;]+' "$PBXPROJ" \
    | sed 's/PRODUCT_BUNDLE_IDENTIFIER = //; s/"//g')
[[ -n "$BUNDLE_ID" ]] || {
    echo "error: could not read PRODUCT_BUNDLE_IDENTIFIER from $PBXPROJ" >&2
    exit 1
}

# One physical device, or MADEIRA_DEVICE to disambiguate. Simulators are
# filtered out: they cannot run this app at all, since everything is built
# for iphoneos.
if [[ -n "${MADEIRA_DEVICE:-}" ]]; then
    DEVICE="$MADEIRA_DEVICE"
else
    # A while-read loop, not `mapfile`: macOS ships bash 3.2.57, where
    # mapfile/readarray do not exist. Anything written for bash 4 fails here
    # for everyone, not just on some machines.
    FOUND=()
    while IFS= read -r udid; do
        [[ -n "$udid" ]] && FOUND+=("$udid")
    done < <(xcrun devicectl list devices 2>/dev/null \
        | awk '$0 ~ /physical/ && $0 ~ /connected/ {
                 for (i = 1; i <= NF; i++) if ($i ~ /^000[0-9]/) print $i }')
    case ${#FOUND[@]} in
        1) DEVICE="${FOUND[0]}" ;;
        0) echo "error: no connected physical device." >&2
           echo "       xcrun devicectl list devices" >&2
           exit 1 ;;
        *) echo "error: ${#FOUND[@]} connected devices; set MADEIRA_DEVICE:" >&2
           printf '       %s\n' "${FOUND[@]}" >&2
           exit 1 ;;
    esac
fi

DST_PATH="Documents/wine/drive_c/Program Files/$GAME_NAME"

echo "==> device:      $DEVICE"
echo "==> bundle:      $BUNDLE_ID  (read from project.pbxproj)"
echo "==> source:      $SRC_DIR  ($(du -sh "$SRC_DIR" | awk '{print $1}'))"
echo "==> destination: <container>/$DST_PATH"
echo "==> Wine path:   C:\\Program Files\\$GAME_NAME\\"
echo ""

# devicectl behaves like cp -R for a directory source. The parent
# "Documents/wine/drive_c/Program Files/" exists after Madeira's first
# launch, when PrefixExtractor lays down the prefix skeleton -- so launch the
# app once before deploying into a fresh container.
echo "==> copying (minutes for a large game)..."
xcrun devicectl device copy to \
    --device "$DEVICE" \
    --source "$SRC_DIR" \
    --destination "$DST_PATH" \
    --domain-type appDataContainer \
    --domain-identifier "$BUNDLE_ID" \
    2>&1 | tail -20

echo ""
echo "==> done. In Madeira, point MADEIRA_EXE at the executable, e.g."
echo "    C:\\Program Files\\$GAME_NAME\\<game>.exe"
