#!/usr/bin/env python3
"""Add an LC_LOAD_DYLIB load command to a Mach-O so a dylib loads at launch.

This is the device-injection primitive Reticle uses to drive a debug build we
sign but do not want to recompile: `DYLD_INSERT_LIBRARIES` is stripped by the
iOS launch path (FrontBoard sanitizes DYLD_* even for get-task-allow apps) and
lldb `dlopen` is blocked on modern iOS, but a plain load command in the main
binary is honored by dyld like any other dependency.

Usage: macho_add_load.py <mach-o path> <dylib load path>
  e.g. macho_add_load.py App.app/App '@executable_path/Frameworks/Agent.framework/Agent'

After running, re-sign the dylib AND the app bundle with the SAME identity the
app already uses (matching Team ID -> library validation passes), then reinstall.

Requires `lief` (pip install lief). Handles both thin and fat Mach-O.
"""
import sys

try:
    import lief
except ImportError:
    sys.exit("lief not installed — run: pip3 install lief")


def main() -> int:
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    binpath, dylib = sys.argv[1], sys.argv[2]
    obj = lief.MachO.parse(binpath)
    slices = (
        [obj.at(i) for i in range(obj.size)]
        if isinstance(obj, lief.MachO.FatBinary)
        else [obj]
    )
    for m in slices:
        already = any(
            getattr(cmd, "name", None) == dylib for cmd in m.libraries
        )
        if already:
            print(f"already present, skipping: {dylib}")
            continue
        m.add_library(dylib)
        print(f"added LC_LOAD_DYLIB: {dylib}")
    obj.write(binpath)
    print(f"written: {binpath}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
