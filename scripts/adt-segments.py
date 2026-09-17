#!/usr/bin/env python3
"""adt-segments.py ADT_DUMP NODE  ->  lines "0x<phys> 0x<remap_iova> 0x<size>" for NODE's IOP nub.

ADT_DUMP is the output of, in macOS:   ioreg -l -w0 -p IODeviceTree -a > adt.plist
(XML plist; nested dicts with IORegistryEntryName / IORegistryEntryChildren, data as base64).
NODE is e.g. dcpext1 -> looks for the child "iop-dcpext1-nub" and its "segment-ranges".
Layout (m1n1 src/adt.h struct adt_segment_ranges, packed, little-endian):
    u64 phys; u64 iova; u64 remap; u32 size; u32 unk;   (32 bytes per entry)
m1n1 uses `remap` as the DART IOVA for dcpext nodes (dt_reserve_dcpext_firmware passes remap=true).
"""
import plistlib, struct, sys

def walk(node, path):
    name = node.get("IORegistryEntryName") or node.get("name", b"?")
    if isinstance(name, bytes): name = name.rstrip(b"\0").decode(errors="replace")
    yield path + [name], node
    for c in node.get("IORegistryEntryChildren", []) or []:
        yield from walk(c, path + [name])

def main():
    dump, want = sys.argv[1], sys.argv[2]
    with open(dump, "rb") as f:
        root = plistlib.load(f)
    roots = root if isinstance(root, list) else [root]
    target = f"iop-{want}-nub"
    hits = [(p, n) for r in roots for p, n in walk(r, []) if p[-1] == target]
    if not hits:
        sys.exit(f"{target} not found in {dump}")
    path, node = hits[0]
    data = node.get("segment-ranges")
    if not isinstance(data, (bytes, bytearray)) or len(data) % 32:
        sys.exit(f"segment-ranges missing/odd size in {'/'.join(path)}")
    print(f"# {'/'.join(path)}: {len(data)//32} segments", file=sys.stderr)
    for i in range(0, len(data), 32):
        phys, iova, remap, size, unk = struct.unpack("<QQQII", data[i:i+32])
        print(f"0x{phys:x} 0x{remap:x} 0x{size:x}")
        print(f"#   phys=0x{phys:x} iova=0x{iova:x} remap=0x{remap:x} size=0x{size:x}", file=sys.stderr)

if __name__ == "__main__":
    main()
