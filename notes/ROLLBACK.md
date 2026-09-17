# Rollback / recovery plan (Step 0) — written BEFORE any install

Machine: Mac mini M2 Pro (j474s), Asahi/Omarchy on **external USB-C SSD `sda`** (port0, USB-C Back Left).
Written 2026-09-17, against linux-asahi 7.1.13.asahi3-1, m1n1 v1.6.1, uboot-asahi 2026.07.asahi2-1.

## Boot chain as it exists today (verified from live system, nothing assumed)

```
iBoot
 └─ m1n1 stage 1        APFS stub volume, INTERNAL NVMe (nvme0n1p3)           ← never touched
     └─ m1n1 stage 2    nvme0n1p4 (vfat "EFI - OMARC") : /m1n1/boot.bin       ← never touched
        contains: m1n1.bin + stock DTBs (incl. t6020-j474s.dtb) + u-boot
        proof: /proc/device-tree/chosen/asahi,efi-system-partition
               = <esp-partuuid> = PARTUUID of nvme0n1p4
         └─ u-boot (EFI)  → scans USB → runs GRUB
             └─ GRUB   sda3 /boot/EFI/BOOT/BOOTAA64.EFI, config /boot/grub/grub.cfg
                 ├─ entry 0 (DEFAULT, 5 s menu timeout): vmlinuz-linux-asahi + initramfs-linux-asahi.img
                 │      cmdline: root=UUID=<root-fs-uuid>… rootflags=subvol=@ rootdelay=120
                 │               cryptdevice=UUID=<luks-uuid>…:cryptroot root=/dev/mapper/cryptroot
                 │      initramfs 'encrypt' hook prompts for the LUKS passphrase, unlocks sda4
                 └─ (NEW, to be added) entry in /etc/grub.d/40_custom:
                        devicetree /dtb/t6020-j474s-fairydust-port2.dtb   (from /boot, sda3)
                        linux      /vmlinuz-linux-fairydust
                        initrd     /initramfs-linux-fairydust.img
```

m1n1 passes its embedded stock DTB (after runtime fixups) to u-boot → GRUB. The new entry
replaces that DTB via GRUB's `devicetree` command **for that entry only**. Entry 0 keeps
seeing the stock DTB. Nothing in this project modifies m1n1, u-boot, the stage-2 payload,
NVRAM, or any `nvme0n1*` partition.

## Invariants that make rollback trivial

1. `GRUB_DEFAULT=0` and `GRUB_TIMEOUT=5`, `GRUB_TIMEOUT_STYLE=menu` are NOT changed.
   → Every unattended boot lands on the stock kernel. The fairydust entry is only ever
   chosen by hand from the menu (arrow keys on the Apple keyboard on port1).
2. `/boot/vmlinuz-linux-asahi`, `/boot/initramfs-linux-asahi.img`, `linux-asahi` package,
   `/usr/lib/modules/7.1.13-3-1-ARCH/` are never modified or removed. Never `pacman -R linux-asahi`.
3. New files are additive, with distinct names:
   `/boot/vmlinuz-linux-fairydust`, `/boot/initramfs-linux-fairydust.img`,
   `/boot/dtb/t6020-j474s-fairydust-port2.dtb`, `/usr/lib/modules/<fairydust-kver>/`.
4. Before `grub-mkconfig`, copy `/boot/grub/grub.cfg` → `/boot/grub/grub.cfg.pre-fairydust`.
   Pre-existing `grub.cfg.b10-diag` and `grub.cfg.b9-loglevel4` are left alone.
5. Never run `update-m1n1`, `asahi-fwextract`, `asahi-bless --set-boot`. Never mount/fsck/write
   anything under `/dev/nvme0n1*`.
6. Blessed port is port2 / phy@f03000000 only. port0 / phy@703000000 carries the root SSD.

## Recovery ladder (least → most invasive)

**A. Fairydust kernel hangs / panics / no display.**
   Hold the power button ~10 s to power off. Power on. Do nothing at the GRUB menu:
   after 5 s entry 0 (stock) boots. Enter LUKS passphrase. Done. Then remove or fix the
   custom entry at leisure (`sudo rm /boot/dtb/... ; edit /etc/grub.d/40_custom ; sudo grub-mkconfig -o /boot/grub/grub.cfg`).

**B. Fairydust kernel boots but GPU/HDMI/USB regressed.**
   Same as A — reboot into entry 0. Nothing persistent was changed by booting the new kernel.
   (Modules for the new kernel live in their own /usr/lib/modules/<kver>/ dir; the stock
   kernel never loads them.)

**C. GRUB menu broken (bad grub.cfg after grub-mkconfig).**
   GRUB drops to `grub>` or shows an error. From the GRUB shell:
   ```
   grub> configfile (hd0,gpt3)/grub/grub.cfg.pre-fairydust
   ```
   or boot by hand:
   ```
   grub> set root=(hd0,gpt3)
   grub> linux /vmlinuz-linux-asahi root=UUID=<root-fs-uuid> rw rootflags=subvol=@ rootdelay=120 usbcore.autosuspend=-1 zswap.enabled=0 cryptdevice=UUID=<luks-uuid>:cryptroot root=/dev/mapper/cryptroot loglevel=4
   grub> initrd /initramfs-linux-asahi.img
   grub> boot
   ```
   (`(hd0,gpt3)` is what the current grub.cfg uses for /boot; if the disk index differs,
   `ls` in the GRUB shell and look for the partition with `/vmlinuz-linux-asahi`.)

**D. /boot on sda3 unreadable, or the external SSD does not enumerate.**
   Nothing in this project writes to sda3 except adding files, so this would be hardware.
   Hold power at boot → Apple boot picker → macOS (untouched, on nvme0n1p2). From macOS the
   vfat sda3 can be mounted and the extra files deleted / grub.cfg.pre-fairydust restored.
   The LUKS root (sda4) is not readable from macOS but is also never modified by this project.

**E. Worst case, still not booting Linux.** Boot an Asahi/Arch ARM USB installer, unlock the
   LUKS root (`cryptsetup open /dev/sdX4 cryptroot`, passphrase), mount `-o subvol=@`, chroot,
   repair. macOS remains bootable throughout.

## Space check (/boot = sda3, 1 GiB vfat)

Free before: 952 MiB. Stock kernel 34 MiB + initramfs 24 MiB. A second pair + DTB ≈ 60 MiB.
Comfortable. Re-check with `df -h /boot` in install.sh before copying.

## Pre-reboot checklist (install.sh must print all of these)

- [ ] sha256 of /boot/vmlinuz-linux-asahi and /boot/initramfs-linux-asahi.img unchanged
- [ ] `grep -c menuentry /boot/grub/grub.cfg` increased by exactly the new entries; entry 0 is still 'Arch Linux' with vmlinuz-linux-asahi
- [ ] /boot/grub/grub.cfg.pre-fairydust exists
- [ ] new entry has `devicetree`, `linux`, `initrd` lines pointing at existing files on /boot
- [ ] `df -h /boot` still shows > 800 MiB free
- [ ] no command in install.sh references nvme0n1 or update-m1n1 (grep it)

## Post-boot regression checks (both kernels) — see scripts/verify.sh

1. Machine boots, LUKS unlocks, `/dev/sda` present on port0 (`lsblk`).
2. `card2-HDMI-A-1` status=connected, Acer XZ270 X at 3840x2160@60 (`hyprctl monitors`).
3. `asahi` DRM bound (`ls /sys/bus/platform/drivers/asahi/`), Hyprland composites on GPU.
4. Apple keyboard on port1 and SSD on port0 enumerate (`lsusb`).
