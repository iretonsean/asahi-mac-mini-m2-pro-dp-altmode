#!/usr/bin/env bash
# run-tests.sh — exercise the EFI-stub dcpext1 fixup (linux/drivers/firmware/efi/libstub/apple-dcpext.c)
# in userspace against THIS machine's live FDT (m1n1's real output, incl. its dcpext0 carveouts) and
# synthetic ADTs. Cross-checks the result against scripts/gen-dtb.sh (independent implementation).
# Rootless. Builds ./harness with ASan/UBSan.
set -euo pipefail
cd "$(dirname "$0")"; ROOT=$(cd ../.. && pwd); L=$ROOT/linux/scripts/dtc/libfdt
export PATH="$HOME/.local/bin:$PATH" LD_LIBRARY_PATH="$HOME/.local/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
gcc -g -O1 -Wall -Wextra -Wno-sign-compare -Wno-unused-parameter -fsanitize=address,undefined -fno-sanitize-recover=all \
    -DAPPLE_DCPEXT_USERSPACE_TEST -I. -I"$L" -o "$T/harness" harness.c "$ROOT/linux/drivers/firmware/efi/libstub/apple-dcpext.c" \
    "$L"/fdt.c "$L"/fdt_ro.c "$L"/fdt_rw.c "$L"/fdt_wip.c "$L"/fdt_strerror.c
export ASAN_OPTIONS=detect_leaks=0
H="$T/harness"; OPT="root=x apple_dcpext1=usb-pd@3b quiet"
BASE=${BASE:-$T/base.dtb}; [ -e "$BASE" ] || dtc -q -I fs -O dtb -o "$BASE" /proc/device-tree/
ADT_SZ=$(fdtget -t x "$BASE" "/reserved-memory/$(for n in $(fdtget -l "$BASE" /reserved-memory); do [ "$(fdtget -ts "$BASE" /reserved-memory/$n label 2>/dev/null)" = adt ] && echo $n; done)" reg | awk '{print "0x"$4}')
# dcpext0 carveouts exactly as m1n1 emitted them (ADT order = memory-region order)
D0=""; for ph in $(fdtget -t x "$BASE" /soc/dcp@289c00000 memory-region); do
  for n in $(fdtget -l "$BASE" /reserved-memory); do p=/reserved-memory/$n
    [ "$(fdtget -t x "$BASE" $p phandle 2>/dev/null)" = "$ph" ] || continue
    case $n in asc-firmware@*) set -- $(fdtget -t x "$BASE" $p iommu-addresses); D0+="${n#asc-firmware@}:$(printf %x $(( (0x$2<<32) | 0x$3 ))):$(printf %x $(( (0x$4<<32) | 0x$5 ))),";; esac
  done; done
D1="10001400000:10040000000:603f00,103e2448000:100c0000000:1000000"   # plausible dcpext1 layout in a real gap of the live map (size 1 unaligned on purpose; the 2nd ends exactly where a dcpext0 carveout starts)
pass=0; fail=0; t() { if "$@"; then echo "  PASS $desc"; pass=$((pass+1)); else echo "  FAIL $desc"; fail=$((fail+1)); fi; }
status() { fdtget -ts "$1" /chosen asahi-dp-altmode,dcpext1 2>/dev/null || echo "<none>"; }
same_as_base() { diff <(dtc -q -I dtb -O dts "$BASE" | grep -v 'asahi-dp-altmode,dcpext1') <(dtc -q -I dtb -O dts "$1" | grep -v 'asahi-dp-altmode,dcpext1') >/dev/null; }
echo "base: $BASE  adt region: $ADT_SZ bytes  dcpext0 (from m1n1): $D0"

python3 mkadt.py "$T/good.adt" "$ADT_SZ" --dcpext0 "$D0" --dcpext1 "$D1" --junk
"$H" "$BASE" "$T/good.adt" "$OPT" "$T/good.dtb" >"$T/log"
desc="happy path: status 'applied: 2 carveouts' ($(status "$T/good.dtb"))"; t test "$(status "$T/good.dtb")" = "applied: 2 carveouts, mux-index 2"
# independent implementation: gen-dtb.sh with the same segments on the same base
printf '0x%s 0x%s 0x%s\n' $(echo "$D1" | tr ',:' '  ') > "$T/segs"
"$ROOT/scripts/gen-dtb.sh" --live-dtb "$BASE" --segments "$T/segs" -o "$T/gen.dtb" >/dev/null
dtc -q -s -I dtb -O dts "$T/gen.dtb" > "$T/gen.dts"; dtc -q -s -I dtb -O dts "$T/good.dtb" | grep -v 'asahi-dp-altmode,dcpext1' > "$T/stub.dts"
python3 "$ROOT/scripts/dtdiff.py" "$T/gen.dts" "$T/stub.dts" | grep -vE '^/chosen :: (linux,|kaslr|rng)|^   [-+]' > "$T/xdiff" || true
desc="stub result == gen-dtb.sh result (phandle-resolved), ignoring stub-owned /chosen props"; t test ! -s "$T/xdiff"
[ -s "$T/xdiff" ] && cat "$T/xdiff" | head -20
desc="fdt_check passes (dtc re-parses output)"; t dtc -q -I dtb -O dtb -o /dev/null "$T/good.dtb"
desc="new carveout size aligned up to 16K like m1n1"; t test "$(fdtget -t x "$T/good.dtb" /reserved-memory/asc-firmware@10001400000 reg)" = "100 1400000 0 604000"
diff <(dtc -q -I dtb -O dts "$BASE" | awk '/\tphy@703000000 \{/,/^\t\t\};/') <(dtc -q -I dtb -O dts "$T/good.dtb" | awk '/\tphy@703000000 \{/,/^\t\t\};/') >/dev/null && { echo "  PASS phy@703000000 byte-identical"; pass=$((pass+1)); } || { echo "  FAIL phy@703000000 changed"; fail=$((fail+1)); }

"$H" "$BASE" "$T/good.adt" "root=x apple_dcpext1=usb-pd@3bx" "$T/o.dtb" >/dev/null
desc="no opt-in (near-miss option) -> FDT untouched, no status"; t eval 'same_as_base "$T/o.dtb" && [ "$(status "$T/o.dtb")" = "<none>" ]'
"$H" "$BASE" "$T/good.adt" "" "$T/o.dtb" >/dev/null
desc="empty cmdline -> untouched"; t same_as_base "$T/o.dtb"

python3 mkadt.py "$T/x.adt" "$ADT_SZ" --dcpext0 "${D0%%,*},$(echo "$D0" | cut -d, -f2 | awk -F: '{printf "%s:%x:%s", $1, strtonum("0x"$2)+0x4000, $3}'),$(echo "$D0" | cut -d, -f3)" --dcpext1 "$D1"
"$H" "$BASE" "$T/x.adt" "$OPT" "$T/o.dtb" >/dev/null
desc="ADT dcpext0 disagrees with m1n1 -> refused, untouched ($(status "$T/o.dtb"))"; t eval 'same_as_base "$T/o.dtb" && status "$T/o.dtb" | grep -q "disagree"'
python3 mkadt.py "$T/x.adt" "$ADT_SZ" --dcpext0 "$D0" --dcpext1 "none"
"$H" "$BASE" "$T/x.adt" "$OPT" "$T/o.dtb" >/dev/null
desc="ADT without dcpext1 -> refused ($(status "$T/o.dtb"))"; t eval 'same_as_base "$T/o.dtb" && status "$T/o.dtb" | grep -q "no dcpext1"'
ov=$(echo "$D0" | cut -d, -f1 | cut -d: -f1)
python3 mkadt.py "$T/x.adt" "$ADT_SZ" --dcpext0 "$D0" --dcpext1 "$ov:140000000:4000"
"$H" "$BASE" "$T/x.adt" "$OPT" "$T/o.dtb" >/dev/null
desc="dcpext1 segment overlapping dcpext0 carveout -> refused ($(status "$T/o.dtb"))"; t eval 'same_as_base "$T/o.dtb" && status "$T/o.dtb" | grep -q overlaps'
# a segment m1n1 would share with dcpext0 (same phys and size, e.g. the firmware text) reuses m1n1's node
sh=$(echo "$D0" | cut -d, -f1); shp=${sh%%:*}; shs=${sh##*:}
python3 mkadt.py "$T/x.adt" "$ADT_SZ" --dcpext0 "$D0" --dcpext1 "$shp:10040000000:$shs,${D1#*,}"
"$H" "$BASE" "$T/x.adt" "$OPT" "$T/sh.dtb" >/dev/null
desc="dcpext1 segment shared with dcpext0 (exact) -> applied ($(status "$T/sh.dtb"))"; t test "$(status "$T/sh.dtb")" = "applied: 2 carveouts, mux-index 2"
shn=/reserved-memory/asc-firmware@$shp
desc="shared node keeps dcpext0's entry and gains dcpext1's (2 iommu-addresses entries)"; t eval '[ "$(fdtget -t x "$T/sh.dtb" $shn iommu-addresses | wc -w)" = 10 ] && [ "$(fdtget -t x "$T/sh.dtb" $shn iommu-addresses | cut -d" " -f1-5)" = "$(fdtget -t x "$BASE" $shn iommu-addresses)" ]'
desc="shared node: no duplicate node, dcp@315c00000 memory-region points at it"; t eval '[ "$(fdtget -l "$T/sh.dtb" /reserved-memory | grep -c "^asc-firmware@$shp$")" = 1 ] && fdtget -t x "$T/sh.dtb" /soc/dcp@315c00000 memory-region | grep -qw "$(fdtget -t x "$BASE" $shn phandle)"'
desc="shared node reg unchanged"; t test "$(fdtget -t x "$T/sh.dtb" $shn reg)" = "$(fdtget -t x "$BASE" $shn reg)"
"$H" "$BASE" - "$OPT" "$T/o.dtb" >/dev/null
desc="ADT region unmapped -> refused ($(status "$T/o.dtb"))"; t eval 'same_as_base "$T/o.dtb" && status "$T/o.dtb" | grep -q "does not parse"'
"$H" "$T/good.dtb" "$T/good.adt" "$OPT" "$T/o.dtb" >/dev/null
desc="second application -> skipped, no double carveouts ($(status "$T/o.dtb"))"; t eval 'status "$T/o.dtb" | grep -q "already present"'
cp "$BASE" "$T/nb.dtb"; fdtput -ts "$T/nb.dtb" / compatible apple,j474s-not apple,t6020 apple,arm-platform
"$H" "$T/nb.dtb" "$T/good.adt" "$OPT" "$T/o.dtb" >/dev/null
desc="other machine -> skipped ($(status "$T/o.dtb"))"; t eval 'status "$T/o.dtb" | grep -q "not apple,j474s"'
cp "$BASE" "$T/nb.dtb"; ep=$(fdtget -t x "$BASE" /soc/phy@703000000/ports/port@0/endpoint phandle 2>/dev/null || true)
if [ -n "$ep" ]; then fdtput -t x "$T/nb.dtb" /soc/i2c@39b040000/usb-pd@3b/connector/ports/port@1/endpoint remote-endpoint "$ep"
  "$H" "$T/nb.dtb" "$T/good.adt" "$OPT" "$T/o.dtb" >/dev/null
  desc="connector rewired to root-disk PHY -> refused ($(status "$T/o.dtb"))"; t eval 'status "$T/o.dtb" | grep -q "not under phy@f03000000"'; fi

# fuzz: truncations and byte flips of the ADT must never crash (ASan/UBSan abort) and never half-apply
python3 - "$T/good.adt" "$T/fz" <<'PY'
import random, sys, os
b = open(sys.argv[1], "rb").read(); os.makedirs(sys.argv[2], exist_ok=True); r = random.Random(1)
for i in range(300):
    x = bytearray(b)
    if i % 3 == 0: x = x[:r.randrange(len(x))]
    else:
        for _ in range(r.randrange(1, 8)): x[r.randrange(len(x))] = r.randrange(256)
    open(f"{sys.argv[2]}/{i}.adt", "wb").write(x)
PY
fz_bad=0; fz_applied=0
for f in "$T"/fz/*.adt; do
  "$H" "$BASE" "$f" "$OPT" "$T/o.dtb" >/dev/null 2>"$T/err" || { fz_bad=$((fz_bad+1)); head -3 "$T/err"; continue; }
  s=$(status "$T/o.dtb"); case "$s" in applied*) fz_applied=$((fz_applied+1));; *MID-WRITE*) fz_bad=$((fz_bad+1));; *) same_as_base "$T/o.dtb" || fz_bad=$((fz_bad+1));; esac
done
desc="fuzz: 300 mutated ADTs, no crash/overread, refusals leave FDT untouched ($fz_applied still applied)"; t test "$fz_bad" = 0
echo "== $pass passed, $fail failed"; [ "$fail" = 0 ]
