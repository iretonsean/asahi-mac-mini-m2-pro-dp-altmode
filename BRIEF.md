# Project Brief: Native USB-C DisplayPort Alt Mode on Mac mini M2 Pro (Asahi)

**Target model for the working session:** Fable 5.1 (`claude-fable-5-1`)
**Start with:** `claude --model claude-fable-5-1` from `~/Projects/asahi-dp-altmode`
**Brief written:** 2026-09-17
**Machine:** the same machine this brief describes — you are working on the host you are modifying.

---

## 1. Objective

Get a native DisplayPort alt-mode signal out of a USB-C port on this Mac mini M2 Pro
(`apple,j474s`, SoC `apple,t6020`) running Asahi Linux, so a USB-C monitor is detected as a
real DRM connector and usable under Hyprland.

"Native" here means the DCP/DPTX/ATCPHY hardware path — **not** DisplayLink/evdi, which was
considered and rejected as a workaround.

Out of scope: multi-monitor over USB-C, Thunderbolt device support, upstreaming the patches.
One working USB-C display on one port is the deliverable.

---

## 2. Why this is needed — diagnosis already completed

Do not re-run this investigation. It is settled. Summary of findings:

The monitor **is** detected at the USB/PD layer; DisplayPort alt-mode entry never happens,
because the kernel has no DP source to attach to the port.

1. **Only one display controller is enabled.** The device tree exposes three DCP nodes:

   | DT node | Compatible | Status | Role |
   |---|---|---|---|
   | `dcp@289c00000` | `apple,t6020-dcpext` | **okay** | HDMI. Has `apple,connector-type = HDMI-A`, `apple,dptx-phy = 4`, `phys = <&phy@39c000000>` (`phy-names = dp-phy`), plus `hdmi-hpd-gpios` / `dp2hdmi-pwren-gpios`. |
   | `dcp@315c00000` | `apple,t6020-dcpext` | **disabled** | The second external controller. **This is the one to bring up.** Has no `apple,dptx-phy`, no `apple,connector-type`, no `phys` — it was never wired to an output. |
   | `dcp@389c00000` | `apple,t6020-dcp` | **disabled** | Internal-panel DCP. Meaningless on a mini. Leave alone. |

   Result: DRM exposes exactly one connector, `card2-HDMI-A-1`. There is no `DP-*` connector.

2. **Type-C layer is healthy.** All four ports advertise DP alt mode as a source
   (`svid=ff01`, `vdo=0x00000c02`). PD contracts are negotiated. But every
   `port*-partner` has an **empty** alt-mode list and `typec_displayport` is not loaded.
   The host never enters DP alt mode.

3. **The monitor says so explicitly.** `lsusb` shows
   `Bus 007 Device 002: ID 2109:0103 VIA Labs, Inc. USB 2.0 BILLBOARD`,
   `bDeviceClass 17 Billboard`, `Driver=[none]`.
   A USB Billboard device is the spec-mandated fallback a USB-C device exposes when it
   offered an alt mode and the host declined to enter it. **When this project succeeds,
   this billboard device should disappear.** It is the single best pass/fail signal.

4. **Upstream status.** DP alt mode on Apple Silicon (DCP, DPXBAR, ATCPHY, ACE) exists only
   in the downstream `fairydust` branch of `AsahiLinux/linux`, demoed at 39C3. It is not in
   `linux-asahi` 7.1.13.asahi3. Upstream ships it strictly as-is, developer-only, no support,
   one "blessed" port per machine, with known cold/hot-plug and color bugs.

---

## 3. System inventory

```
Machine        Apple Mac mini (M2 Pro, 2023) — apple,j474s / apple,t6020
Kernel         7.1.13-3-1-ARCH  (pkg: linux-asahi 7.1.13.asahi3-1, repo asahi-alarm)
Userland       Arch Linux ARM + Omarchy, Hyprland on Wayland
GPU            asahi (Rust DRM driver, CONFIG_DRM_ASAHI=y)
Display        appledrm / apple-dcp, card2-HDMI-A-1
m1n1           v1.6.1        u-boot: uboot-asahi 2026.07.asahi2-1
Mesa           26.2.3        os-fw-version: 13.5
Build host     10 cores, 15 GiB RAM
```

**Storage layout — read this carefully, it drives the safety plan:**

```
sda  3.6T  EXTERNAL USB-C SSD (Micron CT4000X8SSD9)  <-- Asahi lives here
 ├─ sda3  1G   vfat   /boot        (952M free — GRUB, tight for 2 kernels)
 └─ sda4  934G LUKS -> btrfs cryptroot -> / (subvol @) and /home
nvme0n1  466G  internal — macOS APFS + a 11.5G ext4 + 500M vfat
```

Root is on an **encrypted external USB-C SSD**. The bootloader is **GRUB** at `/boot`
(`/boot/grub/grub.cfg`; note pre-existing variants `grub.cfg.b10-diag`,
`grub.cfg.b9-loglevel4` — someone has been experimenting, don't clobber them).

---

## 4. Port map — THE critical constraint

Resolved from `/proc/device-tree` by following connector endpoint phandles. Physical labels
are Apple's own, from the DT `label` properties.

| typec | i2c node | Physical port (rear) | USB controller | ATC PHY | Currently attached |
|---|---|---|---|---|---|
| `port0` | `usb-pd@38` | **USB-C Back Left** | `usb@702280000` (bus 5/6) | `phy@703000000` | ⚠️ **THE BOOT SSD** |
| `port1` | `usb-pd@3f` | USB-C Back Left Middle | `usb@b02280000` (bus 3/4) | `phy@b03000000` | Apple keyboard |
| `port2` | `usb-pd@3b` | **USB-C Back Right Middle** | `usb@f02280000` (bus 7/9) | `phy@f03000000` | ✅ **THE MONITOR** (VIA Labs hub + billboard) |
| `port3` | `usb-pd@3c` | USB-C Back Right | `usb@1302280000` (bus 8/10) | `phy@1303000000` | a PD-only partner (`not_ufp`) |

### Hard rules

- **Bless `port2` (`phy@f03000000` / `usb@f02280000`).** The monitor is already there and it
  is maximally far from the boot disk.
- **Never bless `port0`.** `fairydust` forces the blessed port's ATC PHY always-on and
  dedicates it to DP. Doing that to `port0` takes out the ATC PHY carrying the root
  filesystem. That is an unbootable machine with an encrypted root, recoverable only via
  external media.
- The HDMI output does **not** consume an ATC PHY — it uses the dedicated
  `phy@39c000000` (`apple,t6020-dptx-phy`). So all four USB-C ports' PHYs are available and
  HDMI should be unaffected. Verify this assumption holds after every build.

---

## 5. Approach

Work in this order. Do not skip step 0.

**Step 0 — Establish rollback before touching anything.**
- Confirm the machine can boot from a known-good path with the new kernel absent.
- `linux-asahi` stays installed and its GRUB entry stays intact. The new kernel is an
  *additional* entry, never a replacement. Never `pacman -R linux-asahi`.
- `/boot` has only ~952M free. Check the size of a built kernel + initramfs before
  installing; if it doesn't comfortably fit, free space first rather than filling `/boot`.
- Have the recovery story written down *before* the first reboot: how to get into m1n1/u-boot,
  pick the old entry, and unlock the LUKS root.

**Step 1 — Get the tree.**
```
git clone https://github.com/AsahiLinux/linux.git --branch fairydust --single-branch
```
Also evaluate **PR #622** (`drm/apple, phy: apple: Fix external display hotplug on DP alt
mode`) — it targets exactly the hotplug flakiness this project will otherwise hit. Decide
whether to include it in the first build or hold it as a second iteration.

**Step 2 — Device tree.** The upstream fairydust approach uses preprocessor DTS hacks to
bless a port. Adapt for `t6020` / j474s: enable `dcp@315c00000` and wire it to a DPTX phy
and to `phy@f03000000` (port2). Most published fairydust reports are M1/M2 laptops
(t8103/t8112); **this is an M2 Pro mini and the DTS work will not transfer verbatim.**
Expect this to be the hard part.

**Step 3 — Kernel config.** Start from the running config (`/proc/config.gz`) so the working
system's driver set is preserved. Known-required deltas from build reports:
```
CONFIG_TYPEC_DP_ALTMODE=m
CONFIG_TYPEC_NVIDIA_ALTMODE=m
CONFIG_TYPEC_TBT_ALTMODE=m
CONFIG_EFI_SBAT_FILE=""      # avoids a build failure
CONFIG_QRTR_MHI=n            # avoids a build failure
```
Keep `CONFIG_DRM_ASAHI=y`, `CONFIG_DRM_APPLE=m`, `CONFIG_PHY_APPLE_ATC=m`,
`CONFIG_PHY_APPLE_DPTX=m`, `CONFIG_TYPEC_TPS6598X=m`.

**Step 4 — Build, install as a parallel entry, reboot, test.**

---

## 6. Build prerequisites — currently MISSING

The running kernel is built with Rust (`CONFIG_DRM_ASAHI=y` is a Rust driver), so the Rust
toolchain is mandatory — it cannot be skipped without losing GPU acceleration.

```
rust            NOT INSTALLED   <-- needed; running kernel used rustc 1.93.1
rust-bindgen    NOT INSTALLED   <-- needed
bc              NOT INSTALLED   <-- needed
```
Present and fine: gcc 16.1.1, clang 22.1.8, make, flex, bison, pahole 1.32, cpio, perl,
tar, xz, zstd, openssl, git.

**Version-matching is a likely failure point.** `CONFIG_RUSTC_VERSION_TEXT` on the running
kernel is `rustc 1.93.1 (01f6ddf75 2026-02-11)` with LLVM 21. Arch's current `rust` package
may be newer than what the fairydust tree accepts. Check the tree's
`Documentation/process/changes.rst` and `scripts/min-tool-version.sh` before assuming.

---

## 7. Success criteria

All of these, on the monitor plugged into **port2 / USB-C Back Right Middle**:

1. `dcp@315c00000` probes — appears in `/sys/bus/platform/drivers/apple-dcp/` and logs
   an RTKit init in `dmesg`.
2. A new connector appears: `/sys/class/drm/card*-DP-*` with `status=connected`.
3. `typec_displayport` is loaded (`lsmod`).
4. `/sys/class/typec/port2-partner/port2-partner.*/` gains an alt mode with `svid=ff01`
   and `active=yes`.
5. **The billboard device is gone** — `lsusb` no longer lists `2109:0103 ... BILLBOARD`.
6. `hyprctl monitors` lists the second display with sane modes, and it actually lights up.

## 8. Regression checks — run every single boot

1. **The machine boots.** Root unlocks, `/dev/sda` enumerates on port0.
2. **HDMI still works** — `card2-HDMI-A-1` connected, Acer XZ270 X at 3840x2160@60.
3. **GPU acceleration intact** — `asahi` driver bound, `glxinfo`/`vulkaninfo` sane, Hyprland
   composites without falling back to software.
4. The Apple keyboard on port1 and the SSD on port0 still enumerate.

## 9. Known risks

- **Unbootable system.** Highest-severity risk, from an encrypted external-USB root plus ATC
  PHY changes. Mitigated entirely by discipline in Step 0.
- **DTS won't port cleanly** from t8103/t8112 laptops to t6020 mini. This is the main
  technical unknown and where most effort will go.
- **Rust toolchain version mismatch** blocking the build.
- **Hotplug/cold-plug flakiness and color bugs** are *expected* per upstream, not signs of a
  broken port. PR #622 addresses some of this.
- `/boot` is small (952M free). Watch it.
- Upstream offers **no support** for fairydust. Don't file bugs against it expecting help.

## 10. References

- fairydust branch: https://github.com/AsahiLinux/linux/tree/fairydust
- Hotplug fix PR #622: https://github.com/AsahiLinux/linux/pull/622
- Asahi progress report (Linux 6.19, DP alt mode announcement): https://asahilinux.org/2026/02/progress-report-6-19/
- Asahi display controller docs: https://asahilinux.org/docs/hw/soc/display-controllers/
- LWN coverage: https://lwn.net/Articles/1059347/
- Community build writeups (M1/M2 laptops — adapt, don't copy):
  - https://zenn.dev/omemoji/articles/asahi_displays?locale=en
  - https://github.com/OliRafa/omarchy-fairydust-kernel

---

## 11. Blast radius — what this project may and may not write

The Omarchy install lives **entirely on the external USB-C SSD (`sda`)**. Verified:

- `/etc/fstab` mounts only `UUID=<root-fs-uuid>…` (btrfs on `sda4` LUKS) and `UUID=<boot-fs-uuid>`
  (`sda3`, `/boot`). No internal-NVMe partition is mounted or referenced.
- `/boot/grub/grub.cfg` references only `hd0,gpt3` (`sda3`) and LUKS
  `UUID=<luks-uuid>…` (`sda4`). No NVMe references.
- Kernel build → `~/Projects` (`sda4`). Kernel + initramfs → `/boot` (`sda3`).
  Modules → `/usr/lib/modules` (`sda4`). All external.

### Internal NVMe layout — do not write to any of this

```
nvme0n1p1  500M  apfs  iBootSystemContainer   machine firmware boot container
nvme0n1p2  446G  apfs  Container              *** macOS. Never touch. ***
nvme0n1p3  2.3G  apfs                         likely the m1n1/u-boot stub for an Asahi install
nvme0n1p4  500M  vfat  "EFI - OMARC"          ESP of an older/other Omarchy install
nvme0n1p5  11.5G ext4  "asahi-root"           root of an older/other Asahi install
nvme0n1p6  5G    apfs  RecoveryOSContainer    recovery
```

`nvme0n1p4` and `nvme0n1p5` look like a **previous Omarchy/Asahi install** that is not the
running system. Leave them alone — they may be someone's fallback.

### Rules

1. **Never mount, fsck, repartition or write any `nvme0n1*` partition.** macOS is
   `nvme0n1p2`. Nothing in this project has any reason to go near the internal disk.
2. **Do not run `update-m1n1`, `asahi-fwextract`, or anything that rewrites the boot stub.**
   The stub for this install is plausibly `nvme0n1p3` on the *internal* drive, so a stub
   update is one of the few operations here that would write to the internal NVMe. It is
   also not needed:
3. **Custom device trees load via GRUB, not m1n1.** Use GRUB's `devicetree` directive to
   load a custom `.dtb` from `/boot` (`sda3`, external). This keeps all DT experimentation on
   the external SSD and reversible by editing one GRUB entry.
4. **Do not change the NVRAM boot selection** (`asahi-bless --set-boot`). NVRAM is
   machine-global rather than per-disk. If it does get changed, it is recoverable: hold the
   power button to reach the Apple boot picker and select the macOS volume.
5. Physically, the external SSD is on **port0 / USB-C Back Left**. See §4 — never bless it.

### Unconfirmed — resolve at the start of the session

Which APFS volume is the blessed boot stub for the running system: `nvme0n1p3` (internal) or
`sda2` (external, 2.7T). Run `sudo asahi-bless -l` and `sudo asahi-bless --get-boot`
(both read-only) and record the answer here. If the stub is internal, rule 2 becomes
non-negotiable rather than merely advisable.

### Worst case

A bad kernel or DTB makes **the Omarchy install** fail to boot. macOS is unaffected and
still reachable through the Apple boot picker. Recovery is: boot picker → macOS (or a USB
installer) → fix or remove the GRUB entry on `sda3`.
