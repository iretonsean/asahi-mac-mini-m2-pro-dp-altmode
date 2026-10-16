#!/usr/bin/env bash
# install.sh — install the fairydust kernel as an ADDITIONAL GRUB entry. Run with sudo.
#
#   sudo scripts/install.sh            # install (idempotent)
#   sudo scripts/install.sh --remove   # remove everything this script added
#   scripts/install.sh --print-entry   # (no root) print the GRUB entry it would add
#
# WHAT IT NEVER DOES (BRIEF §11/§12/§14):
#   * no grub-install     — that rewrites the EFI binary and can land on the INTERNAL NVMe ESP.
#                           Only `grub-mkconfig -o /boot/grub/grub.cfg` is used: it writes sda3 only.
#   * no update-m1n1 / asahi-fwextract / asahi-bless — the m1n1 stage-2 payload lives on
#                           nvme0n1p4 (internal). dcpext1 is enabled instead by the fairydust
#                           kernel's own EFI stub (patches/0002-*), on top of the device tree
#                           m1n1 builds every boot, when the command line carries $DCP_OPT.
#   * no GRUB `devicetree` — a DTB snapshotted from one boot carries that boot's m1n1 values
#                           (cpu-release-addr, ADT location) into the next; see notes/HANDOFF.md.
#   * nothing under /dev/nvme0n1*, nothing to NVRAM.
#   * never touches vmlinuz-linux-asahi, initramfs-linux-asahi.img, the linux-asahi package,
#     GRUB_DEFAULT, or the existing grub.cfg.b* backups.
# Everything it writes is on the external SSD: /boot (sda3) and /usr/lib/modules (sda4).
set -euo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
KVER=${KVER:-7.1.13-fairydust-dp}
STAGE=${STAGE:-$HERE/staging}                       # make modules_install INSTALL_MOD_PATH=staging INSTALL_MOD_STRIP=1
MODSRC=$STAGE/lib/modules; [ -d "$MODSRC" ] || MODSRC=$STAGE/usr/lib/modules   # no /lib->/usr/lib symlink in a staging dir
IMAGE=${IMAGE:-$HERE/linux/arch/arm64/boot/Image}
DCP_OPT="apple_dcpext1=usb-pd@3b"; [ -r $HERE/test.cmdline ] && DCP_EXTRA=$(head -c 200 $HERE/test.cmdline | tr -cd "a-z0-9_=+ ")                   # opt-in switch read by the EFI stub fixup
INITRAMFS_PREBUILT=${INITRAMFS_PREBUILT:-$HERE/build/initramfs-linux-fairydust.img}   # optional
# Kept OUT of /boot/vmlinuz-* on purpose: grub-mkconfig's 10_linux globs /boot/vmlinuz-*,
# /boot/vmlinux-*, /boot/kernel-*, /boot/Image and makes the version_sort-highest one the
# top-level default entry — "vmlinuz-linux-fairydust" sorts above "vmlinuz-linux-asahi",
# which would silently make this kernel the unattended default.
KDIR=/boot/fairydust; VMLINUZ=$KDIR/vmlinuz; INITRD=$KDIR/initramfs.img
G_VMLINUZ=${VMLINUZ#/boot}; G_INITRD=${INITRD#/boot}   # GRUB paths: /boot is its own partition (sda3), GRUB's root
OLD_FILES=(/boot/vmlinuz-linux-fairydust /boot/initramfs-linux-fairydust.img)   # earlier layout
OLD_DTB=/boot/dtb/t6020-j474s-dp-usbpd3b.dtb; CUSTOM=/etc/grub.d/40_custom   # OLD_DTB: earlier design, removed if present
MARK_BEGIN="# >>> asahi-dp-altmode fairydust entry (managed by scripts/install.sh) >>>"
MARK_END="# <<< asahi-dp-altmode fairydust entry <<<"
STOCK_FILES=(/boot/vmlinuz-linux-asahi /boot/initramfs-linux-asahi.img)

# ---- GRUB entry: mirror the stock entry exactly, plus the stub's opt-in switch ----
render_entry() {
  local cmdline bootuuid
  cmdline=$(grep -m1 -E '^\s*linux\s+/vmlinuz-linux-asahi' /boot/grub/grub.cfg | sed -E 's/^\s*linux\s+\/vmlinuz-linux-asahi\s*//')
  [ -n "$cmdline" ] || { echo "could not read the stock kernel cmdline from grub.cfg" >&2; return 1; }
  bootuuid=$(findmnt -no UUID /boot)
  cat <<ENTRY
$MARK_BEGIN
menuentry 'Arch Linux, fairydust DP alt mode ($KVER, USB-C Back Right Middle / usb-pd@3b)' --class arch --class gnu-linux --class gnu --class os \$menuentry_id_option 'gnulinux-fairydust-dp-usbpd3b' {
	load_video
	set gfxpayload=keep
	insmod gzio
	insmod part_gpt
	insmod fat
	search --no-floppy --fs-uuid --set=root $bootuuid
	echo	'Loading Linux $KVER (EFI stub enables dcpext1 -> usb-pd@3b) ...'
	linux	$G_VMLINUZ $cmdline $DCP_OPT ${DCP_EXTRA:-}
	echo	'Loading initial ramdisk ...'
	initrd	$G_INITRD
}
$MARK_END
ENTRY
}
[ "${1:-}" = "--print-entry" ] && { render_entry; exit; }   # rootless review of what would be added

[ "$(id -u)" = 0 ] || { echo "run with sudo" >&2; exit 1; }
# the pattern is assembled from pieces so this line does not match itself
forbidden="grub""-install|update""-m1n1|nvme""0n1|asahi""-bless"
grep -qE "$forbidden" <(grep -vE '^\s*#' "$0") && { echo "FATAL: forbidden command text in $0" >&2; exit 1; }
before=$(sha256sum "${STOCK_FILES[@]}" /boot/grub/grub.cfg)

strip_custom() { awk -v b="$MARK_BEGIN" -v e="$MARK_END" '$0==b{skip=1} !skip{print} $0==e{skip=0}' "$CUSTOM"; }
regen_grub() {
  [ -e /boot/grub/grub.cfg.pre-fairydust ] || cp -p /boot/grub/grub.cfg /boot/grub/grub.cfg.pre-fairydust
  grub-mkconfig -o /boot/grub/grub.cfg
  local first first_linux restore="restore with: cp /boot/grub/grub.cfg.pre-fairydust /boot/grub/grub.cfg"
  first=$(grep -m1 -E "^menuentry" /boot/grub/grub.cfg)
  case "$first" in "menuentry 'Arch Linux'"*) ;; *) echo "FATAL: first menuentry is no longer the stock one: $first" >&2; echo "$restore" >&2; exit 1;; esac
  # the kernel entry 0 actually boots, not just its title
  first_linux=$(awk '/^menuentry /{m=1} m && /^[[:space:]]+linux[[:space:]]/{print $2; exit}' /boot/grub/grub.cfg)
  [ "$first_linux" = /vmlinuz-linux-asahi ] || { echo "FATAL: entry 0 boots '$first_linux', not /vmlinuz-linux-asahi" >&2; echo "$restore" >&2; exit 1; }
  # the fairydust kernel appears at most once (our 40_custom entry), never as an auto-generated one
  [ "$(grep -c "$G_VMLINUZ" /boot/grub/grub.cfg)" -le 1 ] || { echo "FATAL: $G_VMLINUZ referenced more than once in grub.cfg" >&2; echo "$restore" >&2; exit 1; }
}

if [ "${1:-}" = "--remove" ]; then
  strip_custom > "$CUSTOM.new" && mv "$CUSTOM.new" "$CUSTOM" && chmod +x "$CUSTOM"
  rm -f "$VMLINUZ" "$INITRD" "$OLD_DTB" "${OLD_FILES[@]}"; rmdir "$KDIR" /boot/dtb 2>/dev/null || true; rm -rf "/usr/lib/modules/$KVER"
  regen_grub; echo "removed fairydust entry and files"; exit 0
fi

# ---- preflight ----
for f in "$IMAGE" "$MODSRC/$KVER/modules.dep"; do [ -e "$f" ] || { echo "missing: $f" >&2; exit 1; }; done
[ "$(od -An -c -j 56 -N4 "$IMAGE" | tr -d ' ')" = "ARM\\0" ] || file "$IMAGE" | grep -q "ARM64 boot executable" || { echo "$IMAGE is not an arm64 kernel Image" >&2; exit 1; }
grep -aq "Linux version $KVER " "$IMAGE" || { echo "$IMAGE is not kernel $KVER" >&2; exit 1; }
grep -aq "$DCP_OPT" "$IMAGE" || { echo "$IMAGE lacks the EFI-stub dcpext1 fixup (patches/0002-*) — rebuild" >&2; exit 1; }
need=$(( ( $(stat -c %s "$IMAGE") + ${INITRAMFS_SIZE:-40000000} ) / 1024 / 1024 + 20 ))
free=$(df -m --output=avail /boot | tail -1)
[ "$free" -gt $((need + 300)) ] || { echo "/boot has ${free}M free, need ~${need}M plus 300M headroom — refusing" >&2; exit 1; }
echo "preflight ok: /boot ${free}M free, need ~${need}M; kernel $KVER"

# ---- files (additive) ----
mkdir -p "$KDIR" && install -m644 "$IMAGE" "$VMLINUZ"
rm -f "$OLD_DTB" "${OLD_FILES[@]}"; rmdir /boot/dtb 2>/dev/null || true
rm -rf "/usr/lib/modules/$KVER"; cp -a "$MODSRC/$KVER" /usr/lib/modules/
rm -f "/usr/lib/modules/$KVER/build" "/usr/lib/modules/$KVER/source"
depmod "$KVER"
# a prebuilt initramfs is only usable if built from THIS Image's modules (BTF mismatch = module load failure)
if [ -e "$INITRAMFS_PREBUILT" ] && [ "$INITRAMFS_PREBUILT" -nt "$IMAGE" ] && [ "$INITRAMFS_PREBUILT" -nt "$MODSRC/$KVER/modules.dep" ]; then
  install -m644 "$INITRAMFS_PREBUILT" "$INITRD"
else mkinitcpio -k "$KVER" -c /etc/mkinitcpio.conf -g "$INITRD"; fi

{ strip_custom; render_entry; } > "$CUSTOM.new"; mv "$CUSTOM.new" "$CUSTOM"; chmod +x "$CUSTOM"
regen_grub

# ---- post checks ----
after=$(sha256sum "${STOCK_FILES[@]}")
diff <(echo "$before" | head -2) <(echo "$after") >/dev/null || { echo "FATAL: stock kernel files changed!" >&2; exit 1; }
echo; echo "installed. GRUB entries now:"; grep -E "^menuentry|^\s+menuentry" /boot/grub/grub.cfg | sed -E "s/--class.*//"
echo "default entry: $(grep -m1 -E '^set default' /boot/grub/grub.cfg)  (GRUB_DEFAULT=$(grep -E '^GRUB_DEFAULT' /etc/default/grub | cut -d= -f2))"
df -h /boot | tail -1; ls -la "$VMLINUZ" "$INITRD"
echo; echo "Next: reboot, pick the 'fairydust DP alt mode' entry in the GRUB menu by hand, then run scripts/verify.sh."
echo "Rollback: reboot and let the default (stock) entry boot; or: sudo $0 --remove"
