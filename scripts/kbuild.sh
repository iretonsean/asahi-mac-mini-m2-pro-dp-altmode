#!/bin/bash
# kbuild.sh — one consistent environment for building the fairydust kernel rootless.
# Pinned per-user toolchain (rustup 1.93.1, bindgen 0.73.2, bc/dtc in ~/.local) matches
# the running linux-asahi 7.1.13 build. LOCALVERSION= (empty, explicit) suppresses the
# "+" suffix so the release string is exactly 7.1.13-fairydust-dp everywhere.
set -e
export PATH="$HOME/.cargo/bin:$HOME/.local/bin:$PATH"
cd "$(dirname "$0")/../linux"
exec nice -n 10 make -j"${JOBS:-10}" LOCALVERSION= "$@"
