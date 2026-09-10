#!/usr/bin/env bash
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export NETWATCH_CONFIG="$TMP/config"
mkdir -p "$NETWATCH_CONFIG"
LOG="$TMP/iptables.log"

run_success_block(){
    source "$ROOT/netwatch.sh"
    iptables(){
        printf '%s\n' "$*" >> "$LOG"
        case "$1" in
            -S) return 1 ;;
            -C) return 1 ;;
            *) return 0 ;;
        esac
    }
    ip(){ printf '192.168.1.42 dev eth0 lladdr AA:BB:CC:DD:EE:FF REACHABLE\n'; }
    cat(){ if [[ "$1" == /proc/sys/net/ipv4/ip_forward ]]; then printf '1\n'; else command cat "$@"; fi; }
    detect_network(){ SUBNET=192.168.1.0/24; GATEWAY=192.168.1.1; IFACE=eth0; }
    block 192.168.1.42
}

if run_success_block >/dev/null 2>&1; then
    grep -q -- '-A NETWATCH_BLOCK -s 192.168.1.42 -j DROP' "$LOG" &&
    grep -q -- '-A NETWATCH_BLOCK -d 192.168.1.42 -j DROP' "$LOG" &&
    grep -q -- '192.168.1.42' "$NETWATCH_CONFIG/blocked_ips" &&
    grep -q -- 'AA:BB:CC:DD:EE:FF' "$NETWATCH_CONFIG/blocked_macs" ||
    { echo 'FAIL successful block did not create expected firewall/state'; exit 1; }
    echo 'PASS successful block records state after firewall application'
else
    echo 'FAIL successful block'; exit 1
fi

rm -f "$LOG" "$NETWATCH_CONFIG/blocked_ips" "$NETWATCH_CONFIG/blocked_macs"

if bash -c '
    export NETWATCH_CONFIG="$1"
    LOG="$2"
    source "$3"
    iptables(){
        printf "%s\n" "$*" >> "$LOG"
        case "$*" in
            "-S"*) return 1 ;;
            "-C"*) return 1 ;;
            "-A NETWATCH_BLOCK -d"*) return 1 ;;
            *) return 0 ;;
        esac
    }
    ip(){ printf "192.168.1.42 dev eth0 lladdr AA:BB:CC:DD:EE:FF REACHABLE\n"; }
    cat(){ if [[ "$1" == /proc/sys/net/ipv4/ip_forward ]]; then printf "1\n"; else command cat "$@"; fi; }
    detect_network(){ SUBNET=192.168.1.0/24; GATEWAY=192.168.1.1; IFACE=eth0; }
    block 192.168.1.42
' _ "$NETWATCH_CONFIG" "$LOG" "$ROOT/netwatch.sh" >/dev/null 2>&1; then
    echo 'FAIL partial firewall failure returned success'; exit 1
fi
[[ ! -s "$NETWATCH_CONFIG/blocked_ips" ]] || { echo 'FAIL partial firewall failure persisted IPv4 state'; exit 1; }
[[ ! -s "$NETWATCH_CONFIG/blocked_macs" ]] || { echo 'FAIL partial firewall failure persisted MAC state'; exit 1; }
grep -q -- '-D NETWATCH_BLOCK -s 192.168.1.42 -j DROP' "$LOG" || { echo 'FAIL rollback did not remove source rule'; exit 1; }
echo 'PASS partial firewall failure rolls back without persisted state'

if bash -c '
    export NETWATCH_CONFIG="$1"
    source "$2"
    iptables(){
        case "$*" in
            "-S NETWATCH_BLOCK") printf "%s\n" "-A NETWATCH_BLOCK -s 192.168.1.99 -j DROP"; return 0 ;;
            *) return 1 ;;
        esac
    }
    ip(){ printf "192.168.1.42 dev eth0 lladdr AA:BB:CC:DD:EE:FF REACHABLE\n"; }
    cat(){ if [[ "$1" == /proc/sys/net/ipv4/ip_forward ]]; then printf "1\n"; else command cat "$@"; fi; }
    detect_network(){ SUBNET=192.168.1.0/24; GATEWAY=192.168.1.1; IFACE=eth0; }
    block 192.168.1.42
' _ "$NETWATCH_CONFIG" "$ROOT/netwatch.sh" >/dev/null 2>&1; then
    echo 'FAIL unrelated IPv4 chain was accepted'; exit 1
else
    echo 'PASS unrelated IPv4 chain is rejected'
fi
