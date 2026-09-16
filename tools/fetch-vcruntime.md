# Obtaining the Microsoft Visual C++ runtime DLLs

Games built with MSVC need the Visual C++ runtime. Those DLLs are authored by
Microsoft and are **not** redistributable under this project's license, so they
are not committed here. You supply them yourself.

Twelve files are expected in `app/Madeira/x86_64-vcruntime/`:

```
concrt140.dll              msvcp140_codecvt_ids.dll   vcruntime140.dll
msvcp140.dll               vcamp140.dll               vcruntime140_1.dll
msvcp140_1.dll             vccorlib140.dll            vcruntime140_threads.dll
msvcp140_2.dll             vcomp140.dll
msvcp140_atomic_wait.dll
```

## How to get them

Download the official x64 redistributable from Microsoft
(`VC_redist.x64.exe`) and extract it. On macOS, 7-Zip does the unpacking:

```sh
brew install sevenzip
```

Modern redistributables are **WiX Burn bundles**: the installer's resources
sit in the PE, and the actual payload is an *overlay* appended after the end
of the image. `7zz x VC_redist.x64.exe` unpacks only the resources (`0`,
`u0`..`u17` -- manifests and strings), which is why the old
`.rsrc/1033/CABINET/*.cab` recipe in this file no longer matched anything.
Verified against 14.51.36247.0 on 2026-09-16.

Carve the overlay's cabinets by their `MSCF` signature, reading each
cabinet's total size from `cbCabinet` at header offset +8:

```sh
python3 - VC_redist.x64.exe <<'EOF'
import struct, sys, os, subprocess
exe = open(sys.argv[1], 'rb').read()
pe = struct.unpack_from('<I', exe, 0x3c)[0]
# End of the last section = start of the overlay.
nsec = struct.unpack_from('<H', exe, pe + 6)[0]
opt = struct.unpack_from('<H', exe, pe + 20)[0]
sec = pe + 24 + opt
end = max(struct.unpack_from('<II', exe, sec + i*40 + 16)[0] +
          struct.unpack_from('<I', exe, sec + i*40 + 20)[0]
          for i in range(nsec))
ov = exe[end:]
os.makedirs('/tmp/vc-cabs', exist_ok=True)
pos = n = 0
while (i := ov.find(b'MSCF', pos)) >= 0:
    size = struct.unpack_from('<I', ov, i + 8)[0]
    if not size or i + size > len(ov):
        pos = i + 4
        continue
    n += 1
    open(f'/tmp/vc-cabs/{n:02d}.cab', 'wb').write(ov[i:i+size])
    print(f'cab {n:02d}  offset {i}  size {size}')
    pos = i + size
EOF
```

Two cabinets come out. The small one repeats the resources; the large one
holds six payloads -- three `.msi` (OLE compound, magic `d0cf11e0`) and three
cabinets (`4d534346`), one per architecture. Take the **amd64** one, whose
members are named `<name>.dll_amd64`:

```sh
7zz x /tmp/vc-cabs/02.cab -o/tmp/vc-payload -y
for c in /tmp/vc-payload/a*; do
    7zz l "$c" 2>/dev/null | grep -q 'vcruntime140.dll_amd64' && AMD64="$c"
done
7zz x "$AMD64" -o/tmp/vc-dlls -y
mkdir -p app/Madeira/x86_64-vcruntime
for f in /tmp/vc-dlls/*.dll_amd64; do
    b=$(basename "$f"); cp "$f" "app/Madeira/x86_64-vcruntime/${b%_amd64}"
done
```

Copying out of the cabinet preserves the bytes, so the files stay exactly as
Microsoft shipped them. If a future redistributable changes shape again, the
goal is unchanged: the twelve files above, **byte-for-byte**.

## Do not modify them

Microsoft's redistribution permission covers the eligible files *unmodified*.
In particular, do not strip Authenticode signatures. You can check that a file
still carries its signature payload:

```sh
python3 - app/Madeira/x86_64-vcruntime/*.dll <<'EOF'
import struct, sys
for path in sys.argv[1:]:
    d = open(path, 'rb').read()
    pe = struct.unpack_from('<I', d, 0x3c)[0]
    off, size = struct.unpack_from('<II', d, pe + 24 + 112 + 4*8)
    ok = size and off + size <= len(d)
    print(('signed  ' if ok else 'UNSIGNED'), path)
EOF
```

A file whose certificate offset equals its own length has had the signature
truncated off and is no longer an unmodified Microsoft binary.

Checking the machine word at the same time is worth the two extra lines --
the redistributable ships arm64 and amd64 payloads side by side under nearly
identical names, and an arm64 `vcruntime140.dll` would load in Wine and fail
far from here. Expect `0x8664` for all twelve:

```sh
python3 - app/Madeira/x86_64-vcruntime/*.dll <<'EOF'
import struct, sys
for path in sys.argv[1:]:
    d = open(path, 'rb').read()
    pe = struct.unpack_from('<I', d, 0x3c)[0]
    machine = struct.unpack_from('<H', d, pe + 4)[0]
    print(hex(machine), path)
EOF
```
