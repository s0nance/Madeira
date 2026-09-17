#!/bin/bash
# Build the D3D11 load test for BOTH architectures.
#
# Both on purpose, and that is the whole design: aarch64 runs native and
# isolates DXMT, x86-64 goes through FEX and ARM64EC first, which is the path a
# real game takes. Either frame time alone is uninterpretable -- the difference
# between them is what separates "DXMT is slow" from "the emulator is slow".
#
# Shaders are compiled host-side to DXBC and embedded, same as
# d3d11-triangle: no runtime shader compiler inside the PE. It reuses that
# directory's hlsl_compile.exe rather than building a second one.
#
# The aarch64 build is tagged `winebuild --builtin` and the x86-64 build is
# not, matching dxmt-tests: the tag sends it down Wine's builtin path, while an
# untagged x64 PE is what FEX picks up as a guest binary.
set -eu

DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$DIR/../.." && pwd)"
MINGW="$REPO_ROOT/toolchains/llvm-mingw-20260421-ucrt-macos-universal/bin"
DXMT_DIRECTX="$REPO_ROOT/research/dxmt/include/native/directx"
HLSL_COMPILE="$REPO_ROOT/build/d3d11-triangle/hlsl_compile.exe"
WINE=${WINE:-/opt/homebrew/bin/wine}

CC_AARCH64="$MINGW/aarch64-w64-mingw32-clang"
CC_X86_64="$MINGW/x86_64-w64-mingw32-clang"

# The shader step needs a host that can run a Windows console exe calling
# D3DCompile, which is how d3d11-triangle and dxmt-tests already do it. That
# means a host Wine, and there is none on this machine -- so none of the D3D11
# tests in this tree can be rebuilt here, not just this one. Say which piece is
# missing rather than failing on a bare "command not found" three lines later.
if [[ ! -x "$WINE" ]]; then
    cat >&2 <<'MSG'
ERROR: no host Wine at $WINE, so HLSL cannot be compiled to DXBC.

  The shaders are built by running a small x86_64 PE (hlsl_compile.exe) that
  calls D3DCompile out of Wine's d3dcompiler_47, which uses vkd3d-shader to
  emit real SM5 DXBC. d3d11-triangle and dxmt-tests have the same dependency;
  this is not specific to the load test.

  Unblock it with:   brew install --cask wine-stable
  or point WINE= at an existing wine binary.

  wine/build-macos is NOT an alternative: build/wine/build.sh builds only
  winebuild, the headers and three import libs on purpose, so that tree has no
  d3dcompiler to call.
MSG
    exit 1
fi

if [[ ! -x "$HLSL_COMPILE" ]]; then
    echo "==> building host HLSL compiler (d3d11-triangle)"
    "$MINGW/x86_64-w64-mingw32-clang" -o "$HLSL_COMPILE" \
        "$REPO_ROOT/build/d3d11-triangle/hlsl_compile.c" -ld3dcompiler -O2
fi

echo "==> compiling shaders"
for stage in vs ps; do
    "$WINE" "$HLSL_COMPILE" "${stage}_main" "${stage}_5_0" < "$DIR/shaders.hlsl" \
        > "$DIR/${stage}.dxbc" 2>"$DIR/${stage}.err"
    if [[ ! -s "$DIR/${stage}.dxbc" ]]; then
        echo "ERROR: ${stage} shader compile failed" >&2
        cat "$DIR/${stage}.err" >&2
        exit 1
    fi
    # A DXBC blob starts with the magic; without this check a zero-length or
    # error-text output would sail through and fail much later as a shader
    # creation failure on device, which is a far worse place to find out.
    head -c 4 "$DIR/${stage}.dxbc" | grep -q DXBC || {
        echo "ERROR: ${stage}.dxbc has no DXBC magic" >&2; exit 1; }
    xxd -i -n "${stage}_dxbc" "$DIR/${stage}.dxbc" > "$DIR/${stage}_dxbc.h"
    echo "  ${stage}: $(wc -c < "$DIR/${stage}.dxbc") bytes of DXBC"
done

echo "==> building load.exe (aarch64, native path)"
"$CC_AARCH64" -o "$DIR/load.exe" -I "$DXMT_DIRECTX" -I "$DIR" \
    "$DIR/load.c" -ld3d11 -ldxgi -luuid -lm -O2
"$REPO_ROOT/wine/build-macos/tools/winebuild/winebuild" --builtin "$DIR/load.exe"

echo "==> building load-x64.exe (x86-64, the emulated path)"
"$CC_X86_64" -o "$DIR/load-x64.exe" -I "$DXMT_DIRECTX" -I "$DIR" \
    "$DIR/load.c" -ld3d11 -ldxgi -luuid -lm -O2

for f in "$DIR/load.exe" "$DIR/load-x64.exe"; do
    printf '%-22s ' "$(basename "$f")"
    python3 - "$f" <<'PY'
import sys, struct
d = open(sys.argv[1], 'rb').read(0x200)
e = struct.unpack_from('<I', d, 0x3c)[0]
m = struct.unpack_from('<H', d, e + 4)[0]
print('machine 0x%04x (%s)' % (m, {0x8664: 'x86-64', 0xaa64: 'arm64'}.get(m, '?')))
PY
done
