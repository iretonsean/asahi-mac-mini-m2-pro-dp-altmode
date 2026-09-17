#!/usr/bin/env bash
# Resolve Type-C ports by STABLE identity (i2c address), never by portN index.
#
# Why: /sys/class/typec/portN indices are assigned in i2c PROBE order, not by
# address, and probe order can race. On this machine the live mapping is
#   0-0038 -> port0   0-003f -> port1   0-003b -> port2   0-003c -> port3
# which is NOT address order (38,3b,3c,3f), confirming probe-order assignment.
# omacom/omarchy-mac PR #289 reports the same physical port appearing as port1
# on one boot and port0 on the next.
#
# Stable keys for Mac mini M2 Pro (j474s / t6020):
#   0x3b  "USB-C Back Right Middle"  phy@f03000000  usb@f02280000   <- DP blessed port
#   0x38  "USB-C Back Left"          phy@703000000  usb@702280000   <- ROOT SSD, never bless
#   0x3f  "USB-C Back Left Middle"   phy@b03000000  usb@b02280000
#   0x3c  "USB-C Back Right"         phy@1303000000 usb@1302280000
#
# Source this file; do not execute it for its side effects.

DP_PORT_I2C="${DP_PORT_I2C:-3b}"      # blessed-for-DisplayPort port
ROOTDISK_PORT_I2C="${ROOTDISK_PORT_I2C:-38}"   # port carrying the external root SSD

# typec_port_by_i2c <addr>  -> prints "portN" for i2c addr (e.g. 3b), or nothing.
typec_port_by_i2c() {
    local addr="${1:?usage: typec_port_by_i2c <addr, e.g. 3b>}" p
    addr="${addr#0x}"
    for p in /sys/class/typec/port[0-9]*; do
        [ -e "$p" ] || continue
        case "${p##*/}" in *-partner|*.*) continue ;; esac
        case "$(readlink -f "$p")" in
            */0-00"$addr"/*) printf '%s\n' "${p##*/}"; return 0 ;;
        esac
    done
    return 1
}

# typec_i2c_by_port <portN> -> prints i2c addr (e.g. 3b)
typec_i2c_by_port() {
    local port="${1:?usage: typec_i2c_by_port <portN>}" rp
    rp="$(readlink -f "/sys/class/typec/$port" 2>/dev/null)" || return 1
    [[ "$rp" =~ /0-00([0-9a-f]+)/ ]] && { printf '%s\n' "${BASH_REMATCH[1]}"; return 0; }
    return 1
}

# typec_sysfs_by_i2c <addr> -> prints the /sys/class/typec/portN path
typec_sysfs_by_i2c() {
    local port; port="$(typec_port_by_i2c "$1")" || return 1
    printf '/sys/class/typec/%s\n' "$port"
}

# typec_label_by_i2c <addr> -> Apple's own connector label from the device tree
typec_label_by_i2c() {
    local addr="${1#0x}" f="/proc/device-tree/soc/i2c@39b040000/usb-pd@${1#0x}/connector/label"
    [ -r "$f" ] && tr -d '\0' < "$f" && echo
}

# assert_not_rootdisk_port <addr> -> fail loudly if addr is the root SSD's port
assert_not_rootdisk_port() {
    local addr="${1#0x}"
    if [ "$addr" = "${ROOTDISK_PORT_I2C#0x}" ]; then
        echo "FATAL: 0x$addr is the port carrying the external root SSD ($(typec_label_by_i2c "$addr")). Refusing." >&2
        return 1
    fi
    return 0
}
