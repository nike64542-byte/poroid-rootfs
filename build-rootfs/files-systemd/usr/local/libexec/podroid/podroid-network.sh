#!/bin/sh
# Podroid VM networking — systemd edition. Port of the OpenRC podroid-network
# start() body (SLIRP static IP on QEMU, DHCP on AVF, USB NIC passthrough).
#
# No `set -e`: matches the OpenRC original — intermediate commands (ip addr
# add on a re-run, tc, etc.) are best-effort; only the explicit exit-1 checks
# below (no NIC / no address) mark the service failed, like eend 1 there.
set -u

echo "Configuring containers..." > /dev/console
ip link set lo up 2>/dev/null

# All physical interfaces (excludes virtual/bridge devices).
PHYS_IFS=$(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | \
    grep -vE '^(lo|dummy[0-9]*|veth|podman|cni|docker|lxcbr|br-)')

NETIF=""
for _i in $(seq 1 10); do
    NETIF=$(printf '%s\n' "$PHYS_IFS" | head -1)
    [ -n "$NETIF" ] && break
    sleep 0.05
done
if [ -z "$NETIF" ]; then
    echo "no network interface" > /dev/console
    exit 1
fi
ip link set "$NETIF" up

if grep -q 'podroid\.backend=avf' /proc/cmdline 2>/dev/null; then
    dhclient -1 -v "$NETIF" 2>/dev/null || true
    [ -s /etc/resolv.conf ] || printf 'nameserver 8.8.8.8\nnameserver 1.1.1.1\n' > /etc/resolv.conf
    if ! ip -o -4 addr show dev "$NETIF" 2>/dev/null | grep -q 'inet '; then
        echo "DHCP did not assign an address to $NETIF" > /dev/console
        exit 1
    fi
else
    ip addr add 10.0.2.15/24 dev "$NETIF" 2>/dev/null
    ip route add default via 10.0.2.2 dev "$NETIF" 2>/dev/null
    DNS_RAW=$(sed -n 's/.*podroid\.dns=\([0-9.,]*\).*/\1/p' /proc/cmdline 2>/dev/null)
    DEVICE_DNS=""
    if [ -n "$DNS_RAW" ]; then
        DNS_RAW=$(echo "$DNS_RAW" | cut -d, -f1)
        case "$DNS_RAW" in
            ''|*[!0-9.]*) ;;
            *) DEVICE_DNS="$DNS_RAW" ;;
        esac
    fi
    if [ -n "$DEVICE_DNS" ]; then
        printf 'nameserver %s\nnameserver 8.8.8.8\nnameserver 1.1.1.1\n' "$DEVICE_DNS" \
            > /etc/resolv.conf
    else
        printf 'nameserver 10.0.2.3\nnameserver 8.8.8.8\nnameserver 1.1.1.1\n' \
            > /etc/resolv.conf
    fi
    echo "DNS: ${DEVICE_DNS:-10.0.2.3} 8.8.8.8" > /dev/console
    if ! ip -o -4 addr show dev "$NETIF" 2>/dev/null | grep -q 'inet '; then
        echo "static IP did not stick on $NETIF" > /dev/console
        exit 1
    fi
fi

BW_MBIT=$(sed -n 's/.*podroid\.bandwidth=\([0-9]*\).*/\1/p' /proc/cmdline 2>/dev/null)
if [ -n "$BW_MBIT" ] && [ "$BW_MBIT" -gt 0 ]; then
    tc qdisc replace dev "$NETIF" root tbf rate "${BW_MBIT}mbit" burst 32kbit latency 400ms 2>/dev/null || true
fi

# USB network adapters passed through (QEMU path only)
if ! grep -q 'podroid\.backend=avf' /proc/cmdline 2>/dev/null; then
    for _if in $PHYS_IFS; do
        [ "$_if" = "$NETIF" ] && continue
        ip -o -4 addr show dev "$_if" 2>/dev/null | grep -q 'inet ' && continue
        echo "USB NIC $_if — running DHCP" > /dev/console
        ip link set "$_if" up 2>/dev/null
        dhclient -1 -v "$_if" 2>/dev/null || true
    done
fi

echo "Network found" > /dev/console
exit 0