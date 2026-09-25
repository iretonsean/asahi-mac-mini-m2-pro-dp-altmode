#!/usr/bin/env bash
# verify.sh — post-boot checks for the DP alt-mode project. Read-only, no root needed.
# Run on EVERY boot (stock or fairydust kernel). Regression checks come first (BRIEF §8),
# then the DP success criteria (BRIEF §7) which are only expected to pass on the fairydust
# kernel with the custom DTB. Ports are resolved by i2c address / DT path (BRIEF §13), never
# by /sys/class/typec/portN.
cd "$(dirname "$0")"; . ./lib-typec-port.sh
DP_I2C=3b; ROOT_I2C=38; KBD_I2C=3f
declare -A USBCTRL=([38]=702280000 [3f]=b02280000 [3b]=f02280000 [3c]=1302280000)
pass=0; fail=0
ok()   { printf '  PASS  %s\n' "$*"; pass=$((pass+1)); }
bad()  { printf '  FAIL  %s\n' "$*"; fail=$((fail+1)); }
info() { printf '  info  %s\n' "$*"; }
check() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi; }
port_of_sysdev() { # print i2c addr of the USB-C port whose xhci hosts sysfs device $1
  local rp; rp=$(readlink -f "$1"); for a in "${!USBCTRL[@]}"; do case "$rp" in *"/${USBCTRL[$a]}.usb/"*) echo "$a"; return;; esac; done; echo "?"; }

stub=$(tr -d '\0' 2>/dev/null < /proc/device-tree/chosen/asahi-dp-altmode,dcpext1 || echo "not run (option absent or stock kernel)")
echo "== kernel: $(uname -r)   dcpext1 alias: $([ -e /proc/device-tree/aliases/dcpext1 ] && echo yes || echo no)   EFI-stub fixup: $stub"
echo "== regression checks (must pass on every kernel)"
rootdev=$(findmnt -no SOURCE / ); bootdisk=$(lsblk -no PKNAME "$(findmnt -no SOURCE /boot)" 2>/dev/null)
check "root mounted from LUKS mapper ($rootdev)" sh -c 'case "$0" in /dev/mapper/cryptroot*) exit 0;; esac; exit 1' "$rootdev"
check "/boot on the external SSD ($bootdisk)" test -n "$bootdisk"
p=$(port_of_sysdev "/sys/block/$bootdisk"); check "boot SSD hangs off the i2c-0x$ROOT_I2C port ($(typec_label_by_i2c $ROOT_I2C)) [seen: 0x$p]" test "$p" = "$ROOT_I2C"
h=$(ls /sys/class/drm/card*-HDMI-A-1/status 2>/dev/null | head -1); check "HDMI connector connected" test "$(cat "$h" 2>/dev/null)" = connected
check "HDMI advertises modes (top: $(head -1 "${h%status}modes" 2>/dev/null))" sh -c '[ -s "$0" ]' "${h%status}modes"
check "asahi GPU driver bound" sh -c 'ls /sys/bus/platform/drivers/asahi/ | grep -q gpu'
check "render node present" test -e /dev/dri/renderD128
check "Apple keyboard enumerated" sh -c 'lsusb | grep -qi "apple.*keyboard\|05ac:"'
kbd=$(for d in /sys/bus/usb/devices/*; do grep -qs '^05ac$' "$d/idVendor" && echo "$d"; done | head -1)
[ -n "$kbd" ] && { p=$(port_of_sysdev "$kbd"); check "keyboard on i2c-0x$KBD_I2C port [seen: 0x$p]" test "$p" = "$KBD_I2C"; }
ncpu_dt=$(ls -d /proc/device-tree/cpus/cpu@* 2>/dev/null | wc -l)
check "all $ncpu_dt CPUs from the DT are online ($(nproc --all) online)" test "$(nproc --all)" = "$ncpu_dt"
check "HDMI uses dedicated dptx phy (not an ATC PHY)" test "$(od -An -tx4 --endian=big /proc/device-tree/soc/dcp@289c00000/phys | tr -d ' ')" = "$(od -An -tx4 --endian=big /proc/device-tree/soc/phy@39c000000/phandle | tr -d ' ')"
if command -v hyprctl >/dev/null && [ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]; then info "hyprctl monitors:"; hyprctl monitors 2>/dev/null | grep -E '^Monitor|^\s+[0-9]+x[0-9]+@' | sed 's/^/        /'; fi

echo "== DP alt-mode success criteria (BRIEF §7) on i2c-0x$DP_I2C '$(typec_label_by_i2c $DP_I2C)'"
case "$stub" in applied*) ok "0. EFI-stub fixup applied ($stub)";; "not run"*) info "0. EFI-stub fixup did not run — expected on the stock entry only";; *) bad "0. EFI-stub fixup refused: $stub";; esac
check "1. dcp@315c00000 bound to apple-dcp" test -e /sys/bus/platform/drivers/apple-dcp/315c00000.dcp
dpc=$(ls -d /sys/class/drm/card*-DP-* 2>/dev/null | head -1)
check "2. a DP connector exists ($dpc)" test -n "$dpc"
[ -n "$dpc" ] && check "2b. DP connector status=connected ($(cat $dpc/status 2>/dev/null))" test "$(cat $dpc/status)" = connected
check "3. typec_displayport module loaded" sh -c 'lsmod | grep -q "^typec_displayport"'
ps=$(typec_sysfs_by_i2c $DP_I2C); check "4. partner on 0x$DP_I2C advertises DP altmode (svid ff01)" sh -c "grep -qs ff01 $ps-partner/$ps-partner.*/svid"
check "4b. DP altmode active on 0x$DP_I2C" sh -c "for d in $ps-partner/*/svid; do grep -qs ff01 \$d && grep -qs yes \$(dirname \$d)/active && exit 0; done; exit 1"
check "5. VIA billboard device (2109:0103) is GONE" sh -c '! lsusb -d 2109:0103 | grep -q .'
if command -v hyprctl >/dev/null && [ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]; then check "6. hyprctl lists a DP monitor" sh -c 'hyprctl monitors | grep -q "^Monitor DP-"'; fi
echo "== hints from dmesg (may need root):"
dmesg 2>/dev/null | grep -iE "315c00000|dispext1|dp-xbar|dpxbar|dptx_connect|typec_displayport|displayport|cd321x.*hpd|asc-mem" | tail -15 | sed 's/^/    /'
info "under DP pin assignment C USB on this port drops to 2.0 — SuperSpeed loss there is expected (PR #289)."
echo "== $pass passed, $fail failed"; [ "$fail" -eq 0 ]
