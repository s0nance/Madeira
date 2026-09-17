#!/usr/bin/env python3
"""Write a Windows .lnk so Wine's Start menu can launch something.

Madeira starts programs through its own launcher, which calls
NtCreateUserProcess directly. Nothing ever puts an entry in the prefix's Start
menu, so the Wine virtual desktop comes up with a 20-pixel taskbar, a Start
button and nothing behind it -- a program you launched from Madeira cannot be
restarted from inside the desktop, because there is nothing there to click.

This writes the smallest .lnk that Wine's loader actually resolves. Checked
against wine/dlls/shell32/shelllink.c rather than guessed:

  - IShellLink::Load tests SLDF_HAS_ID_LIST and SLDF_HAS_LINK_INFO
    independently (shelllink.c:783 and :792), so a LinkInfo-only shortcut with
    no ID list resolves fine. That matters: an ID list would mean synthesising
    shell item PIDLs, which is a great deal of format for no gain here.
  - Stream_LoadLocation reads dwTotalSize, dwVolTableOfs and dwLocalPathOfs,
    and tolerates a zero volume table. The volume table is written anyway, so
    the file matches what real shortcuts look like.

Usage:
  make-shortcut.py <out.lnk> <target> [--args ARGS] [--workdir DIR] [--name N]
"""
import struct
import sys

HEADER_SIZE = 0x4C
LINK_CLSID = bytes([0x01, 0x14, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00,
                    0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46])

HAS_LINK_INFO = 0x00000002
HAS_NAME      = 0x00000004
HAS_WORKDIR   = 0x00000010
HAS_ARGS      = 0x00000020
IS_UNICODE    = 0x00000080

FILE_ATTRIBUTE_NORMAL = 0x00000080
DRIVE_FIXED = 3
SW_SHOWNORMAL = 1


def counted_unicode(s):
    """StringData: a u16 character count then the UTF-16LE chars, no NUL."""
    raw = s.encode("utf-16-le")
    return struct.pack("<H", len(s)) + raw


def link_info(local_path, volume_label=""):
    """LinkInfo with VolumeIDAndLocalBasePath, the layout Wine's
    Stream_LoadLocation expects. Offsets are from the start of this block, so
    they are computed after the sizes are known rather than hardcoded."""
    header_size = 0x1C                      # seven DWORDs, see LOCATION_INFO
    vol_label = volume_label.encode("ascii", "replace") + b"\0"
    volume = struct.pack("<IIII", 16 + len(vol_label), DRIVE_FIXED, 0, 0x10) + vol_label
    path = local_path.encode("ascii", "replace") + b"\0"
    suffix = b"\0"                           # CommonPathSuffix, empty

    vol_ofs = header_size
    path_ofs = vol_ofs + len(volume)
    suffix_ofs = path_ofs + len(path)
    total = suffix_ofs + len(suffix)

    return struct.pack("<IIIIIII",
                       total, header_size, 0x00000001,
                       vol_ofs, path_ofs, 0, suffix_ofs) + volume + path + suffix


def make_lnk(target, args="", workdir="", name=""):
    flags = HAS_LINK_INFO | IS_UNICODE
    if name:    flags |= HAS_NAME
    if workdir: flags |= HAS_WORKDIR
    if args:    flags |= HAS_ARGS

    out = struct.pack("<I", HEADER_SIZE) + LINK_CLSID
    out += struct.pack("<II", flags, FILE_ATTRIBUTE_NORMAL)
    out += b"\0" * 24                        # creation / access / write times
    out += struct.pack("<III", 0, 0, SW_SHOWNORMAL)
    out += struct.pack("<HHII", 0, 0, 0, 0)  # hotkey + three reserved fields
    assert len(out) == HEADER_SIZE, len(out)

    out += link_info(target)
    # StringData, in the order the format fixes: NAME, RELATIVE_PATH,
    # WORKING_DIR, ARGUMENTS, ICON_LOCATION -- only the flagged ones.
    if name:    out += counted_unicode(name)
    if workdir: out += counted_unicode(workdir)
    if args:    out += counted_unicode(args)
    out += struct.pack("<I", 0)              # terminal block
    return out


def main(argv):
    if len(argv) < 3:
        print(__doc__.strip(), file=sys.stderr)
        return 1
    out_path, target = argv[1], argv[2]
    args = workdir = name = ""
    i = 3
    while i < len(argv) - 1:
        if argv[i] == "--args":    args = argv[i + 1]
        elif argv[i] == "--workdir": workdir = argv[i + 1]
        elif argv[i] == "--name":  name = argv[i + 1]
        else:
            print("unknown option: %s" % argv[i], file=sys.stderr)
            return 1
        i += 2

    blob = make_lnk(target, args, workdir, name)
    with open(out_path, "wb") as f:
        f.write(blob)
    print("%s: %d bytes -> %s%s" % (out_path, len(blob), target,
                                    (" " + args) if args else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
