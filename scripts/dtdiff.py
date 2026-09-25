#!/usr/bin/env python3
"""dtdiff.py A.dts B.dts : property-level diff of two decompiled DTs with phandle refs resolved to node paths."""
import re, sys
PH_PROPS = re.compile(r'^(power-domains|dmas|remote-endpoint|iommus|clocks|mboxes|phys|.*-gpios|gpios|interrupt-parent|memory-region|pinctrl-\d+|resets|reset-domains|mux-controls|apple,.*-opp|operating-points-v2|displayport|interrupts-extended|nvmem-cells|apple,bw-.*|apple,.*-dart|sound-dai|cpus|cpu|next-level-cache|phandle|iommu-map|msi-parent|apple,dcp|apple,piodma|apple,dptx-phy-ref|power-supply|.*-supply|thermal-sensors|cooling-device|trip|apple,sio|apple,aop|apple,.*)$')
def parse(fn):
    props = {}; ph = {}; stack = []
    for line in open(fn):
        s = line.strip()
        m = re.match(r'^([^ ]+) \{$', s)
        if m: stack.append(m.group(1)); continue
        if s == '};': stack.pop(); continue
        m = re.match(r'^([^ =;]+)(?: = (.*))?;$', s)
        if m and stack:
            path = '/' + '/'.join(stack[1:])
            props[(path, m.group(1))] = m.group(2) or ''
            if m.group(1) == 'phandle': ph[int(m.group(2).strip('<>'), 16)] = path
    return props, ph
def norm(props, ph):
    out = {}
    for (path, name), v in props.items():
        if name == 'phandle': continue
        if PH_PROPS.match(name) and v.startswith('<'):
            v = re.sub(r'0x[0-9a-f]+', lambda m: ph.get(int(m.group(0),16), m.group(0)) if int(m.group(0),16) > 0x10 else m.group(0), v)
        out[(path, name)] = v
    return out
a = norm(*parse(sys.argv[1])); b = norm(*parse(sys.argv[2]))
for k in sorted(set(a) | set(b)):
    if a.get(k) != b.get(k):
        print(f"{k[0]} :: {k[1]}\n   - {a.get(k, '<absent>')[:200]}\n   + {b.get(k, '<absent>')[:200]}")
