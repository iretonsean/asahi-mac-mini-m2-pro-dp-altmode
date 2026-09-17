# Handoff — fairydust kernel + USB-C DisplayPort on the "USB-C Back Right Middle" port

> ## ⚠️ If you boot macOS for the ADT dump (step 1): DO NOT let macOS install a system update.
> The Asahi install is paired to OS firmware **13.5** (`asahi,os-fw-version`). A macOS update
> changes the paired firmware and breaks Asahi far worse than anything in this project.
> Decline/postpone any update prompt, do the one command below, shut down, boot back to Asahi.
> Also: pick the macOS volume from the boot picker (hold power) for that one boot only; do not
> change the default startup disk (BRIEF §11 rule 4).

Everything below runs on the external SSD only. Nothing here writes `nvme0n1*`, runs
`update-m1n1`, `grub-install`, or `asahi-bless` (BRIEF §11/§12/§14; `scripts/install.sh`
refuses to run if such text appears in its own body).

## What exists (all in `~/Projects/asahi-dp-altmode`, git-tracked except `linux/`, `build/`, `staging/`)

| Path | What |
|---|---|
| `linux/` | fairydust @ `ce9f2eba72c0` (2026-09-08, 7.1.13-based), branch `j474s-dp-usbpd3b` = fairydust + `patches/0001-*` |
| `patches/0001-arm64-dts-apple-t6020-j474s-bless-USB-C-Back-Right-M.patch` | DTS re-target: dcpext1 → atcphy2 / usb-pd@3b. Unpatched fairydust aims dcpext1 at atcphy1 = the *keyboard* port (it never touches atcphy0/the boot disk — only the aim is wrong) |
| `patches/pr622-hotplug-fix.diff` | PR #622 (closed, unmerged; applies cleanly). **Not** in the first build — second iteration if hotplug is flaky |
| `build/config-7.1.13-running` → `linux/.config` | running config + `TYPEC_NVIDIA_ALTMODE=m`, `TYPEC_TBT_ALTMODE=m`, `LOCALVERSION=""` (`EFI_SBAT_FILE`/`QRTR_MHI` don't exist in this tree) |
| `linux/arch/arm64/boot/Image` (34,114,048 B), `staging/lib/modules/7.1.13-fairydust-dp/` (127 MB stripped, 1,864 modules), `build/initramfs-linux-fairydust.img` (24.3 MB, built rootless; file list identical to the stock initramfs) | build output — ~60 MB lands on /boot (952 MB free) |
| `scripts/kbuild.sh` | `make` wrapper with the pinned toolchain (rustup 1.93.1, bindgen 0.73.2, `~/.local` bc/dtc) |
| `scripts/gen-dtb.sh` + `scripts/adt-segments.py` | builds `dt/t6020-j474s-dp-usbpd3b.dtb` from the live DT + the ADT dump (replicates m1n1 v1.6.1 fixups for dcpext1) |
| `scripts/install.sh` | `sudo`: copies kernel/initramfs/dtb/modules, adds the GRUB entry, `grub-mkconfig`. `--remove` undoes it |
| `scripts/verify.sh` | post-boot regression + success checks, ports keyed on i2c address (BRIEF §13) |
| `scripts/lib-typec-port.sh` | the i2c↔portN helper (peer-verified on live hardware) |
| `notes/ROLLBACK.md` | boot chain, invariants, recovery ladder — read before the first reboot |
| `dt/live-7.1.13.dts`, `dt/stock-t6020-j474s.dts`, `dt/base-live.dtb` | live DT (with m1n1 fixups) vs stock DTB, for reference |

## 1. One-time: get dcpext1's firmware carveouts from macOS (needed by gen-dtb.sh)

Why: m1n1 only emits the DCP firmware-region/DART mappings for DCP nodes that have an alias in
the payload DTB (stock payload: `dcpext0` only). The kernel's DART driver needs those
(`apple,asc-mem` + `iommu-addresses`, `IOMMU_RESV_TRANSLATED`) to let dcpext1's coprocessor
run. Their physical addresses live only in the Apple Device Tree, which Linux never sees. The
GRUB-`devicetree` route bypasses m1n1, so the values have to come from macOS once. (Details:
BRIEF §14, `scripts/gen-dtb.sh` header, m1n1 `src/kboot.c` `dt_reserve_dcpext_firmware`.)

In macOS (Terminal):
```
ioreg -l -w0 -p IODeviceTree -a > ~/Desktop/adt.plist
```
Get `adt.plist` onto the Linux side (USB stick / AirDrop to a phone / iCloud — anything;
the OMARCHYESP partition on the external SSD is a plain FAT volume too:
`diskutil list` → `sudo diskutil mount <the 1G "OMARCHYESP" slice>` → copy to `/Volumes/OMARCHYESP/`
and afterwards it appears at `/boot/adt.plist` in Linux). Shut down macOS. Boot Asahi.

Regenerate after any macOS/firmware update (carveout addresses come from iBoot) and re-check
`gen-dtb.sh` if m1n1 is ever updated.

## 2. Generate the DTB and review it (no root)

```
cd ~/Projects/asahi-dp-altmode
scripts/gen-dtb.sh --adt /path/to/adt.plist --ref build/ref-j474s-usbpd3b.dtb
less dt/t6020-j474s-dp-usbpd3b.delta.txt      # exactly what changed vs the live DT
```
Expect: `dcp@315c00000` status okay, `apple,connector-type = "DP"`, `apple,dptx-phy = <0x02>`,
`phys = <0xef 0x06>` (phy@f03000000, PHY_TYPE_DP), `mux-controls = <xbar 0>`, `mux-index = <0x02>`,
`apple,firmware-version/compat = <0x0d 0x05 0x00>`, `memory-region` with 2-3 new
`asc-firmware@…` nodes carrying `iommu-addresses = <0xd0 iova size>`; `mux@f0304c000`,
`iommu@315304000`, `iommu@31530c000`, `mbox@315c08000`, `audio-controller@39b508000` okay;
`display-subsystem` iommus = `<0x48 0 0xd1 0>`; `usb-pd@3b/connector` gains `displayport = <0xd0>`;
`power-controller@238` (atc2_common) gains `apple,always-on`. Nothing about `phy@703000000`.
The script aborts if the connector's SuperSpeed endpoint does not resolve under `/soc/phy@f03000000`.

## 3. Install (sudo) — additive GRUB entry only

```
sudo scripts/install.sh
```
It prints the menu, confirms entry 0 is still the stock kernel, and that the stock files'
checksums are unchanged. `GRUB_DEFAULT=0` and the 5-second menu stay: an unattended boot always
lands on the stock kernel. If a rootless initramfs was produced it is used
(`build/initramfs-linux-fairydust.img`); otherwise the script runs `mkinitcpio` for the new
kernel with the system `/etc/mkinitcpio.conf` (same hooks/modules as the stock one, incl.
`tps6598x phy_apple_atc usb_storage uas` for the boot SSD).

## 4. Reboot and test

1. Read `notes/ROLLBACK.md` §"Recovery ladder" once.
2. Reboot. In GRUB, arrow down to **"Arch Linux, fairydust DP alt mode (7.1.13-fairydust-dp, USB-C Back Right Middle / usb-pd@3b)"**, Enter. Unlock LUKS.
3. `scripts/verify.sh` — regression block must be all PASS; success block should be PASS 1-6.
4. If the monitor is dark: replug it (cold-plug is known-flaky upstream), check
   `sudo dmesg | grep -iE '315c00000|dispext1|dpxbar|dptx|cd321x'`. Expected good signs:
   `apple-dcp 315c00000.dcp: DCP index:2 dptx target phy: 2`, RTKit boot for 315c00000,
   `Switched dpphy to dispext1,0`, `dcp_dptx_connect(port=0)`, a `card*-DP-1` connector, and
   `lsusb` no longer listing `2109:0103 … BILLBOARD`. USB on that port dropping to 2.0 is
   expected under DP pin assignment C (PR #289) — not a cable fault.
5. Anything wrong → power-cycle, let the default entry boot (stock kernel, untouched).

### Troubleshooting order (BRIEF §15)
- **DP connector appears on the right port but the image is wrong/absent** → suspect
  `mux-index` first (`dt/…dts`, `dcp@315c00000`). It is the one value that comes from driver
  semantics, not the DTS: on t602x the crossbar state is `2*dispext + port`, so dispext1/port 0
  = 2 (same as the Mac Studio template). If the crossbar log says `Switched dpphy to dispext1,0`
  but nothing shows, try `mux-index = <3>` (dispext1,1) via `fdtput -t u <dtb> /soc/dcp@315c00000 mux-index 3`
  and re-run `sudo scripts/install.sh`. This failure looks like a cable/monitor fault and isn't.
- **`apple-dcp 315c00000.dcp` probe fails / RTKit boot timeout** → the firmware carveouts
  (`asc-firmware@…` nodes from the ADT dump) are wrong or missing. Re-check the
  `adt-segments.py` output against `ioreg` (`iop-dcpext1-nub` / `segment-ranges`).
- **No DP connector at all** → `dmesg | grep -i 315c00000`; check the DTB actually loaded
  (`ls /proc/device-tree/aliases/dcpext1` exists only with the custom DTB).
- **Partner shows DP altmode but no HPD** → cd321x HPD forwarding (`drivers/usb/typec/tipd/core.c`);
  compare with haripako's notes (break 2/3 in their README).

Deliberately NOT done: `dtbs_install` into `/usr/lib/modules/<kver>/dtbs/` (Arch's packaging
layout). The `95-m1n1-install.hook` pacman hook watches that path and `update-m1n1` globs
`/lib/modules/*-ARCH` — our kver wouldn't match, but keeping DTBs out of there removes the
question entirely. The DTB lives at `/boot/dtb/` only.

## 5. Known limitations / second iteration

- Hot/cold-plug flakiness and colour issues are expected per upstream. Candidates for a second
  build: `patches/pr622-hotplug-fix.diff` (`git apply` in `linux/`, rebuild with
  `scripts/kbuild.sh Image modules`), and haripako's DCP `->crashed`-latch fix
  (https://github.com/haripako/dp-altmode, `kmod-drm/`), plus their unresolved
  phantom-`DCPAVSERV`-after-unplug+suspend bug — don't burn hours on that one.
- `rustfmt` warnings during the build are non-fatal (bindgen formatting only).
- Route B (the community way: fairydust DTB with the `dcpext1` alias packed by `update-m1n1`)
  would need no ADT dump but writes the m1n1 payload on `nvme0n1p4` — forbidden by the brief.
  If that rule is ever relaxed, `linux/arch/arm64/boot/dts/apple/t6020-j474s.dtb` from the
  `j474s-dp-usbpd3b` branch is the DTB to pack; do NOT pack the unpatched fairydust one
  (it blesses the keyboard port).
