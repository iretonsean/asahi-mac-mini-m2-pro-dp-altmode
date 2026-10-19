#!/bin/bash
# dp-test.sh — one test cycle without manual steps (run with sudo; allowed by /etc/sudoers.d/90-asahi-dp-altmode)
#   dp-test.sh arm [--reboot]   install the current build, rebuild its initramfs (with the temporary
#                               key file), and mark the fairydust entry for the NEXT boot only
#   dp-test.sh disarm           clear the one-shot flag
#   dp-test.sh status           show the flag and the last test result
#   dp-test.sh default on|off   boot fairydust every time (falls back to stock after a failed boot)
#   dp-test.sh setup-default    install the GRUB snippet + watchdog confirm step (one time)
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
  default)
    case "${2:-}" in
      on)  grub-editenv $ENV set fd_default=1 fd_tries=0 ;;
      off) grub-editenv $ENV set fd_default=0 ;;
      *) echo "default on|off"; exit 1 ;;
    esac; grub-editenv $ENV list ;;
  setup-default)
    # Fill in this machine's values: the /boot filesystem UUID, and the owner and path of this repo.
    sed "s/@BOOT_FS_UUID@/$(findmnt -no UUID /boot)/" "$HERE/scripts/grub-05_asahi_dp_oneshot" > /etc/grub.d/05_asahi_dp_oneshot
    chmod 755 /etc/grub.d/05_asahi_dp_oneshot
    sed -e "s#@OWNER@#$(stat -c %U "$HERE")#" -e "s#@REPO@#$HERE#" "$HERE/scripts/asahi-dp-watchdog" > /usr/local/sbin/asahi-dp-watchdog
    chmod 755 /usr/local/sbin/asahi-dp-watchdog
    grep -n fd_tries /usr/local/sbin/asahi-dp-watchdog
    grub-mkconfig -o /boot/grub/grub.cfg 2>&1 | tail -1
    grep -c fd_tries /boot/grub/grub.cfg ;;
  status) grub-editenv $ENV list; cat /var/log/asahi-dp/latest.txt 2>/dev/null | tail -40 ;;
  *) sed -n 2,6p "$0"; exit 1 ;;
esac
