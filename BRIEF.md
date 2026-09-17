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

> **⚠ See §13 before using this table.** The `portN` indices below are assigned in i2c probe
> order and are NOT stable across boots. Use the i2c address / DT phy path as the key.
> `scripts/lib-typec-port.sh` resolves ports correctly; use it instead of hardcoding `portN`.

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

All of these, on the monitor plugged into the blessed port — **i2c `usb-pd@3b` / "USB-C Back
Right Middle" / `phy@f03000000`**. Resolve it with `scripts/lib-typec-port.sh`; never
hardcode `portN` (§13).

1. `dcp@315c00000` probes — appears in `/sys/bus/platform/drivers/apple-dcp/` and logs
   an RTKit init in `dmesg`.
2. A new connector appears: `/sys/class/drm/card*-DP-*` with `status=connected`.
3. `typec_displayport` is loaded (`lsmod`).
4. The blessed port gains a partner alt mode with `svid=ff01` and `active=yes`:
   `cat "$(typec_sysfs_by_i2c 3b)"-partner/*/svid`
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

---

## 12. CORRECTION to §11 — the boot chain starts on the INTERNAL drive

Resolved 2026-09-17 without sudo, from the device tree. **This supersedes the §11 claim that
the Omarchy install "lives entirely on the external SSD."** That is true of the root and
`/boot`, but NOT of the boot chain.

```
/proc/device-tree/chosen/asahi,efi-system-partition
  = <esp-partuuid>
  -> /dev/nvme0n1p4   (vfat, LABEL "EFI - OMARC", INTERNAL NVMe)
```

So the actual boot path is:

```
iBoot            nvme0n1p1  iBootSystemContainer   INTERNAL
  -> stub        nvme0n1p3  2.3G APFS              INTERNAL  (m1n1 + u-boot; size is classic stub)
  -> ESP         nvme0n1p4  "EFI - OMARC"          INTERNAL  <-- CONFIRMED by DT
  -> GRUB cfg    sda3       OMARCHY-ESP            external  (/boot)
  -> kernel      sda3, root sda4 LUKS/btrfs        external
```

`nvme0n1p4` is **not** a leftover from an old install, as §11 guessed. It is part of the
**live** boot chain for the running system. `nvme0n1p3` being the blessed stub is a strong
inference (stub and ESP are paired, and 2.3G is the standard stub size), not yet confirmed —
`sudo asahi-bless -l` would confirm it but needs a real TTY; `/dev/mtd0` is root-only and the
user is in `wheel` but sudo has no askpass in the agent session.

### Consequences — these are now hard rules, not advice

1. **§11 rule 2 is load-bearing and CONFIRMED.** `update-m1n1` / `asahi-fwextract` write the
   boot stub, and the stub is on the internal NVMe. Running either writes to the internal
   drive and can brick the boot of the running system. Do not run them. Device-tree changes
   go through GRUB's `devicetree` directive from `/boot` (sda3), as §11 rule 3 already says.

2. **NEW: never run `grub-install`.** It rewrites the EFI binary, and the live one is on
   `nvme0n1p4` (internal). `grub-mkconfig -o /boot/grub/grub.cfg` is fine — it writes only
   the config, on sda3 (external). Adding the new kernel entry must be done by editing
   `/boot/grub/grub.cfg` or via `grub-mkconfig`, never by reinstalling GRUB.

3. **Never mount, fsck or write `nvme0n1p4`.** §11 rule 1 already forbade all `nvme0n1*`;
   this is the partition where that rule most plausibly gets violated by accident, because a
   routine-looking bootloader step targets it.

4. `nvme0n1p5` (ext4 "asahi-root", 11.5G) is still presumed to be a previous internal Asahi
   root, now superseded by the external install. Unconfirmed. Leave it alone regardless.

### What is still true

**macOS (`nvme0n1p2`, 446G APFS) is not touched by anything in this project.** It is not
mounted, not referenced by fstab or grub.cfg, and there is no APFS write path on this system.
The correction above is about the *boot chain*, not about macOS user data.

**Worst case is unchanged in kind but not in reach:** a bad kernel or DTB breaks the Omarchy
boot. Recovery is still the Apple boot picker (hold power) -> macOS or USB installer. But
because the stub and ESP are internal, a careless `update-m1n1` or `grub-install` breaks
boot in a way that is harder to repair from a live USB than a bad entry on sda3 would be.
Stay on the external SSD for every write.

---

## 13. DEFECT in §4 — portN indices are unstable. Re-key on i2c address.

Found via omacom/omarchy-mac PR #289. **§4 and §7 criterion 4 are keyed on `portN`, which is
wrong.** Those indices are assigned in i2c probe order, not by address, and probe order can
race. PR #289: "the same physical port was observed as `port1` on one boot and `port0` on
the next."

Our own data corroborates it — the mapping is not in address order:

```
0-0038 -> port0    0-003f -> port1    0-003b -> port2    0-003c -> port3
```

Address order (38, 3b, 3c, 3f) would give port0,1,2,3. It doesn't. Probe-order assignment
confirmed.

This is a safety defect, not a cosmetic one: §4 says "bless port2, never port0", and port0's
ATC PHY carries the external boot SSD. If the indices swap on a boot, that sentence points at
the wrong physical connector.

### Use these stable identifiers everywhere — DTB, scripts, verification

| | MONITOR — bless this | BOOT SSD — never touch |
|---|---|---|
| i2c node | `usb-pd@3b` (addr 0x3b) | `usb-pd@38` (addr 0x38) |
| DT label | "USB-C Back Right Middle" | "USB-C Back Left" |
| ATC PHY | `phy@f03000000` | `phy@703000000` |
| USB ctrl | `usb@f02280000` | `usb@702280000` |
| endpoints | 0x55 / 0x56 | 0x51 / 0x52 |

Other two, for completeness: `usb-pd@3f` / "Back Left Middle" / `phy@b03000000` (keyboard);
`usb-pd@3c` / "Back Right" / `phy@1303000000`.

DT paths are stable. `portN` is not. Anything reading `/sys/class/typec/portN` must resolve
the port through its i2c address first.

### Two signals from PR #289 that will otherwise mislead diagnosis

1. **The USB Billboard device is not proof of failure.** It reads like a failed alt mode but
   says nothing either way. (§1 item 3 treats its disappearance as the pass signal — that
   direction still holds, but do not read its *presence* as a specific fault.)
2. **Losing SuperSpeed is what success looks like.** Under DP pin assignment C all four lanes
   carry DP and USB drops to 2.0. Do not diagnose that as a bad cable or a dying port.

### Read before writing more DTS

- PR #289: https://github.com/omacom/omarchy-mac/pull/289 — documents the whole failure chain
- Working implementation: https://github.com/haripako/dp-altmode — its kernel-side HPD
  forwarding is backported from `fairydust`. May already solve problems this project is about
  to hit. Read it rather than re-deriving.
- Issue #384: https://github.com/omacom/omarchy-mac/issues/384 — M2 Air (t8112) report;
  explicitly asks whether Mini/Pro/Max are tracked separately. **This machine is that missing
  data point.**

---

## 14. BLOCKER for the GRUB-devicetree route — dcpext1 firmware carveouts are not in the live DT

Raised by the build session, **independently verified here against the live device tree**.
This is real and it changes the plan.

### The finding

m1n1's `kboot.c` (`dt_reserve_dcpext_firmware` / `dt_reserve_asc_firmware`) only processes DCP
nodes that have a **`dcpextN` alias in the payload DTB**. For each one it reads the Apple
Device Tree (`/arm-io/dcpextN/iop-dcpextN-nub` `segment-ranges`) and emits `/reserved-memory`
`apple,asc-mem` nodes carrying `iommu-addresses` (phys -> DART IOVA), plus a `memory-region`
on the DCP node. `apple-dart` needs these (`IOMMU_RESV_TRANSLATED`) to recreate the
coprocessor's firmware mappings after it resets the DART. Without them dcpext1's firmware
cannot execute.

The stock m1n1 payload declares only `dcpext0`, so nothing for dcpext1 exists in the live DT,
and the physical addresses of its firmware carveouts are readable nowhere from Linux.

### Evidence (all from this machine)

```
/proc/device-tree/aliases/       -> dcpext0 = /soc/dcp@289c00000 .  No dcpext1 alias.

dcp@289c00000 (HDMI, working)    memory-region = <0x104 0x105 0x106 0x107>
  0x104 -> reserved-memory/asc-firmware@10000230000   (apple,asc-mem, has iommu-addresses)
  0x105 -> reserved-memory/asc-firmware@103e4448000   (apple,asc-mem)
  0x106 -> reserved-memory/asc-firmware@103e3448000   (apple,asc-mem)
  0x107 -> reserved-memory/framebuffer@103e4a48000

dcp@315c00000 (target)           NO memory-region, NO apple,firmware-compat,
                                 NO apple,firmware-version
```

Property diff between the working HDMI node and the target is exactly the set m1n1
synthesizes plus the board wiring. The two remaining `asc-firmware` nodes (0x108, 0x109)
belong to other coprocessors, not to DCP.

ADT is confirmed not exposed to Linux: `/sys/firmware/fdt` is the flattened **Linux** DT, and
nothing under `/proc/device-tree` carries `segment-ranges`.

### The two routes

**Route A — derive from a macOS ADT dump (chosen; complies with §11/§12).**
Boot macOS once and run, as a normal user:
```
ioreg -l -w0 -p IODeviceTree -a > adt.plist
```
Read-only, writes nothing, touches no Linux partition. Copy the plist to Linux.
`scripts/gen-dtb.py` then takes that plus the live `/proc/device-tree` and emits the final
DTB, replicating m1n1's fixups for dcpext1.

⚠ **While in macOS, do not let it install any system update.** `asahi,os-fw-version` is
currently 13.5 and the Asahi install is paired to that firmware. A macOS update changes the
paired firmware and is a much bigger problem than this project. Decline update prompts.

**Route B — add a `dcpext1` alias to the m1n1 payload DTS and `update-m1n1`.**
This is what fairydust does upstream. It **writes `nvme0n1p4` on the internal NVMe** and is
forbidden by §11 rule 2 and §12 rule 1. Documented for completeness only. Do not take this
route without the user explicitly lifting that constraint.

### Open question, unverified

Whether a custom m1n1 can be **chainloaded** from external media instead of flashed to
`nvme0n1p4` — which would get Route B's correctness without Route B's write. Nobody has
checked this. Worth ten minutes before committing to the gen-dtb.py path, not worth blocking on.

---

## 15. Stock fairydust blesses the WRONG port on this machine

Raised by the build session, verified here. **Anyone who packs unmodified fairydust DTBs on a
j474s gets DP on the keyboard port and nothing on the monitor.**

`t602x-j474-j475.dtsi` includes `t600x-j375.dtsi` (Mac Studio), whose `ENABLE_DCPEXT_TYPEC`
block is active because `j474s.dts` defines that macro. The compiled stock DTS contains:

```
&dcpext1 { status="okay"; apple,connector-type="DP"; apple,dptx-phy=<1>;
           phys=<&atcphy1 6>; mux-controls=<&atcphy1_xbar 0>; mux-index=<2>; };
&atcphy1_xbar { status="okay"; };
&ps_atc1_common { apple,always-on; };
```

Alias resolution on this machine, confirmed from the live DT:

| alias | phy node | connector | attached |
|---|---|---|---|
| `atcphy0` | `phy@703000000` | `usb-pd@38` Back Left | **ROOT SSD** |
| `atcphy1` | `phy@b03000000` | `usb-pd@3f` Back Left Middle | keyboard ← **stock blesses this** |
| `atcphy2` | `phy@f03000000` | `usb-pd@3b` Back Right Middle | **MONITOR** ← should be blessed |
| `atcphy3` | `phy@1303000000` | `usb-pd@3c` Back Right | pd-only |

**Not catastrophic** — verified that stock fairydust never touches `atcphy0`/`ps_atc0`: those
appear only in base node definitions, with no `status` override, no `always-on`, no DP wiring.
The boot disk is not at risk from the stock DTB. It is simply aimed at the wrong connector.

### The re-target

`patches/0001-…bless-USB-C-Back-Right-M.patch`, branch `j474s-dp-usbpd3b`: moves `dcpext1` to
`apple,dptx-phy=<2>` / `phys=<&atcphy2 PHY_TYPE_DP>` / `mux-controls=<&atcphy2_xbar 0>`,
enables `atcphy2_xbar` and disables `atcphy1_xbar`, swaps `apple,always-on` from
`ps_atc1_common` to `ps_atc2_common`, and moves `displayport` from `typec1` to `typec2`.
`scripts/gen-dtb.sh` applies the same delta to the live-DT-derived DTB for the GRUB route, and
asserts the connector's SS endpoint resolves under `phy@f03000000` and never `phy@703000000`.

`dpaudio2` correctly needs no change: verified that `dpaudio2_dcp` is an endpoint inside
`dcpext1`'s own `ports/port@0`, so DP audio binds to the DCP, not to the PHY.

### Highest-risk unverified assumption in the patch

`mux-index` is left at `2` on the reasoning that the t602x crossbar encodes it as
`2 * dispext + port`, so dispext1/port0 stays 2 regardless of which ATC PHY feeds it. That is
driver semantics and cannot be confirmed from the DTS. If DP comes up on the right connector
but the image is wrong or absent, **suspect `mux-index` first.**

### Chainload idea (§14) — ruled out

m1n1's `chainload_load` reads only from NVMe (it has no USB stack), and both chainload specs
live on `nvme0n1p3`/`p4`. A custom m1n1 cannot be booted from the external SSD. Route A
(macOS ADT dump) stands as the only path that respects §11/§12.
