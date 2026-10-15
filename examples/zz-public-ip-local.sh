#!/bin/sh
# Optional extra glue for Keenetic setups where the router's public address is
# not configured on the router itself, but on an upstream NAT device. Without
# this, LAN clients and the router itself dial that public address, the packet
# leaves towards the ISP and comes back through the policy/proxy path, which
# breaks local access to the router's own services on that address (panel,
# WebDAV, etc.).
#
# What it does on every NDM firewall rebuild:
#   1. adds PUBLIC_IP/32 to the s-ui bypass ipset (so it is never proxied);
#   2. DNATs PUBLIC_IP:any from the LAN interfaces and from the router itself
#      to the router's LAN address.
#
# Install as /opt/etc/ndm/netfilter.d/zz-public-ip-local.sh and configure
# /opt/etc/sui-tproxy/zz-public-ip-local.conf. Does nothing while PUBLIC_IP is
# empty, so it is safe to keep installed.

CONF=/opt/etc/sui-tproxy/zz-public-ip-local.conf
[ -r "$CONF" ] && . "$CONF"

PUBLIC_IP="${PUBLIC_IP:-}"
ROUTER_IP="${ROUTER_IP:-}"
LAN_IFACES="${LAN_IFACES:-}"

[ "$type" = "iptables" ] || exit 0
[ "$table" = "nat" ] || [ "$table" = "mangle" ] || exit 0

[ -n "$PUBLIC_IP" ] || exit 0
[ -n "$ROUTER_IP" ] || exit 0

if ipset list sui_tproxy_bypass4 >/dev/null 2>&1; then
    ipset add sui_tproxy_bypass4 "$PUBLIC_IP/32" -exist 2>/dev/null || \
        ipset add sui_tproxy_bypass4 "$PUBLIC_IP/32" 2>/dev/null
fi

[ "$table" = "nat" ] || exit 0

for iface in $LAN_IFACES; do
    iptables -t nat -C PREROUTING -i "$iface" -d "$PUBLIC_IP/32" \
        -j DNAT --to-destination "$ROUTER_IP" 2>/dev/null || \
        iptables -t nat -I PREROUTING 1 -i "$iface" -d "$PUBLIC_IP/32" \
            -j DNAT --to-destination "$ROUTER_IP"
done

iptables -t nat -C OUTPUT -d "$PUBLIC_IP/32" \
    -j DNAT --to-destination "$ROUTER_IP" 2>/dev/null || \
    iptables -t nat -I OUTPUT 1 -d "$PUBLIC_IP/32" \
        -j DNAT --to-destination "$ROUTER_IP"
