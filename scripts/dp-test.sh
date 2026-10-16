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
    install -m 755 "$HERE/scripts/grub-05_asahi_dp_oneshot" /etc/grub.d/05_asahi_dp_oneshot
    W=/usr/local/sbin/asahi-dp-watchdog
    grep -q fd_tries $W || sed -i "s|{ echo \"network ok\" >> \"\$out\"; exit 0; }|{ echo \"network ok\" >> \"\$out\"; grub-editenv $ENV set fd_tries=0; exit 0; }|" $W
    grep -n fd_tries $W
    grub-mkconfig -o /boot/grub/grub.cfg 2>&1 | tail -1
    grep -c fd_tries /boot/grub/grub.cfg ;;
  status) grub-editenv $ENV list; cat /var/log/asahi-dp/latest.txt 2>/dev/null | tail -40 ;;
  *) sed -n 2,6p "$0"; exit 1 ;;
esac
