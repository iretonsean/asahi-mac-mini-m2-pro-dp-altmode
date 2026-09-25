#!/usr/bin/env bash
# stage.sh — after ANY kernel rebuild: restage stripped modules and rebuild the rootless initramfs
# from them. Needed because module BTF must match the vmlinux it loads into
# (CONFIG_MODULE_ALLOW_BTF_MISMATCH is off), so stale modules/initramfs refuse to load.
set -euo pipefail
cd "$(dirname "$0")/.."; KVER=7.1.13-fairydust-dp
grep -aq "Linux version $KVER " linux/arch/arm64/boot/Image || { echo "Image is not $KVER" >&2; exit 1; }
rm -rf "staging/lib/modules/$KVER"
scripts/kbuild.sh modules_install INSTALL_MOD_PATH="$PWD/staging" INSTALL_MOD_STRIP=1 > build/modules_install.log 2>&1
mkinitcpio -k "$KVER" -r "$PWD/staging" -c /etc/mkinitcpio.conf -g build/initramfs-linux-fairydust.img > build/mkinitcpio.log 2>&1
echo "staged $(find "staging/lib/modules/$KVER" -name '*.ko*' | wc -l) modules; initramfs $(stat -c %s build/initramfs-linux-fairydust.img) B"
grep -E "ERROR" build/mkinitcpio.log && exit 1 || true
