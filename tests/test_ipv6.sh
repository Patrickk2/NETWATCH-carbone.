#!/usr/bin/env bash
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export NETWATCH_CONFIG="$TMP/config"
mkdir -p "$NETWATCH_CONFIG"
source "$ROOT/netwatch-ipv6.sh"

ip6tables(){
    printf '%s\n' "$*" >> "$TMP/ip6tables.log"
    case "$*" in
        -S*) return 1 ;;
        -C*) return 1 ;;
        -N*|-A*|-I*|-D*|-X*) return 0 ;;
        *) return 0 ;;
    esac
}
ip(){
    case "$*" in
        "-6 route show default") printf 'default via 2001:db8::1 dev eth0\n' ;;
        "-6 route show default dev eth0") printf 'default via 2001:db8::1 dev eth0\n' ;;
        "-6 addr show dev eth0 scope global") printf '2001:db8::10/64\n' ;;
        *) : ;;
    esac
}
cat(){ if [[ "$1" == /proc/sys/net/ipv6/conf/all/forwarding ]]; then printf '1\n'; else command cat "$@"; fi; }
detect_ipv6(){ IFACE=eth0; GATEWAY_IPV6=2001:db8::1; }
valid_ipv6 2001:db8::10 >/dev/null || { echo 'FAIL valid IPv6'; exit 1; }
! valid_ipv6 not-an-ip >/dev/null || { echo 'FAIL invalid IPv6 accepted'; exit 1; }
if block 2001:db8::10 >/dev/null 2>&1 && grep -q '2001:db8::10' "$NETWATCH_CONFIG/blocked_ipv6"; then echo 'PASS IPv6 block lifecycle'; else echo 'FAIL IPv6 block lifecycle'; exit 1; fi

printf '%s\n' '2001:db8::10' '2001:db8::11' > "$NETWATCH_CONFIG/blocked_ipv6"
ip6tables(){
    case "$*" in
        '-S '*|-S) printf '%s\n' '-A NETWATCH6_BLOCK -m comment --comment NETWATCH6-owner -j RETURN' ;;
        *) return 0 ;;
    esac
}
unblock 2001:db8::10 >/dev/null 2>&1 || { echo 'FAIL IPv6 unblock'; exit 1; }
grep -Fxq '2001:db8::11' "$NETWATCH_CONFIG/blocked_ipv6" && ! grep -Fxq '2001:db8::10' "$NETWATCH_CONFIG/blocked_ipv6" || { echo 'FAIL IPv6 state cleanup'; exit 1; }
echo 'PASS IPv6 unblock removes state safely'

printf '%s\n' '2001:db8::12' > "$NETWATCH_CONFIG/blocked_ipv6"
BEFORE_RULE_LOG="$TMP/before-dry-run"
: > "$BEFORE_RULE_LOG"
DRY_RUN=true
ip6tables(){ printf '%s\n' "$*" >> "$BEFORE_RULE_LOG"; return 0; }
block 2001:db8::12 >/dev/null 2>&1 || { echo 'FAIL IPv6 dry-run'; exit 1; }
[[ "$(cat "$NETWATCH_CONFIG/blocked_ipv6")" == '2001:db8::12' ]] && [[ ! -s "$BEFORE_RULE_LOG" ]] || { echo 'FAIL IPv6 dry-run changed state'; exit 1; }
echo 'PASS IPv6 dry-run makes no control/state changes'
