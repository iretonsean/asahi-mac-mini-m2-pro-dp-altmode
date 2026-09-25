#!/usr/bin/env python3
"""mkadt.py OUT.bin SIZE --dcpext0 phys:remap:size,... --dcpext1 phys:remap:size,... [--junk]
Synthetic Apple Device Tree in the raw binary layout m1n1 parses (rust/src/adt.rs):
node = u32 nprops, u32 nchildren, props, children; prop = char[32] name, u32 size (bit31 template flag), value padded to 4."""
import struct, sys, argparse
def prop(name, val, flag=0):
    return name.encode().ljust(32, b"\0") + struct.pack("<I", len(val) | flag) + val + b"\0" * (-len(val) % 4)
def node(name, props, children=()):
    ps = [prop("name", name.encode() + b"\0")] + props
    return struct.pack("<II", len(ps), len(children)) + b"".join(ps) + b"".join(children)
def segs(spec):
    out = b""
    for s in filter(None, spec.split(",")):
        phys, remap, size = (int(x, 16) for x in s.split(":"))
        out += struct.pack("<QQQII", phys, 0xdead0000 + len(out), remap, size, 0)
    return out
ap = argparse.ArgumentParser(); ap.add_argument("out"); ap.add_argument("size", type=lambda x: int(x, 0))
ap.add_argument("--dcpext0", default=""); ap.add_argument("--dcpext1", default=""); ap.add_argument("--junk", action="store_true")
a = ap.parse_args()
junk = [prop("odd-3", b"abc"), prop("template", b"\x01\x02\x03\x04\x05", 0x80000000), prop("empty", b"")] if a.junk else []
def dcp(n, spec):
    kids = [node("dart-thing", junk)] if a.junk else []
    if spec is not None: kids.append(node(f"iop-{n}-nub", junk + [prop("segment-ranges", segs(spec))]))
    return node(n, junk + [prop("compatible", b"dcpext,t602x\0")], kids)
armio = [node("sio", junk, [node("iop-sio-nub", junk)]) ] if a.junk else []
armio += [dcp("dcpext0", a.dcpext0)] + ([dcp("dcpext1", a.dcpext1)] if a.dcpext1 != "none" else [])
blob = node("device-tree", junk + [prop("compatible", b"J474sAP\0")], [node("chosen", junk), node("arm-io", junk, armio)])
assert len(blob) <= a.size, "ADT larger than region"
open(a.out, "wb").write(blob)
