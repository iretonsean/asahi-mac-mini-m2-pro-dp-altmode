#!/bin/bash
# dp-test.sh — one test cycle without manual steps (run with sudo; allowed by /etc/sudoers.d/90-asahi-dp-altmode)
#   dp-test.sh arm [--reboot]   install the current build, rebuild its initramfs (with the temporary
#                               key file), and mark the fairydust entry for the NEXT boot only
#   dp-test.sh disarm           clear the one-shot flag
#   dp-test.sh status           show the flag and the last test result
set -euo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd); KVER=7.1.13-fairydust-dp; ENV=/boot/grub/fairydust.env
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
[ -e $ENV ] || grub-editenv $ENV create
case "${1:-}" in
  arm)
    "$HERE/scripts/install.sh" | tail -3
    mkinitcpio -k $KVER -g /boot/fairydust/initramfs.img >/var/log/asahi-dp-mkinitcpio.log 2>&1 \
      || { echo "mkinitcpio failed, see /var/log/asahi-dp-mkinitcpio.log"; exit 1; }
    lsinitcpio /boot/fairydust/initramfs.img | grep -q '^crypto_keyfile.bin$' && echo "initramfs: key file in" || echo "initramfs: NO key file (passphrase needed)"
    grub-editenv $ENV set fd_next=1; echo "next boot only: fairydust ($(grub-editenv $ENV list))"
    [ "${2:-}" = --reboot ] && { sync; systemctl reboot; } ;;
  disarm) grub-editenv $ENV set fd_next=0; grub-editenv $ENV list ;;
  status) grub-editenv $ENV list; cat /var/log/asahi-dp/latest.txt 2>/dev/null | tail -40 ;;
  *) sed -n 2,6p "$0"; exit 1 ;;
esac
