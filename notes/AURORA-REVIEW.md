# Aurora / Omarchy Mac review for the Mac mini M2 Pro (j474s)

Date: 2026-10-13. Nothing on the machine was changed. This note records what the Omarchy Mac
repos offer for USB-C video on this Mac, and what to take from them.

## Summary

- Aurora gives no new route to USB-C video on the j474s. Our fairydust + EFI-stub build already
  does what Aurora does for `dcpext1`.
- Do not use the Aurora installer or `m1n1-aurora`. They write m1n1 (`update-m1n1`), which
  BRIEF §11/§12/§14 forbids.
- One Aurora patch is worth porting: the dwc3 DP-lane guard (`dff2d7cb`).

## What the repos are

| Repo | Role |
|---|---|
| `omacom/linux-aurora` | Kernel + installer (`install-aurora-sep.sh`). Latest tag `aurora-2026.10.13.18` |
| `omacom/omarchy-mac-pkgs` | Userspace packages + manual (`mac-manual/content/12-hardware.md`) |
| `omacom/omarchy-mac-installer` | macOS installer app. Developer previews only ("not a release") |
| `omarchy-mac/omarchy-pkgs-aarch64` | App packages only. No kernel |

## What Aurora does for the j474s

- `t6020-j474s.dts` + `t602x-j474-j475.dtsi`: HDMI on `dcpext0`, USB-C DP on `dcpext1`,
  all four USB-C ports routed to `dcpext1`, `dcpext1` alias set.
- The alias makes m1n1 emit the `dcpext1` firmware carveouts. That needs `update-m1n1`
  (forbidden here). Our `apple-dcpext.c` EFI stub does the same work at boot.
- No j474 mention in Aurora's tools, release notes or issues. The qualified M2 hardware is the
  14" M1 Pro and the 16" M2 Max (five displays through HDMI and USB4).
- Nearly all current Aurora display work targets M3 (T6030, T8122, T6031). It does not apply to T6020.
- Manual lists "external displays: works" and one known issue: stale DisplayPort link after an
  HDMI unplug on the M2 Max (replug or reboot).

## Aurora patches checked against `linux/` (fairydust @ ce9f2eba7 + our patches)

All four failed `git apply --check`. Aurora's `atc.c` is about 3,250 lines; ours is 2,514.

| Commit | What it fixes | Fit |
|---|---|---|
| `dff2d7cb5a4b` phy: apple: atc: keep DP alt mode up when dwc3 powers the USB3 PHY off | Monitor works at boot, goes dark on every hot-plug (the monitor's hub re-enumerates, dwc3 cuts the DP lanes) | **High.** About ten lines. Our `atcphy_usb3_power_off()` (atc.c:1989) has the same unguarded `atcphy_configure(..., MODE_OFF)`. Port by hand. |
| `3f9346c8aed0` usb: typec: cd321x: isolate hotplug state by port | One port's USB4 status change tears down DP on another port | Low. Only `usb-pd@3b` is routed. |
| `ebbf4cb22add` usb: typec: tipd: auto-recover the display after standby | Display stays dark after suspend until a replug | Medium, if we suspend. Large, and `tipd/core.c` has drifted. |
| `4527a758a595` drm/apple: keep the j416s tunnel hotplug policy scoped to M2 Pro | M1 link-status handling kept when two series merged | Not needed. It only matters with Aurora's other series. |

## Expected behavior on this Mac

- Two display pipes: HDMI port on `dcpext0`, USB-C on `dcpext1`.
- Four USB-C ports share one pipe: one USB-C display at a time, plus the HDMI port.
  (Read from the DT, not tested.)
- A USB-C-to-HDMI adapter that uses DP alt-mode is handled like a DP monitor.
- USB on the DP port drops to 2.0 under DP pin assignment C. This is expected (PR #289).

## Recommended path

1. Finish the pending step in `HANDOFF.md` §2–3: `sudo scripts/install.sh`, reboot, pick the
   fairydust GRUB entry, run `scripts/verify.sh`. State not confirmed after 2026-09-25.
2. If the monitor goes dark on hot-plug: port `dff2d7cb` as `patches/0003-*`, add
   `patches/pr622-hotplug-fix.diff`, then `scripts/kbuild.sh Image modules`,
   `scripts/stage.sh`, `sudo scripts/install.sh`.
3. Do not adopt the Aurora installer or `m1n1-aurora`.

## Plain-language version

- You have a custom setup that is meant to send video out of one USB-C port. It is built.
- Aurora (the other project) offers nothing that gets video sooner. Its approach changes the Mac's
  low-level startup software, which you said never to touch.
- One small Aurora fix is worth borrowing. It stops the Mac from cutting the video signal when a
  monitor is plugged in late.
- Steps: install the custom setup (password needed), restart and pick the new startup option,
  plug the monitor into "USB-C Back Right Middle", run the check script. If the screen goes black
  after a late plug-in, add the small fix and rebuild.
- If anything goes wrong, power-cycle the Mac. It boots the normal system.

## Sources

- https://github.com/omacom/linux-aurora (release `aurora-2026.10.13.18`, issues #39, #103)
- https://github.com/omacom/omarchy-mac-pkgs (`mac-manual/content/12-hardware.md`)
- https://github.com/omacom/omarchy-mac-installer
- https://github.com/omarchy-mac/omarchy-pkgs-aarch64
