#!/usr/bin/env bash
# gen-dtb.sh — build the device tree for the fairydust GRUB entry.
#
# Output: t6020-j474s-dp-usbpd3b.dtb — the LIVE device tree of this machine (which already
# carries every runtime fixup m1n1 applied at boot: memory, reserved-memory, MAC addresses,
# calibration data, dcpext0 firmware regions, ...) plus the delta that enables the second
# external display controller dcp@315c00000 (dcpext1) and wires it to the ATC PHY of the
# USB-C connector Apple labels "USB-C Back Right Middle" (usb-pd@3b, i2c 0x3b, phy@f03000000).
#
# Why not a DTB compiled from the fairydust DTS: on Asahi the DTB is patched at runtime by
# m1n1 (stage 2, internal NVMe ESP), and BRIEF §11/§12 forbid touching that payload. Loading
# our own DTB through GRUB's `devicetree` bypasses m1n1, so anything m1n1 would have done for
# the newly enabled node has to be replicated here. This script replicates, for dcpext1, what
# m1n1 v1.6.1 (src/kboot.c: dt_reserve_dcpext_firmware -> dt_reserve_asc_firmware,
# dt_set_dcp_firmware) does for a node that has a dcpextN alias:
#   * /reserved-memory/asc-firmware@<phys> {compatible="apple,asc-mem"; reg; no-map;
#       iommu-addresses = <&dcpext1 remap_iova size>;}  for each entry in the Apple Device
#       Tree property /arm-io/dcpext1/iop-dcpext1-nub/segment-ranges (remap=true, 16K-aligned)
#   * memory-region = <&asc-firmware ...> on the dcpext1 node
#   * apple,firmware-version / apple,firmware-compat (copied from dcpext0, same OS firmware)
#   * status = "okay"
# The segment-ranges live only in the Apple Device Tree, which Linux never sees, so they
# must come from a one-time `ioreg -l -w0 -p IODeviceTree -a` dump taken in macOS (--adt).
# RE-CHECK THIS LOGIC IF m1n1 IS UPDATED (silent-breakage path: m1n1 changes its carveout
# handling, this DTB keeps the old layout, dcpext1's coprocessor fails to start with no clue).
# Also regenerate after any macOS/firmware update (carveout addresses come from iBoot).
#
# The typec/DP delta itself mirrors fairydust's t600x-j375.dtsi (Mac Studio, dcpext1 on
# atcphy1) transposed to atcphy2, cross-checked against the reference DTB compiled from the
# patched fairydust source (patches/0001-*.patch, see --ref).
#
# Usage:
#   gen-dtb.sh --adt adt.plist [-o out.dtb] [--ref linux/arch/arm64/boot/dts/apple/t6020-j474s.dtb]
#   gen-dtb.sh --segments segs.txt ...      # alternative: lines "phys remap_iova size" (hex)
#   gen-dtb.sh --no-firmware-regions ...    # TESTING ONLY: dcpext1 will not start
#   gen-dtb.sh --live-dtb saved.dtb ...     # use a saved `dtc -I fs` dump instead of /proc/device-tree
# Never blesses phy@703000000 / usb-pd@38 (root SSD): hard-coded assertions below.
set -euo pipefail
export PATH="$HOME/.local/bin:$PATH" LD_LIBRARY_PATH="$HOME/.local/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

OUT="dt/t6020-j474s-dp-usbpd3b.dtb"; ADT=""; SEGS=""; REF=""; LIVE=""; NOFW=0
while [ $# -gt 0 ]; do case "$1" in
  --adt) ADT="$2"; shift 2;; --segments) SEGS="$2"; shift 2;; -o) OUT="$2"; shift 2;;
  --ref) REF="$2"; shift 2;; --live-dtb) LIVE="$2"; shift 2;; --no-firmware-regions) NOFW=1; shift;;
  *) echo "unknown arg $1" >&2; exit 2;; esac; done
[ -n "$ADT$SEGS" ] || [ "$NOFW" = 1 ] || { echo "need --adt <ioreg plist> or --segments <file> (or --no-firmware-regions for testing)" >&2; exit 2; }

# ---- stable identities (DT paths; BRIEF §13: never key on portN) ----
DCP=/soc/dcp@315c00000            # dcpext1
DCP0=/soc/dcp@289c00000           # dcpext0 (HDMI) — source of firmware-version/compat
PHY=/soc/phy@f03000000            # atcphy2
XBAR=/soc/mux@f0304c000           # atcphy2_xbar (display crossbar)
DISPEXT1_DART=/soc/iommu@315304000
DCPEXT1_DART=/soc/iommu@31530c000
DCPEXT1_MBOX=/soc/mbox@315c08000
DPAUDIO2=/soc/audio-controller@39b508000
DISPLAY=/soc/display-subsystem
DISPEXT0_DART=/soc/iommu@289304000
CONN=/soc/i2c@39b040000/usb-pd@3b/connector
ROOTDISK_PHY=/soc/phy@703000000   # usb-pd@38 "USB-C Back Left" — NEVER
PHY_TYPE_DP=6                     # include/dt-bindings/phy/phy.h
DPTX_PHY_INDEX=2                  # atcphy2 (driver: index >3 means dedicated dptx/lpdptx phy)
MUX_INDEX=2                       # t602x crossbar: 2*dispextN + port -> dispext1,0

W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
B="$W/base.dtb"
if [ -n "$LIVE" ]; then cp "$LIVE" "$B"; else dtc -q -I fs -O dtb -p 262144 -o "$B" /proc/device-tree/; fi
g() { fdtget "$B" "$@"; }         # get
p() { fdtput "$B" "$@"; }         # put
ph() { g -t x "$1" phandle; }      # phandle of node path
have() { fdtget "$B" "$1" "$2" >/dev/null 2>&1; }

# ---- assertions that we are wiring the intended connector ----
lbl=$(g -t s "$CONN" label); [ "$lbl" = "USB-C Back Right Middle" ] || { echo "FATAL: $CONN label is '$lbl'" >&2; exit 1; }
ss=$(g -t x "$CONN/ports/port@1/endpoint" remote-endpoint)
ss_path=$(dtc -q -I dtb -O dts "$B" | awk -v want="phandle = <0x$ss>;" '
  /^\t+[^ \t]+ \{$/ { n=split($0,a,"\t"); name=a[n]; sub(/ \{$/,"",name); depth=n-1; path[depth]=name }
  index($0,want) { s=""; for(i=1;i<=depth;i++) s=s "/" path[i]; print s; exit }')
case "$ss_path" in "$PHY"/*) ;; *) echo "FATAL: connector SS endpoint resolves to '$ss_path', not under $PHY" >&2; exit 1;; esac
case "$PHY" in "$ROOTDISK_PHY") echo "FATAL: refusing to bless the root-disk PHY" >&2; exit 1;; esac
[ "$(g -t s "$DCP" compatible | head -1)" = "apple,t6020-dcpext" ] || { echo "FATAL: $DCP compatible mismatch" >&2; exit 1; }
[ "$(g -t s "$XBAR" compatible)" = "apple,t6020-display-crossbar" ] || { echo "FATAL: $XBAR compatible mismatch" >&2; exit 1; }

# ---- phandles ----
maxph=$(dtc -q -I dtb -O dts "$B" | grep -oE 'phandle = <0x[0-9a-f]+>' | grep -oE '0x[0-9a-f]+' | python3 -c 'import sys;print(max(int(x,16) for x in sys.stdin.read().split()))')
newph() { maxph=$((maxph+1)); printf '%d' "$maxph"; }
DCP_PH=$((16#$(ph "$DCP"))); PHY_PH=$((16#$(ph "$PHY")))
DISPEXT0_DART_PH=$((16#$(ph "$DISPEXT0_DART"))); DISPEXT1_DART_PH=$((16#$(ph "$DISPEXT1_DART")))
if have "$XBAR" phandle; then XBAR_PH=$((16#$(ph "$XBAR"))); else XBAR_PH=$(newph); p -t u "$XBAR" phandle "$XBAR_PH"; fi
ATC2_COMMON=$(for f in /proc/device-tree/soc/power-management@*/power-controller@*/label; do [ "$(tr -d '\0' <"$f")" = atc2_common ] && { d=${f%/label}; echo "${d#/proc/device-tree}"; }; done)
[ -n "$ATC2_COMMON" ] || { echo "FATAL: atc2_common power controller not found" >&2; exit 1; }

# ---- the delta (mirrors t600x-j375.dtsi's ENABLE_DCPEXT_TYPEC block, atcphy1 -> atcphy2) ----
p -t s "$DISPEXT1_DART" status okay
p -t s "$DCPEXT1_DART"  status okay
p -t s "$DCPEXT1_MBOX"  status okay
p -t s "$XBAR"          status okay
p -t s "$DPAUDIO2"      status okay
p -t u "$DISPLAY" iommus "$DISPEXT0_DART_PH" 0 "$DISPEXT1_DART_PH" 0
p -t s "$DCP" status okay
p -t s "$DCP" apple,connector-type DP
p -t u "$DCP" apple,dptx-phy "$DPTX_PHY_INDEX"
p -t u "$DCP" phys "$PHY_PH" "$PHY_TYPE_DP"
p -t s "$DCP" phy-names dp-phy
p -t u "$DCP" mux-controls "$XBAR_PH" 0
p -t s "$DCP" mux-control-names dp-xbar
p -t u "$DCP" mux-index "$MUX_INDEX"
p -t u "$DCP" apple,firmware-version $(g -t u "$DCP0" apple,firmware-version)
p -t u "$DCP" apple,firmware-compat  $(g -t u "$DCP0" apple,firmware-compat)
p -t u "$CONN" displayport "$DCP_PH"
p -t s /aliases dcpext1 "$DCP"
fdtput -t x "$B" "$ATC2_COMMON" apple,always-on 2>/dev/null || p "$ATC2_COMMON" apple,always-on   # empty property
# (fdtput cannot write a zero-length property directly on all versions; normalise below)

# ---- dcpext1 firmware carveouts (what m1n1 dt_reserve_asc_firmware would emit) ----
if [ "$NOFW" = 0 ]; then
  if [ -n "$ADT" ]; then
    SEGS="$W/segs.txt"
    python3 "$(dirname "$0")/adt-segments.py" "$ADT" dcpext1 > "$SEGS"
  fi
  n=0; regions=()
  while read -r phys iova size; do
    [ -n "$phys" ] || continue
    phys=$((phys)); iova=$((iova)); size=$((size))
    size=$(( (size + 0x3fff) & ~0x3fff ))          # m1n1: ALIGN_UP(size, SZ_16K)
    node=$(printf '/reserved-memory/asc-firmware@%x' "$phys")
    if ! fdtget -p "$B" "$node" >/dev/null 2>&1; then
      p -c "$node"; RPH=$(newph); p -t u "$node" phandle "$RPH"
      p -t s "$node" compatible apple,asc-mem
      p -t x "$node" reg $(printf '0x%x 0x%x 0x%x 0x%x' $((phys>>32)) $((phys&0xffffffff)) $((size>>32)) $((size&0xffffffff)))
      p -t x "$node" no-map 2>/dev/null || true
    else RPH=$((16#$(ph "$node"))); fi
    # iommu-addresses = <&dcpext1 iova(u64) size(u64)>
    old=$(fdtget -t x "$B" "$node" iommu-addresses 2>/dev/null || true)
    p -t x "$node" iommu-addresses $old $(printf '0x%x 0x%x 0x%x 0x%x 0x%x' "$DCP_PH" $((iova>>32)) $((iova&0xffffffff)) $((size>>32)) $((size&0xffffffff)))
    regions+=("$RPH"); n=$((n+1))
  done < "$SEGS"
  [ "$n" -ge 1 ] || { echo "FATAL: no dcpext1 segments found in $SEGS" >&2; exit 1; }
  p -t u "$DCP" memory-region "${regions[@]}"
  echo "added $n firmware regions for dcpext1"
else
  echo "WARNING: --no-firmware-regions: dcpext1 has no firmware mappings; expect the coprocessor NOT to start" >&2
fi

# ---- tidy: drop per-boot stub artefacts that the EFI stub/GRUB regenerate anyway ----
for prop in linux,uefi-mmap-size linux,uefi-mmap-start linux,uefi-mmap-desc-size linux,uefi-mmap-desc-ver linux,uefi-system-table kaslr-seed rng-seed linux,initrd-start linux,initrd-end; do
  fdtput -d "$B" /chosen "$prop" 2>/dev/null || true
done

# ---- normalise via dtc (fixes empty props, drops padding) and emit review artefacts ----
dtc -q -I dtb -O dts "$B" | sed -E 's/apple,always-on = \[\];/apple,always-on;/; s/no-map = \[\];/no-map;/' > "$W/out.dts"
dtc -q -I dts -O dtb -o "$OUT" "$W/out.dts"
dtc -q -I dtb -O dts -o "${OUT%.dtb}.dts" "$OUT"
dtc -q -I dtb -O dts "$B" >/dev/null
diff <(dtc -q -I fs -O dts /proc/device-tree/ 2>/dev/null || dtc -q -I dtb -O dts "$LIVE") "${OUT%.dtb}.dts" | grep -E '^[<>]' > "${OUT%.dtb}.delta.txt" || true
echo "wrote $OUT ($(stat -c %s "$OUT") bytes); review ${OUT%.dtb}.dts and ${OUT%.dtb}.delta.txt"
if [ -n "$REF" ]; then
  echo "--- dcp@315c00000 in reference (fairydust source) vs generated (phandle numbers differ by design):"
  diff <(dtc -q -I dtb -O dts "$REF" | awk '/dcp@315c00000 \{/,/^\t\t\};/' | grep -vE 'phandle|remote-endpoint|iommus|mboxes|power-domains|resets|clocks|memory-region|phys =|mux-controls' | sort) \
       <(awk '/dcp@315c00000 \{/,/^\t\t\};/' "${OUT%.dtb}.dts" | grep -vE 'phandle|remote-endpoint|iommus|mboxes|power-domains|resets|clocks|memory-region|phys =|mux-controls|name =' | sort) && echo "    (identical apart from excluded reference-typed properties)"
fi
