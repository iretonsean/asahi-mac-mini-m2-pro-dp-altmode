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

## Status (2026-09-17)

Built, not yet booted. Kernel `7.1.13-fairydust-dp` (fairydust `ce9f2eba72c0` + one DTS patch)
builds rootless with a pinned toolchain; install/verify tooling is ready. Remaining:
a one-time `ioreg` dump from macOS (see [`notes/HANDOFF.md`](notes/HANDOFF.md) §1 — and do
**not** let macOS update while there), then `sudo scripts/install.sh`, reboot, `scripts/verify.sh`.

## Things worth knowing even if you have different hardware

* **Unpatched `fairydust` already blesses a port on the M2 Pro mini — the wrong one.**
  `t6020-j474s.dts` inherits the Mac Studio's `ENABLE_DCPEXT_TYPEC` block, which aims
  dcpext1 at `atcphy1` (usb-pd@3f, "USB-C Back Left Middle"). It never touches `atcphy0`,
  so nothing breaks; it just lights up the port you probably didn't plug the monitor into.
  [`patches/0001-…`](patches/) re-targets it to `atcphy2` / usb-pd@3b.
* **`/sys/class/typec/portN` indices are probe-order and not stable across boots.** Key
  everything on the i2c address / DT path instead (`scripts/lib-typec-port.sh`).
* **Loading a custom DTB through GRUB's `devicetree` bypasses m1n1's runtime fixups.** For a
  newly enabled DCP that means the firmware carveout / DART mappings (`apple,asc-mem` +
  `iommu-addresses`) are missing and the coprocessor cannot start. m1n1 derives them from
  the Apple Device Tree (`iop-dcpextN-nub/segment-ranges`), which Linux cannot see, so
  `scripts/gen-dtb.sh` replicates m1n1 v1.6.1's logic from an `ioreg` dump.
* On t602x the display crossbar `mux-index` is `2 * dispext + port`.

## Layout

| Path | |
|---|---|
| `BRIEF.md` | problem statement, diagnosis, port map, safety rules (§11–§15) |
| `notes/ROLLBACK.md` | boot chain, invariants, recovery ladder |
| `notes/HANDOFF.md` | step-by-step runbook + troubleshooting |
| `patches/0001-*.patch` | the DTS re-target (apply on `fairydust`) |
| `patches/pr622-hotplug-fix.diff` | AsahiLinux/linux#622, held for a second iteration |
| `scripts/kbuild.sh` | build wrapper (rustup 1.93.1, bindgen 0.73.2, user-local `bc`/`dtc`) |
| `scripts/gen-dtb.sh`, `scripts/adt-segments.py` | live DT + ADT dump → GRUB-loadable DTB |
| `scripts/install.sh` | additive GRUB entry; `--remove` undoes it; never `grub-install`/`update-m1n1` |
| `scripts/verify.sh` | post-boot regression + success checks |
| `dt/stock-t6020-j474s.dts` | decompiled stock DTB for reference |

Upstream `fairydust` is developer-only and unsupported; so is this. No warranty — the
recovery plan exists because things can go wrong.
