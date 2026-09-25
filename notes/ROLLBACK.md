# Rollback / recovery plan (Step 0) — written BEFORE any install

Machine: Mac mini M2 Pro (j474s), Asahi/Omarchy on **external USB-C SSD `sda`** on the connector
Apple labels "USB-C Back Left" (DT `usb-pd@38`, i2c 0x38, ATC PHY `phy@703000000`).

> Port identity convention (BRIEF §13): `/sys/class/typec/portN` indices follow i2c probe order and
> are NOT stable across boots. Every script here resolves ports by i2c address / DT path via
> `scripts/lib-typec-port.sh`. "portN" appears below only as a hint, never as a key.
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
                        linux      /fairydust/vmlinuz  <stock cmdline> apple_dcpext1=usb-pd@3b
                        initrd     /fairydust/initramfs.img
                        (no `devicetree` line — see below)
```

m1n1 passes its embedded stock DTB (after runtime fixups) to u-boot → GRUB → kernel, for
BOTH entries. In the new entry the fairydust kernel's EFI stub (patches/0002-*) adds the
dcpext1 → usb-pd@3b delta to that tree in memory, for that boot only, and only because the
cmdline carries `apple_dcpext1=usb-pd@3b`. Entry 0's kernel has no such code. Nothing in this
project modifies m1n1, u-boot, the stage-2 payload, NVRAM, or any `nvme0n1*` partition.

Why not GRUB `devicetree` (the original plan): the live DT carries per-boot m1n1 values —
secondary-CPU `cpu-release-addr` (spin table) and the ADT / m1n1-log `phram` regions moved
by 0x18f0000 between the 2026-09-17 boot and the 2026-09-25 boot. A DTB snapshotted on one
boot would point the next boot's secondary CPUs at a stale spin table.

## Invariants that make rollback trivial

1. `GRUB_DEFAULT=0` and `GRUB_TIMEOUT=5`, `GRUB_TIMEOUT_STYLE=menu` are NOT changed.
   → Every unattended boot lands on the stock kernel. The fairydust entry is only ever
   chosen by hand from the menu (arrow keys on the Apple keyboard, i2c 0x3f "USB-C Back Left Middle").
2. `/boot/vmlinuz-linux-asahi`, `/boot/initramfs-linux-asahi.img`, `linux-asahi` package,
   `/usr/lib/modules/7.1.13-3-1-ARCH/` are never modified or removed. Never `pacman -R linux-asahi`.
3. New files are additive, with distinct names:
   `/boot/fairydust/vmlinuz`, `/boot/fairydust/initramfs.img`, `/usr/lib/modules/7.1.13-fairydust-dp/`.
   Deliberately NOT `/boot/vmlinuz-*`: grub-mkconfig's 10_linux globs that and makes the
   version_sort-highest kernel the top-level default — `vmlinuz-linux-fairydust` sorts above
   `vmlinuz-linux-asahi`. install.sh also checks after grub-mkconfig that entry 0's `linux`
   line is `/vmlinuz-linux-asahi`, not just that its title is "Arch Linux".
4. Before `grub-mkconfig`, copy `/boot/grub/grub.cfg` → `/boot/grub/grub.cfg.pre-fairydust`.
   Pre-existing `grub.cfg.b10-diag` and `grub.cfg.b9-loglevel4` are left alone.
5. Never run `update-m1n1`, `asahi-fwextract`, `asahi-bless --set-boot`. Never mount/fsck/write
   anything under `/dev/nvme0n1*`.
5b. **Never run `grub-install`** (BRIEF §12). It rewrites the EFI binary and can land on the
   internal NVMe ESP. Only `grub-mkconfig -o /boot/grub/grub.cfg` (writes sda3 only) or a
   direct edit of `/boot/grub/grub.cfg`. install.sh carries a header comment saying so.
   Verified 2026-09-17: EFI var `LoaderDevicePartUUID` = <boot-partuuid>-… = PARTUUID of sda3, i.e.
   the GRUB that booted this session is the copy on the external SSD, so editing sda3's
   grub.cfg is what takes effect.
6. Blessed port is **`phy@f03000000` / `usb-pd@3b` (i2c 0x3b, "USB-C Back Right Middle")** only.
   **`phy@703000000` / `usb-pd@38` (i2c 0x38, "USB-C Back Left")** carries the root SSD — never.

## Recovery ladder (least → most invasive)

**A. Fairydust kernel hangs / panics / no display.**
   Hold the power button ~10 s to power off. Power on. Do nothing at the GRUB menu:
   after 5 s entry 0 (stock) boots. Enter LUKS passphrase. Done. Then remove or fix the
   custom entry at leisure (`sudo scripts/install.sh --remove`).

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
- [ ] new entry has `linux` (with `apple_dcpext1=usb-pd@3b`) and `initrd` lines pointing at existing files under /boot/fairydust (review first, rootless: `scripts/install.sh --print-entry`)
- [ ] entry 0's `linux` line is `/vmlinuz-linux-asahi` (install.sh checks this after grub-mkconfig)
- [ ] `df -h /boot` still shows > 800 MiB free
- [ ] no command in install.sh references nvme0n1 or update-m1n1 (grep it)

## Post-boot regression checks (both kernels) — see scripts/verify.sh

1. Machine boots, LUKS unlocks, `/dev/sda` present behind the i2c-0x38 port (`lsblk`; verify.sh resolves the port by i2c address).
2. `card2-HDMI-A-1` status=connected, Acer XZ270 X at 3840x2160@60 (`hyprctl monitors`).
3. `asahi` DRM bound (`ls /sys/bus/platform/drivers/asahi/`), Hyprland composites on GPU.
4. Apple keyboard (i2c 0x3f port) and SSD (i2c 0x38 port) enumerate (`lsusb`).
