# USB-C DisplayPort alt mode on a Mac mini M2 Pro (Asahi Linux)

Bringing up the second external display controller (`dcp@315c00000`, *dcpext1*) on an
Apple Mac mini M2 Pro (`apple,j474s` / `t6020`) running Asahi Linux, and wiring it to the
USB-C port Apple labels **"USB-C Back Right Middle"** so a USB-C monitor shows up as a real
DRM `DP-*` connector — using the AsahiLinux `fairydust` branch, **without touching the
internal NVMe or the m1n1 boot stub**.

This machine boots Asahi from an *external* USB-C SSD that hangs off one of the very ATC
PHYs DisplayPort alt mode would repurpose, so the whole project is organised around not
bricking it. Read [`BRIEF.md`](BRIEF.md) (the full problem statement, diagnosis and safety
rules) and [`notes/ROLLBACK.md`](notes/ROLLBACK.md) before doing anything.

## Status (2026-09-25)

Built, not yet booted. Kernel `7.1.13-fairydust-dp` = fairydust `ce9f2eba72c0` + a DTS patch +
an EFI-stub patch that enables dcpext1 on top of the device tree m1n1 builds each boot, with the
firmware carveouts read from the Apple Device Tree m1n1 leaves in RAM. No macOS boot is needed.
Remaining: `sudo scripts/install.sh`, reboot, pick the fairydust entry, `scripts/verify.sh`
(see [`notes/HANDOFF.md`](notes/HANDOFF.md)).

## Things worth knowing even if you have different hardware

* **Unpatched `fairydust` already blesses a port on the M2 Pro mini — the wrong one.**
  `t6020-j474s.dts` inherits the Mac Studio's `ENABLE_DCPEXT_TYPEC` block, which aims
  dcpext1 at `atcphy1` (usb-pd@3f, "USB-C Back Left Middle"). It never touches `atcphy0`,
  so nothing breaks; it just lights up the port you probably didn't plug the monitor into.
  [`patches/0001-…`](patches/) re-targets it to `atcphy2` / usb-pd@3b.
* **`/sys/class/typec/portN` indices are probe-order and not stable across boots.** Key
  everything on the i2c address / DT path instead (`scripts/lib-typec-port.sh`).
* **Don't load a DTB snapshotted from the live tree through GRUB's `devicetree`.** m1n1's
  fixups include per-boot values (secondary-CPU `cpu-release-addr`, the ADT's location) that
  change from boot to boot. A newly enabled DCP also needs firmware carveout / DART mappings
  (`apple,asc-mem` + `iommu-addresses`) that m1n1 derives from the Apple Device Tree
  (`iop-dcpextN-nub/segment-ranges`) only for aliased nodes.
  [`patches/0002-*`](patches/) does that in the kernel's EFI stub instead. It reads the ADT
  from the `phram` "adt" region m1n1 leaves in RAM and checks its parser against m1n1's own
  dcpext0 output on every boot.
* **Don't name an extra kernel `/boot/vmlinuz-*` on an Arch GRUB setup** unless you want it to
  become the default: `grub-mkconfig` version-sorts those, and `linux-fairydust` > `linux-asahi`.
* On t602x the display crossbar `mux-index` is `2 * dispext + port`.

## Layout

| Path | |
|---|---|
| `BRIEF.md` | problem statement, diagnosis, port map, safety rules (§11–§15) |
| `notes/ROLLBACK.md` | boot chain, invariants, recovery ladder |
| `notes/HANDOFF.md` | step-by-step runbook + troubleshooting |
| `patches/0001-*.patch` | the DTS re-target (apply on `fairydust`; only matters for an m1n1-packed DTB) |
| `patches/0002-*.patch` | EFI-stub dcpext1 fixup — what the GRUB entry actually relies on |
| `tests/stub-fixup/` | rootless userspace tests of the stub fixup against the live FDT |
| `patches/pr622-hotplug-fix.diff` | AsahiLinux/linux#622, held for a second iteration |
| `scripts/kbuild.sh` | build wrapper (rustup 1.93.1, bindgen 0.73.2, user-local `bc`/`dtc`) |
| `scripts/gen-dtb.sh`, `scripts/adt-segments.py` | legacy DTB generator, now only the tests' oracle — don't boot its output |
| `scripts/install.sh` | additive GRUB entry; `--remove` undoes it; `--print-entry` previews; never `grub-install`/`update-m1n1` |
| `scripts/stage.sh` | restage modules + rootless initramfs after any rebuild |
| `scripts/verify.sh` | post-boot regression + success checks |
| `dt/stock-t6020-j474s.dts` | decompiled stock DTB for reference |

Upstream `fairydust` is developer-only and unsupported; so is this. No warranty — the
recovery plan exists because things can go wrong.
