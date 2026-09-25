# Handoff — fairydust kernel + USB-C DisplayPort on the "USB-C Back Right Middle" port

Updated 2026-09-25. **No macOS boot and no ADT dump are needed any more.** The remaining
steps are one `sudo scripts/install.sh`, a reboot, and picking the new GRUB entry by hand.

Everything below runs on the external SSD only. Nothing here writes `nvme0n1*`, runs
`update-m1n1`, `grub-install`, or `asahi-bless` (BRIEF §11/§12/§14; `scripts/install.sh`
refuses to run if such text appears in its own non-comment lines).

## What changed on 2026-09-25 (and why the plan changed)

1. **The GRUB-`devicetree` route was unsafe.** `scripts/gen-dtb.sh` snapshotted the *live*
   DT. That tree carries per-boot m1n1 values: every secondary CPU's `cpu-release-addr`
   (spin table) and the ADT / m1n1-log `phram` regions shifted by 0x18f0000 between the
   09-17 boot and the 09-25 boot. A DTB snapshotted on boot N would send boot N+1's
   secondary CPUs to a stale spin-table address. Dropped.
2. **The ADT is already in RAM.** m1n1 leaves the Apple Device Tree of *this* boot in
   `/reserved-memory/flash@…` (`compatible = "phram"`, `label = "adt"`). The running kernel
   has `CONFIG_MTD_PHRAM` off, so Linux can't read it, but the EFI stub can. That also
   removes the macOS-dump risk: a macOS boot runs macOS's own iBoot2 and firmware, not the
   13.5 set Asahi is paired to, so its carveouts would not necessarily match.
3. **New route:** `patches/0002-efi-libstub-apple-enable-dcpext1-on-j474s-from-m1n1-.patch`
   (`linux/drivers/firmware/efi/libstub/apple-dcpext.c`). On every boot of the fairydust
   entry, before ExitBootServices, the kernel's EFI stub takes the FDT m1n1 built for that
   boot and applies what m1n1 v1.6.1 would have applied for a `dcpext1` alias, plus the
   board wiring:
   * carveouts: ADT `/arm-io/dcpext1/iop-dcpext1-nub` `segment-ranges`
     (`u64 phys, u64 iova, u64 remap, u32 size, u32 unk`; m1n1 uses `remap`, size aligned
     up to 16K) → `/reserved-memory/asc-firmware@<phys>` {`apple,asc-mem`, `reg`, `no-map`,
     `iommu-addresses = <&dcpext1 remap size>`} + `memory-region` on the DCP;
   * `apple,firmware-version/compat` copied from dcpext0 (same OS firmware, same m1n1
     computation), `status = "okay"`, `aliases/dcpext1`;
   * the t600x-j375 `ENABLE_DCPEXT_TYPEC` block transposed to atcphy2: dptx-phy 2,
     `phys = <&phy@f03000000 PHY_TYPE_DP>`, crossbar `mux@f0304c000` index 2, both dcpext1
     DARTs + mbox + `audio-controller@39b508000` okay, display-subsystem iommus += dispext1,
     `usb-pd@3b/connector` `displayport`, `atc2_common` `apple,always-on`.

   **Safety:** it runs only with `apple_dcpext1=usb-pd@3b` on the cmdline and only on
   `apple,j474s`. It refuses, leaving the FDT exactly as m1n1 made it, if any of these
   fail: the ADT parser reproduces m1n1's own dcpext0 carveouts in the same FDT *exactly*;
   the connector's SuperSpeed endpoint resolves under `/soc/phy@f03000000` (never
   `phy@703000000`, the root SSD); no dcpext1 segment overlaps an existing reservation; the
   base nodes look as expected; `dcpext1` isn't already aliased. All checks run before the
   first write. The outcome is always recorded in `/proc/device-tree/chosen/asahi-dp-altmode,dcpext1`.
4. **Two latent install.sh bugs fixed.** (a) The forbidden-text self-check matched its own
   line, so the script always exited FATAL. (b) `grub-mkconfig`'s `10_linux` would have
   picked up `/boot/vmlinuz-linux-fairydust` and, because it version-sorts above
   `vmlinuz-linux-asahi`, made it the **default** entry. The old check only looked at the
   title "Arch Linux". The kernel now goes to `/boot/fairydust/` (outside the glob), and the
   check verifies that entry 0's `linux` line is `/vmlinuz-linux-asahi`. (c) The GRUB entry
   also used `/boot/...` paths, which GRUB can't resolve because /boot is its own partition.
5. Stock DTB vs unpatched fairydust DTB, compared with phandles resolved to paths
   (`scripts/dtdiff.py`), differ **only** in the dcpext1/DP block. So fairydust's drivers
   need nothing else from the fairydust DTS, and the stock m1n1 tree is a valid base.

## What exists (all in `~/Projects/asahi-dp-altmode`, git-tracked except `linux/`, `build/`, `staging/`)

| Path | What |
|---|---|
| `linux/` | fairydust @ `ce9f2eba72c0` (7.1.13-based), branch `j474s-dp-usbpd3b` = fairydust + `patches/0001-*` (DTS re-target, used only by the Route-B DTB) + `patches/0002-*` (EFI-stub fixup, **what this route runs**) |
| `linux/arch/arm64/boot/Image` | 34,114,048 B, built 2026-09-25 21:17, contains the stub fixup (`install.sh` checks it) |
| `staging/lib/modules/7.1.13-fairydust-dp/` | 1,864 stripped modules, 127 MB, restaged 21:18 from the same build |
| `build/initramfs-linux-fairydust.img` | 24.3 MB, rebuilt rootless 21:19 (`mkinitcpio -r staging`); same 323-file list as the stock initramfs; all 323 modules byte-identical to staging. It had to be rebuilt: the 09-17 modules' BTF no longer matches this vmlinux and `CONFIG_MODULE_ALLOW_BTF_MISMATCH` is off (a mismatch means the module refuses to load). `install.sh` only uses it if it is newer than the Image and `modules.dep`; otherwise it runs `mkinitcpio` |
| `tests/stub-fixup/run-tests.sh` | rootless: builds the stub code in userspace (ASan/UBSan) and runs it on **this machine's live FDT** with synthetic ADTs. 15 checks, incl. an exact phandle-resolved match with the independent `gen-dtb.sh` implementation and 300 fuzzed ADTs |
| `scripts/install.sh` | `sudo`: additive GRUB entry; `--remove` undoes it; `--print-entry` (no root) shows the entry |
| `scripts/verify.sh` | post-boot regression + success checks, ports keyed on i2c address (BRIEF §13); now also prints the stub's status and checks all CPUs are online |
| `scripts/gen-dtb.sh`, `scripts/adt-segments.py` | **legacy, do not boot their output.** Kept as a test oracle for the stub |
| `scripts/dtdiff.py` | property-level DT diff with phandles resolved to node paths |
| `scripts/stage.sh` | after any rebuild: restage modules + rebuild the rootless initramfs (BTF must match) |
| `scripts/kbuild.sh` | `make` wrapper with the pinned toolchain (rustup 1.93.1, bindgen 0.73.2, `~/.local` bc/dtc). Don't pass `W=1` (or any flag change): the Rust objects rebuild, and then the modules and initramfs have to be restaged |

## 1. Review (no root)

```
cd ~/Projects/asahi-dp-altmode
tests/stub-fixup/run-tests.sh          # expect: == 15 passed, 0 failed
scripts/install.sh --print-entry       # the exact GRUB entry that will be added
scripts/verify.sh                      # baseline on the stock kernel: regression block all PASS
```

## 2. Install (sudo) — additive GRUB entry only

```
sudo scripts/install.sh
```
What it does: copies the Image to `/boot/fairydust/vmlinuz`, the modules to
`/usr/lib/modules/7.1.13-fairydust-dp/` + `depmod`, and the initramfs to
`/boot/fairydust/initramfs.img`. It writes its marked block into `/etc/grub.d/40_custom`, backs
up `grub.cfg` to `grub.cfg.pre-fairydust` (once), and runs `grub-mkconfig -o /boot/grub/grub.cfg`.
It aborts if entry 0 no longer boots `/vmlinuz-linux-asahi` or if the stock kernel/initramfs
checksums changed (baseline: `notes/stock-boot-files.sha256`). `GRUB_DEFAULT=0` and the
5-second menu stay, so an unattended boot always lands on the stock kernel.
About 60 MB lands on /boot (952 MB free).

## 3. Reboot and test

1. Read `notes/ROLLBACK.md` §"Recovery ladder" once.
2. Reboot. In GRUB, arrow down past "Arch Linux" and "Advanced options" to
   **"Arch Linux, fairydust DP alt mode (7.1.13-fairydust-dp, USB-C Back Right Middle / usb-pd@3b)"**, Enter.
   If the stub refuses, it prints `ERROR: apple-dcpext1: …` on the HDMI screen before the
   kernel starts; boot continues without dcpext1. Unlock LUKS.
3. `scripts/verify.sh`: the regression block must be all PASS (incl. "all 10 CPUs online");
   the success block should be PASS 0-6. Line 0 is the stub's status string.
4. If the monitor is dark: replug it (cold-plug is known-flaky upstream), then check
   `sudo dmesg | grep -iE '315c00000|dispext1|dpxbar|dptx|cd321x'`. Good signs:
   `apple-dcp 315c00000.dcp: DCP index:2 dptx target phy: 2`, RTKit boot for 315c00000,
   `Switched dpphy to dispext1,0`, `dcp_dptx_connect(port=0)`, a `card*-DP-1` connector, and
   `lsusb` no longer listing `2109:0103 … BILLBOARD`. USB on that port dropping to 2.0 is
   expected under DP pin assignment C (PR #289), not a cable fault.
5. Anything wrong → power-cycle and let the default entry boot (stock kernel, untouched).
   Remove with `sudo scripts/install.sh --remove`.

### Troubleshooting order (BRIEF §15)
- **Stub status is not `applied: N carveouts`** → the message says which check refused.
  `ADT dcpext0 segments disagree with m1n1's reserved-memory` means the ADT layout is not
  what m1n1 v1.6.1 parses: stop and re-read m1n1 (was it updated?). `no usable … phram 'adt'
  region` means m1n1 no longer exposes the ADT. Neither is fixable by retrying.
- **DP connector appears on the right port but the image is wrong/absent** → suspect
  `mux-index` first (`MUX_INDEX` in `apple-dcpext.c`). It is the one value that comes from
  driver semantics, not the DTS: on t602x the crossbar state is `2*dispext + port`, so
  dispext1/port 0 = 2 (same as the Mac Studio template). If the crossbar log says
  `Switched dpphy to dispext1,0` but nothing shows, try 3 (`scripts/kbuild.sh Image modules`,
  `scripts/stage.sh`, `sudo scripts/install.sh`). This failure looks
  like a cable/monitor fault and isn't.
- **`apple-dcp 315c00000.dcp` probe fails / RTKit boot timeout** with the stub reporting
  `applied` → the carveouts are wrong or incomplete. The dcpext0 self-test makes a parser
  error unlikely; compare `/proc/device-tree/reserved-memory/asc-firmware@*` against dmesg's
  DART faults.
- **No DP connector at all** → `dmesg | grep -i 315c00000`; confirm the stub ran (verify.sh line 0).
- **Partner shows DP altmode but no HPD** → cd321x HPD forwarding (`drivers/usb/typec/tipd/core.c`);
  compare with haripako's notes (break 2/3 in their README).

## 4. Known limitations / second iteration

- Hot/cold-plug flakiness and colour issues are expected per upstream. Candidates for a second
  build: `patches/pr622-hotplug-fix.diff` (`git apply` in `linux/`, `scripts/kbuild.sh Image modules`,
  then **always** `scripts/stage.sh` to restage modules and rebuild the initramfs),
  and haripako's DCP `->crashed`-latch fix (https://github.com/haripako/dp-altmode, `kmod-drm/`),
  plus their unresolved phantom-`DCPAVSERV`-after-unplug+suspend bug. Don't burn hours on that one.
- `rustfmt` warnings during the build are non-fatal (bindgen formatting only).
- The stub assumes the carveouts iBoot reports in the ADT are excluded from usable RAM, as
  m1n1's own comment says for every DCP carveout. The reserved-memory nodes only describe
  the existing mappings to the DART.
- Re-check `apple-dcpext.c` against m1n1 `src/kboot.c` if m1n1 is ever updated. If a future
  m1n1 payload aliases dcpext1 itself, the stub steps aside (`skipped: … already present`).
- Route B (the community way: a fairydust DTB with the `dcpext1` alias packed by
  `update-m1n1`) writes the m1n1 payload on `nvme0n1p4` and is forbidden by the brief. If
  that rule is ever relaxed, `linux/arch/arm64/boot/dts/apple/t6020-j474s.dtb` from the
  `j474s-dp-usbpd3b` branch is the DTB to pack. Do NOT pack the unpatched fairydust one
  (it blesses the keyboard port).
- `dtbs_install` into `/usr/lib/modules/<kver>/dtbs/` is deliberately not done (the
  `95-m1n1-install.hook` pacman hook watches that layout).
