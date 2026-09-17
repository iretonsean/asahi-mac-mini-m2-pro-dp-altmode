#!/usr/bin/env bash
# install.sh — install the fairydust kernel as an ADDITIONAL GRUB entry. Run with sudo.
#
#   sudo scripts/install.sh            # install (idempotent)
#   sudo scripts/install.sh --remove   # remove everything this script added
#
# WHAT IT NEVER DOES (BRIEF §11/§12/§14):
#   * no grub-install     — that rewrites the EFI binary and can land on the INTERNAL NVMe ESP.
#                           Only `grub-mkconfig -o /boot/grub/grub.cfg` is used: it writes sda3 only.
#   * no update-m1n1 / asahi-fwextract / asahi-bless — the m1n1 stage-2 payload lives on
#                           nvme0n1p4 (internal). The custom device tree goes in via GRUB's
#                           `devicetree` directive from /boot (sda3, external) instead.
#   * nothing under /dev/nvme0n1*, nothing to NVRAM.
#   * never touches vmlinuz-linux-asahi, initramfs-linux-asahi.img, the linux-asahi package,
#     GRUB_DEFAULT, or the existing grub.cfg.b* backups.
# Everything it writes is on the external SSD: /boot (sda3) and /usr/lib/modules (sda4).
set -euo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
KVER=${KVER:-7.1.13-fairydust-dp}
STAGE=${STAGE:-$HERE/staging}                       # make modules_install INSTALL_MOD_PATH=staging
IMAGE=${IMAGE:-$HERE/linux/arch/arm64/boot/Image}
DTB=${DTB:-$HERE/dt/t6020-j474s-dp-usbpd3b.dtb}
INITRAMFS_PREBUILT=${INITRAMFS_PREBUILT:-$HERE/build/initramfs-linux-fairydust.img}   # optional
VMLINUZ=/boot/vmlinuz-linux-fairydust; INITRD=/boot/initramfs-linux-fairydust.img
DTB_DST=/boot/dtb/t6020-j474s-dp-usbpd3b.dtb; CUSTOM=/etc/grub.d/40_custom
MARK_BEGIN="# >>> asahi-dp-altmode fairydust entry (managed by scripts/install.sh) >>>"
MARK_END="# <<< asahi-dp-altmode fairydust entry <<<"
STOCK_FILES=(/boot/vmlinuz-linux-asahi /boot/initramfs-linux-asahi.img)

[ "$(id -u)" = 0 ] || { echo "run with sudo" >&2; exit 1; }
grep -qE "grub-install|update-m1n1|nvme0n1|asahi-bless" <(grep -vE '^\s*#' "$0") && { echo "FATAL: forbidden command text in $0" >&2; exit 1; }
before=$(sha256sum "${STOCK_FILES[@]}" /boot/grub/grub.cfg)

strip_custom() { awk -v b="$MARK_BEGIN" -v e="$MARK_END" '$0==b{skip=1} !skip{print} $0==e{skip=0}' "$CUSTOM"; }
regen_grub() {
  [ -e /boot/grub/grub.cfg.pre-fairydust ] || cp -p /boot/grub/grub.cfg /boot/grub/grub.cfg.pre-fairydust
  grub-mkconfig -o /boot/grub/grub.cfg
  first=$(grep -m1 -E "^menuentry" /boot/grub/grub.cfg)
  case "$first" in "menuentry 'Arch Linux'"*) ;; *) echo "FATAL: first menuentry is no longer the stock one: $first" >&2; echo "restore with: cp /boot/grub/grub.cfg.pre-fairydust /boot/grub/grub.cfg" >&2; exit 1;; esac
  grep -q "vmlinuz-linux-asahi" /boot/grub/grub.cfg || { echo "FATAL: stock kernel missing from grub.cfg" >&2; exit 1; }
}

if [ "${1:-}" = "--remove" ]; then
  strip_custom > "$CUSTOM.new" && mv "$CUSTOM.new" "$CUSTOM" && chmod +x "$CUSTOM"
  rm -f "$VMLINUZ" "$INITRD" "$DTB_DST"; rm -rf "/usr/lib/modules/$KVER"
  regen_grub; echo "removed fairydust entry and files"; exit 0
fi

# ---- preflight ----
for f in "$IMAGE" "$DTB" "$STAGE/usr/lib/modules/$KVER/modules.dep"; do [ -e "$f" ] || { echo "missing: $f" >&2; exit 1; }; done
[ "$(file -b "$DTB" | cut -c1-19)" = "Device Tree Blob v" ] || [ "$(od -An -tx1 -N4 "$DTB" | tr -d ' ')" = d00dfeed ] || { echo "$DTB is not a DTB" >&2; exit 1; }
grep -q "^dcpext1 = \"/soc/dcp@315c00000\"" <(fdtget -p "$DTB" /aliases 2>/dev/null | sed 's/^/dummy /' ; ${HOME:-/root}/.local/bin/fdtget "$DTB" /aliases dcpext1 2>/dev/null | sed 's/^/dcpext1 = "/; s/$/"/') 2>/dev/null || true
need=$(( ( $(stat -c %s "$IMAGE") + ${INITRAMFS_SIZE:-40000000} + $(stat -c %s "$DTB") ) / 1024 / 1024 + 20 ))
free=$(df -m --output=avail /boot | tail -1)
[ "$free" -gt $((need + 300)) ] || { echo "/boot has ${free}M free, need ~${need}M plus 300M headroom — refusing" >&2; exit 1; }
echo "preflight ok: /boot ${free}M free, need ~${need}M; kernel $KVER"

# ---- files (additive) ----
install -m644 "$IMAGE" "$VMLINUZ"
mkdir -p /boot/dtb && install -m644 "$DTB" "$DTB_DST"
rm -rf "/usr/lib/modules/$KVER"; cp -a "$STAGE/usr/lib/modules/$KVER" /usr/lib/modules/
rm -f "/usr/lib/modules/$KVER/build" "/usr/lib/modules/$KVER/source"
depmod "$KVER"
if [ -e "$INITRAMFS_PREBUILT" ]; then install -m644 "$INITRAMFS_PREBUILT" "$INITRD"
else mkinitcpio -k "$KVER" -c /etc/mkinitcpio.conf -g "$INITRD"; fi

# ---- GRUB entry: mirror the stock entry exactly, plus `devicetree` ----
cmdline=$(grep -m1 -E '^\s*linux\s+/vmlinuz-linux-asahi' /boot/grub/grub.cfg | sed -E 's/^\s*linux\s+\/vmlinuz-linux-asahi\s*//')
[ -n "$cmdline" ] || { echo "could not read the stock kernel cmdline from grub.cfg" >&2; exit 1; }
bootuuid=$(findmnt -no UUID /boot)
{ strip_custom; cat <<ENTRY
$MARK_BEGIN
menuentry 'Arch Linux, fairydust DP alt mode ($KVER, USB-C Back Right Middle / usb-pd@3b)' --class arch --class gnu-linux --class gnu --class os \$menuentry_id_option 'gnulinux-fairydust-dp-usbpd3b' {
	load_video
	set gfxpayload=keep
	insmod gzio
	insmod part_gpt
	insmod fat
	insmod fdt
	search --no-floppy --fs-uuid --set=root $bootuuid
	echo	'Loading device tree $DTB_DST (dcpext1 -> usb-pd@3b) ...'
	devicetree	$DTB_DST
	echo	'Loading Linux $KVER ...'
	linux	$VMLINUZ $cmdline
	echo	'Loading initial ramdisk ...'
	initrd	$INITRD
}
$MARK_END
ENTRY
} > "$CUSTOM.new"; mv "$CUSTOM.new" "$CUSTOM"; chmod +x "$CUSTOM"
regen_grub

# ---- post checks ----
after=$(sha256sum "${STOCK_FILES[@]}")
diff <(echo "$before" | head -2) <(echo "$after") >/dev/null || { echo "FATAL: stock kernel files changed!" >&2; exit 1; }
echo; echo "installed. GRUB entries now:"; grep -E "^menuentry|^\s+menuentry" /boot/grub/grub.cfg | sed -E "s/--class.*//"
echo "default entry: $(grep -m1 -E '^set default' /boot/grub/grub.cfg)  (GRUB_DEFAULT=$(grep -E '^GRUB_DEFAULT' /etc/default/grub | cut -d= -f2))"
df -h /boot | tail -1; ls -la "$VMLINUZ" "$INITRD" "$DTB_DST"
echo; echo "Next: reboot, pick the 'fairydust DP alt mode' entry in the GRUB menu by hand, then run scripts/verify.sh."
echo "Rollback: reboot and let the default (stock) entry boot; or: sudo $0 --remove"
