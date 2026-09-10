#!/usr/bin/env bash
# netwatch-ipv6 — Linux IPv6 discovery and gateway control helper.
# Usage: netwatch-ipv6.sh [--dry-run] <command> [args...]

set -u
SCRIPT_NAME=$(basename "$0")
if [[ -n "${NETWATCH_CONFIG:-}" ]]; then
    CONFIG_DIR=$NETWATCH_CONFIG
elif [[ ${EUID:-1} -eq 0 ]]; then
    CONFIG_DIR=/etc/netwatch
else
    CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/netwatch"
fi
BLOCK_FILE="$CONFIG_DIR/blocked_ipv6"
DRY_RUN=false
IFACE=""
GATEWAY_IPV6=""

info(){ printf '[+] %s\n' "$*" >&2; }
ok(){ printf '[✓] %s\n' "$*"; }
warn(){ printf '[!] %s\n' "$*" >&2; }
die(){ printf '[x] %s\n' "$*" >&2; exit 1; }

require_root(){ [[ ${EUID:-1} -eq 0 ]] || die 'This command requires root. Run with sudo.'; }

ensure_config_dir(){
    [[ -d "$CONFIG_DIR" ]] || mkdir -p -- "$CONFIG_DIR" || die "Cannot create config directory: $CONFIG_DIR"
    if [[ ${EUID:-1} -eq 0 ]]; then
        local owner mode group_bits other_bits
        owner=$(stat -c '%u' -- "$CONFIG_DIR" 2>/dev/null) || die "Cannot inspect config directory ownership."
        mode=$(stat -c '%a' -- "$CONFIG_DIR" 2>/dev/null) || die "Cannot inspect config directory permissions."
        [[ "$owner" == 0 ]] || die "Refusing root operation with non-root-owned config directory."
        group_bits=$(((10#$mode / 10) % 10))
        other_bits=$((10#$mode % 10))
        (( (group_bits & 2) == 0 && (other_bits & 2) == 0 )) ||
            die "Config directory must not be group/world writable."
    fi
}

check_deps(){
    local kind=${1:-}
    local -a required=()
    case "$kind" in
        scan) required=(ip awk mktemp python3 nmap) ;;
        identify) required=(ip awk python3 nmap) ;;
        block|unblock|reset) required=(ip awk mktemp python3 ip6tables) ;;
        *) required=() ;;
    esac
    local dep
    for dep in "${required[@]}"; do
        command -v "$dep" >/dev/null 2>&1 || die "Missing dependency: $dep"
    done
}

valid_ipv6(){
    [[ -n "$1" ]] || return 1
    python3 - "$1" <<'PY'
import ipaddress, sys
try:
    ipaddress.IPv6Address(sys.argv[1])
except Exception:
    raise SystemExit(1)
PY
}

normalize_ipv6(){
    python3 - "$1" <<'PY'
import ipaddress, sys
try:
    print(ipaddress.IPv6Address(sys.argv[1]))
except Exception:
    raise SystemExit(1)
PY
}

detect_ipv6(){
    local route addr
    route=$(ip -6 route show default 2>/dev/null | awk 'NR==1 {print}')
    IFACE=$(awk '{print $5}' <<< "$route")
    [[ -n "$IFACE" ]] || die 'No IPv6 default route/interface found.'
    addr=$(ip -6 addr show dev "$IFACE" scope global 2>/dev/null | awk '/inet6/ && $2 !~ /^fe80:/ {print $2; exit}')
    [[ -n "$addr" ]] || die "No global IPv6 address found on $IFACE."
    GATEWAY_IPV6=$(awk '{print $3}' <<< "$route")
    if [[ -n "$GATEWAY_IPV6" ]]; then
        GATEWAY_IPV6=$(normalize_ipv6 "$GATEWAY_IPV6") || true
    fi
    info "Interface: $IFACE${GATEWAY_IPV6:+ | Gateway: $GATEWAY_IPV6}"
}

scan(){
    local format=${1:-table}
    [[ "$format" == table || "$format" == json || "$format" == csv ]] ||
        die 'Scan format must be table, json or csv.'
    detect_ipv6
    local tmp rc addr mac state count=0 first=true
    tmp=$(mktemp "${TMPDIR:-/tmp}/netwatch6_XXXXXX") || die 'Cannot create temporary file.'
    ip -6 neigh show dev "$IFACE" 2>/dev/null |
        awk '{
            addr=$1; mac="--"; state=$NF;
            for (i=2;i<=NF;i++) if ($i=="lladdr" && i<NF) mac=$(i+1);
            if (addr ~ /^[0-9A-Fa-f:]+$/ && state!="FAILED" && state!="INCOMPLETE") print addr,mac,state
        }' >"$tmp"
    rc=$?
    ((rc==0)) || { rm -f -- "$tmp"; die 'Failed to read IPv6 neighbor table.'; }

    if [[ "$format" == json ]]; then
        printf '[\n'
    elif [[ "$format" == csv ]]; then
        printf 'ipv6,mac,state\n'
    else
        printf '%-42s %-20s %s\n' 'IPv6 Address' 'MAC' 'State'
        printf '%s\n' '--------------------------------------------------------------------------------'
    fi

    while read -r addr mac state; do
        [[ -n "$addr" ]] || continue
        ((count++))
        case "$format" in
            json)
                $first || printf ',\n'
                first=false
                printf '  {"ipv6":"%s","mac":"%s","state":"%s"}' "$addr" "$mac" "$state"
                ;;
            csv) printf '"%s","%s","%s"\n' "$addr" "$mac" "$state" ;;
            table) printf '%-42s %-20s %s\n' "$addr" "$mac" "$state" ;;
        esac
    done <"$tmp"
    rm -f -- "$tmp"
    [[ "$format" == json ]] && printf '\n]\n'
    [[ "$format" == table ]] && ok "$count IPv6 neighbor(s) found."
}

chain_owned(){
    ip6tables -S NETWATCH6_BLOCK 2>/dev/null |
        grep -Fq -- '-m comment --comment NETWATCH6-owner -j RETURN'
}

write_state(){
    local target=$1
    ensure_config_dir
    if grep -Fqx -- "$target" "$BLOCK_FILE" 2>/dev/null; then
        return 0
    fi
    printf '%s\n' "$target" >> "$BLOCK_FILE" || return 1
}

remove_state(){
    local target=$1
    [[ -f "$BLOCK_FILE" ]] || return 0
    local tmp="$BLOCK_FILE.tmp.$$" rc
    if grep -Fvx -- "$target" "$BLOCK_FILE" >"$tmp"; then
        :
    else
        rc=$?
        if ((rc != 1)); then
            rm -f -- "$tmp"
            return "$rc"
        fi
    fi
    mv -f -- "$tmp" "$BLOCK_FILE"
}

ensure_chain(){
    local created=false
    if ip6tables -S NETWATCH6_BLOCK >/dev/null 2>&1; then
        chain_owned || die 'Refusing to modify existing unrelated chain: NETWATCH6_BLOCK'
    else
        ip6tables -N NETWATCH6_BLOCK || die 'Failed to create NETWATCH6_BLOCK.'
        ip6tables -A NETWATCH6_BLOCK -m comment --comment NETWATCH6-owner -j RETURN ||
            { ip6tables -X NETWATCH6_BLOCK 2>/dev/null || true; die 'Failed to mark NETWATCH6_BLOCK as Netwatch-owned.'; }
        created=true
    fi
    printf '%s' "$created"
}

rollback_block(){
    local target=$1 hook_added=$2 chain_created=$3
    if "$hook_added"; then
        ip6tables -D FORWARD -j NETWATCH6_BLOCK >/dev/null 2>&1 || true
    fi
    ip6tables -D NETWATCH6_BLOCK -d "$target" -j DROP >/dev/null 2>&1 || true
    ip6tables -D NETWATCH6_BLOCK -s "$target" -j DROP >/dev/null 2>&1 || true
    if "$chain_created"; then
        ip6tables -D NETWATCH6_BLOCK -m comment --comment NETWATCH6-owner -j RETURN >/dev/null 2>&1 || true
        ip6tables -X NETWATCH6_BLOCK >/dev/null 2>&1 || true
    fi
}

block(){
    require_root
    local target=${1:-} chain_created hook_added=false
    [[ -n "$target" ]] || die "Usage: $SCRIPT_NAME block <ipv6>"
    valid_ipv6 "$target" || die "Invalid IPv6 address: '$target'"
    target=$(normalize_ipv6 "$target")
    detect_ipv6
    [[ -z "$GATEWAY_IPV6" || "$target" != "$GATEWAY_IPV6" ]] ||
        die 'Refusing to block the default IPv6 gateway.'
    [[ "$(cat /proc/sys/net/ipv6/conf/all/forwarding 2>/dev/null || printf 0)" == 1 ]] ||
        die 'IPv6 blocking requires forwarding=1.'

    if $DRY_RUN; then
        warn "[DRY-RUN] Would add Netwatch-owned IPv6 DROP rules for $target."
        return 0
    fi
    ensure_config_dir
    chain_created=$(ensure_chain)
    if ip6tables -C FORWARD -j NETWATCH6_BLOCK >/dev/null 2>&1; then
        hook_added=false
    else
        ip6tables -I FORWARD 1 -j NETWATCH6_BLOCK || { rollback_block "$target" false "$chain_created"; die 'Failed to attach NETWATCH6_BLOCK.'; }
        hook_added=true
    fi
    if ! ip6tables -C NETWATCH6_BLOCK -s "$target" -j DROP >/dev/null 2>&1; then
        ip6tables -A NETWATCH6_BLOCK -s "$target" -j DROP ||
            { rollback_block "$target" "$hook_added" "$chain_created"; die 'Failed to add IPv6 source block.'; }
    fi
    if ! ip6tables -C NETWATCH6_BLOCK -d "$target" -j DROP >/dev/null 2>&1; then
        ip6tables -A NETWATCH6_BLOCK -d "$target" -j DROP ||
            { rollback_block "$target" "$hook_added" "$chain_created"; die 'Failed to add IPv6 destination block.'; }
    fi
    if ! write_state "$target"; then
        rollback_block "$target" "$hook_added" "$chain_created"
        die 'Failed to persist IPv6 block state; firewall changes were rolled back.'
    fi
    ok "IPv6 block added for $target"
}

unblock(){
    require_root
    local target=${1:-}
    [[ -n "$target" ]] || die "Usage: $SCRIPT_NAME unblock <ipv6>"
    valid_ipv6 "$target" || die "Invalid IPv6 address: '$target'"
    target=$(normalize_ipv6 "$target")
    if $DRY_RUN; then
        warn "[DRY-RUN] Would remove Netwatch-owned IPv6 firewall state for $target."
        return 0
    fi
    ensure_config_dir
    if ip6tables -S NETWATCH6_BLOCK >/dev/null 2>&1; then
        chain_owned || die 'Refusing to modify existing unrelated chain: NETWATCH6_BLOCK'
        ip6tables -D NETWATCH6_BLOCK -s "$target" -j DROP >/dev/null 2>&1 || true
        ip6tables -D NETWATCH6_BLOCK -d "$target" -j DROP >/dev/null 2>&1 || true
    fi
    remove_state "$target" || die 'Failed to update IPv6 block state.'
    if ip6tables -S NETWATCH6_BLOCK >/dev/null 2>&1 && chain_owned; then
        if ! ip6tables -S NETWATCH6_BLOCK 2>/dev/null |
            grep -qv -- '^-A NETWATCH6_BLOCK -m comment --comment NETWATCH6-owner -j RETURN$'; then
            ip6tables -D FORWARD -j NETWATCH6_BLOCK >/dev/null 2>&1 || true
            ip6tables -D NETWATCH6_BLOCK -m comment --comment NETWATCH6-owner -j RETURN >/dev/null 2>&1 || true
            ip6tables -X NETWATCH6_BLOCK >/dev/null 2>&1 || true
        fi
    fi
    ok "IPv6 unblock operation completed for $target."
}

reset_cmd(){
    require_root
    if $DRY_RUN; then
        warn '[DRY-RUN] Would remove only Netwatch-owned IPv6 firewall rules and control state.'
        return 0
    fi
    ensure_config_dir
    if ip6tables -S NETWATCH6_BLOCK >/dev/null 2>&1; then
        chain_owned || die 'Refusing reset: NETWATCH6_BLOCK is not marked as Netwatch-owned.'
        if [[ -f "$BLOCK_FILE" ]]; then
            while IFS= read -r original; do
                valid_ipv6 "$original" || continue
                local target
                target=$(normalize_ipv6 "$original") || continue
                ip6tables -D NETWATCH6_BLOCK -s "$target" -j DROP >/dev/null 2>&1 || true
                ip6tables -D NETWATCH6_BLOCK -d "$target" -j DROP >/dev/null 2>&1 || true
            done < "$BLOCK_FILE"
        fi
        if ! ip6tables -S NETWATCH6_BLOCK 2>/dev/null |
            grep -qv -- '^-A NETWATCH6_BLOCK -m comment --comment NETWATCH6-owner -j RETURN$'; then
            ip6tables -D FORWARD -j NETWATCH6_BLOCK >/dev/null 2>&1 || true
            ip6tables -D NETWATCH6_BLOCK -m comment --comment NETWATCH6-owner -j RETURN >/dev/null 2>&1 || true
            ip6tables -X NETWATCH6_BLOCK >/dev/null 2>&1 || true
        else
            die 'Reset left unexpected rules in NETWATCH6_BLOCK; refusing to delete the chain.'
        fi
    fi
    rm -f -- "$BLOCK_FILE"
    ok 'Netwatch-owned IPv6 control state reset.'
}

show_help(){
    cat <<EOF
netwatch-ipv6 v1.3.1 — Linux IPv6 discovery and gateway control

Usage:
  $SCRIPT_NAME [--dry-run] <command> [args]

Commands:
  scan [table|json|csv]  Discover on-link IPv6 neighbors
  identify <ipv6>        Run Nmap IPv6 service/OS identification
  block <ipv6>           Block an IPv6 target on a Linux gateway
  unblock <ipv6>         Remove a Netwatch-owned IPv6 block
  reset                  Remove only Netwatch-owned IPv6 control state
  help                   Show this help

Safety:
  Blocking requires root, IPv6 forwarding, a detected IPv6 gateway, and an
  owned NETWATCH6_BLOCK chain. The default IPv6 gateway is never blockable.
  --dry-run performs no firewall or persistent-state changes.
EOF
}

if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
    return 0
fi

args=()
for arg in "$@"; do
    case "$arg" in --dry-run) DRY_RUN=true;; *) args+=("$arg");; esac
done
set -- "${args[@]}"
CMD=${1:-help}
shift || true
case "$CMD" in
    scan) check_deps scan; scan "${1:-table}" ;;
    identify) check_deps identify; detect_ipv6; target=${1:-}; valid_ipv6 "${target:-}" || die "Invalid IPv6 address: '${target:-}'"; nmap -6 -sV -O --osscan-guess --max-retries 1 --host-timeout 30s -T4 "$(normalize_ipv6 "$target")" ;;
    block) check_deps block; block "${1:-}" ;;
    unblock) check_deps unblock; unblock "${1:-}" ;;
    reset) check_deps reset; reset_cmd ;;
    help|-h|--help) show_help ;;
    *) die "Unknown command: $CMD. Run '$SCRIPT_NAME help'." ;;
esac
