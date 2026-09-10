#!/usr/bin/env bash
# netwatch — Linux network monitor and gateway control tool.
# Usage: netwatch.sh [--dry-run] [--persistent] <command> [args...]

VERSION="1.3.1"
REPOSITORY_URL="https://github.com/sudomarc/NETWATCH"
UPDATE_URL="https://raw.githubusercontent.com/sudomarc/NETWATCH/main/netwatch.sh"
SCRIPT_NAME=$(basename "$0")

if [[ -n "${NETWATCH_CONFIG:-}" ]]; then
    CONFIG_DIR=$NETWATCH_CONFIG
elif [[ ${EUID:-1} -eq 0 ]]; then
    CONFIG_DIR=/etc/netwatch
else
    CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/netwatch"
fi

BLOCK_FILE="$CONFIG_DIR/blocked_macs"
BLOCK_IP_FILE="$CONFIG_DIR/blocked_ips"
THROTTLE_FILE="$CONFIG_DIR/throttled_macs"
SCAN_LOG="$CONFIG_DIR/scan_history.log"
SUBNET=""
GATEWAY=""
IFACE=""
DRY_RUN=false
PERSISTENT=false

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'; NC=$'\033[0m'

info(){ printf '%s[•]%s %s\n' "$BLUE" "$NC" "$*" >&2; }
ok(){ printf '%s[✓]%s %s\n' "$GREEN" "$NC" "$*"; }
warn(){ printf '%s[!]%s %s\n' "$YELLOW" "$NC" "$*" >&2; }
err(){ printf '%s[✗]%s %s\n' "$RED" "$NC" "$*" >&2; }
die(){ err "$*"; exit 1; }

require_root(){ [[ ${EUID:-1} -eq 0 ]] || die "This command requires root. Run with sudo."; }

ensure_config_dir(){
    [[ -d "$CONFIG_DIR" ]] || mkdir -p -- "$CONFIG_DIR" || die "Cannot create config directory: $CONFIG_DIR"
    if [[ ${EUID:-1} -eq 0 ]]; then
        local owner mode group_bits other_bits
        owner=$(stat -c '%u' -- "$CONFIG_DIR" 2>/dev/null) || die "Cannot inspect config directory ownership: $CONFIG_DIR"
        mode=$(stat -c '%a' -- "$CONFIG_DIR" 2>/dev/null) || die "Cannot inspect config directory permissions: $CONFIG_DIR"
        [[ "$owner" == "0" ]] || die "Refusing root operation with non-root-owned config directory: $CONFIG_DIR"
        group_bits=$(((10#$mode / 10) % 10))
        other_bits=$((10#$mode % 10))
        (( (group_bits & 2) == 0 && (other_bits & 2) == 0 )) ||
            die "Config directory must not be group/world writable: $CONFIG_DIR"
    fi
}

log(){
    ensure_config_dir
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$SCAN_LOG" ||
        warn "Unable to write log: $SCAN_LOG"
}

version_compare(){
    local a=$1 b=$2 i va vb
    [[ "$a" =~ ^[0-9]+([.][0-9]+){0,2}$ && "$b" =~ ^[0-9]+([.][0-9]+){0,2}$ ]] || return 2
    local -a aa=() bb=()
    IFS=. read -r -a aa <<< "$a"
    IFS=. read -r -a bb <<< "$b"
    for ((i=0; i<3; i++)); do
        va=${aa[i]:-0}; vb=${bb[i]:-0}
        ((10#$va > 10#$vb)) && return 0
        ((10#$va < 10#$vb)) && return 1
    done
    return 1
}

valid_ipv4(){
    python3 - "$1" <<'PY'
import ipaddress, sys
try:
    addr = ipaddress.IPv4Address(sys.argv[1])
except Exception:
    raise SystemExit(1)
if str(addr) != sys.argv[1]:
    raise SystemExit(1)
PY
}

is_valid_mac(){ [[ "${1^^}" =~ ^([0-9A-F]{2}:){5}[0-9A-F]{2}$ ]]; }
is_valid_speed(){ [[ "$1" =~ ^[0-9]+(kbit|mbit|gbit|kbps|mbps)$ ]]; }
normalize_mac(){ printf '%s\n' "${1^^}"; }

check_deps(){
    local command_name=$1
    local -a required=()
    case "$command_name" in
        scan|monitor|export) required=(nmap ip awk mktemp) ;;
        identify) required=(nmap ip awk python3) ;;
        block|unblock) required=(iptables ip awk python3 mktemp) ;;
        reset) required=(iptables ip awk) ;;
        throttle|unthrottle) required=(python3) ;;
        update) required=(grep head cut) ;;
        *) required=() ;;
    esac
    local dep missing=()
    for dep in "${required[@]}"; do
        command -v "$dep" >/dev/null 2>&1 || missing+=("$dep")
    done
    ((${#missing[@]}==0)) || die "Missing dependencies for '$command_name': ${missing[*]}"
}

detect_network(){
    local route ip_route
    route=$(ip -4 route show default 2>/dev/null | awk 'NR==1 {print $0}')
    GATEWAY=$(awk '{print $3}' <<< "$route")
    IFACE=$(awk '{print $5}' <<< "$route")
    [[ -n "$GATEWAY" && -n "$IFACE" ]] || die "No IPv4 default gateway/interface found."
    valid_ipv4 "$GATEWAY" || die "Detected invalid IPv4 gateway: $GATEWAY"
    ip_route=$(ip -4 addr show dev "$IFACE" 2>/dev/null | awk '/inet / {print $2; exit}')
    [[ -n "$ip_route" ]] || die "No IPv4 address on interface $IFACE."
    SUBNET=$(ip -4 route show dev "$IFACE" scope link 2>/dev/null |
        awk '$1 ~ /^[0-9]+\./ {print $1; exit}')
    if [[ -z "$SUBNET" ]]; then
        SUBNET=$(python3 - "$ip_route" <<'PY'
import ipaddress, sys
try:
    print(ipaddress.ip_interface(sys.argv[1]).network)
except Exception:
    raise SystemExit(1)
PY
        ) || die "Unable to determine the IPv4 subnet for $IFACE."
    fi
    info "Interface: $IFACE | Subnet: $SUBNET | Gateway: $GATEWAY"
}

vendor(){
    local oui
    oui=$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]' | cut -d: -f1-3)
    case "$oui" in
        00:1A:2B|00:50:56|00:0C:29|00:05:69) echo VMware ;;
        00:1C:42) echo Parallels ;;
        00:03:93|A4:4C:C8|00:26:9E|00:0D:93|3C:07:54|A8:86:DD) echo Apple ;;
        00:1E:58|00:1F:3A|00:21:5C|14:18:77) echo Dell ;;
        00:1A:A0|00:1E:4C|00:24:E8|30:8D:99) echo HP ;;
        00:25:90|00:1B:21|00:1D:09|8C:EC:4B) echo Intel ;;
        00:16:E9|00:18:7D|00:1F:33|F8:7B:20) echo Cisco ;;
        20:CF:30|2C:B0:5D|64:B4:73) echo Xiaomi ;;
        A4:77:33|AC:CF:85|40:B0:34|B4:79:A7) echo Samsung ;;
        B8:27:EB|DC:A6:32|E4:5F:01) echo Raspberry\ Pi ;;
        *) echo Unknown ;;
    esac
}

json_escape(){
    local value=$1
    value=${value//\\/\\\\}
    value=${value//"/\\"}
    value=${value//$'\t'/\\t}
    value=${value//$'\r'/\\r}
    value=${value//$'\n'/\\n}
    printf '%s' "$value"
}

csv_escape(){
    local value=$1
    value=${value//"/""}
    printf '"%s"' "$value"
}

scan(){
    local format=${1:-table}
    case "$format" in table|json|csv) ;; *) die "Scan format must be table, json or csv." ;; esac
    ensure_config_dir
    local tmp rc count=0 line addr mac hostname vend first=true
    tmp=$(mktemp "${TMPDIR:-/tmp}/netwatch_XXXXXX") || die "Cannot create temporary file."
    trap 'rm -f -- "$tmp"' RETURN
    nmap -sn -PR "$SUBNET" --max-retries 2 --host-timeout 8s -oG - >"$tmp" 2>/dev/null
    rc=$?
    ((rc==0)) || { err "nmap scan failed."; return "$rc"; }
    ip neigh flush nud stale >/dev/null 2>&1 || true

    if [[ "$format" == json ]]; then printf '[\n'; elif [[ "$format" == csv ]]; then printf 'ip,mac,hostname,vendor\n'; fi

    while IFS= read -r line; do
        [[ "$line" == Host:*" Status: Up"* ]] || continue
        addr=$(awk '{print $2}' <<< "$line")
        [[ "$addr" == "$GATEWAY" ]] && continue
        mac=$(ip neigh show "$addr" 2>/dev/null | awk 'NR==1 {print toupper($5); exit}')
        [[ -n "$mac" && "$mac" != FAILED && "$mac" != INCOMPLETE ]] || mac=--
        hostname=$(getent hosts "$addr" 2>/dev/null | awk 'NR==1 {print $2; exit}')
        [[ -n "$hostname" ]] || hostname=-
        vend=-
        if [[ "$mac" != -- ]] && is_valid_mac "$mac"; then
            vend=$(vendor "$mac")
        fi
        ((count++))
        case "$format" in
            json)
                $first || printf ',\n'
                first=false
                printf '  {"ip":"%s","mac":"%s","hostname":"%s","vendor":"%s"}' \
                    "$(json_escape "$addr")" "$(json_escape "$mac")" \
                    "$(json_escape "$hostname")" "$(json_escape "$vend")"
                ;;
            csv)
                printf '%s,%s,%s,%s\n' "$(csv_escape "$addr")" "$(csv_escape "$mac")" \
                    "$(csv_escape "$hostname")" "$(csv_escape "$vend")"
                ;;
            table)
                printf '%-16s %-18s %-24s %-14s\n' "$addr" "$mac" "${hostname:0:24}" "${vend:0:14}"
                ;;
        esac
    done < "$tmp"

    if [[ "$format" == json ]]; then printf '\n]\n'; elif [[ "$format" == table ]]; then ok "$count device(s) found."; fi
    log "scan: $count devices on $SUBNET"
}

monitor(){
    local interval=${1:-30}
    [[ "$interval" =~ ^[1-9][0-9]*$ && "$interval" -le 3600 ]] || die "Interval must be between 1 and 3600 seconds."
    while :; do
        clear
        detect_network
        scan table
        sleep "$interval"
    done
}

chain_owned(){
    local command=$1 chain=$2 marker=$3
    "$command" -C "$chain" -m comment --comment "$marker" -j RETURN >/dev/null 2>&1
}

chain_only_marker(){
    local command=$1 chain=$2 marker=$3 rules
    rules=$("$command" -S "$chain" 2>/dev/null | sed 's/"//g') || return 1
    ! grep -qv -- "^-A $chain -m comment --comment $marker -j RETURN$" <<< "$rules"
}

write_state_line(){
    local file=$1 value=$2
    ensure_config_dir
    if grep -Fqx -- "$value" "$file" 2>/dev/null; then
        return 0
    fi
    printf '%s\n' "$value" >> "$file"
}

remove_state_line(){
    local file=$1 value=$2
    [[ -f "$file" ]] || return 0
    local tmp="$file.tmp.$$" rc
    if grep -Fvx -- "$value" "$file" > "$tmp"; then
        :
    else
        rc=$?
        if ((rc != 1)); then
            rm -f -- "$tmp"
            return "$rc"
        fi
    fi
    mv -f -- "$tmp" "$file"
}

ensure_chain(){
    local command=$1 chain=$2 marker=$3
    if "$command" -S "$chain" >/dev/null 2>&1; then
        chain_owned "$command" "$chain" "$marker" || die "Refusing to modify existing unrelated chain: $chain"
        CHAIN_CREATED=false
    else
        "$command" -N "$chain" || die "Failed to create $chain."
        "$command" -A "$chain" -m comment --comment "$marker" -j RETURN ||
            { "$command" -X "$chain" 2>/dev/null || true; die "Failed to mark $chain as Netwatch-owned."; }
        CHAIN_CREATED=true
    fi
}

rollback_ipv4(){
    local ip=$1 mac=$2 hook_added=$3 chain_created=$4
    "$hook_added" && iptables -D FORWARD -j NETWATCH_BLOCK >/dev/null 2>&1 || true
    [[ -n "$mac" && "$mac" != -- ]] && iptables -D NETWATCH_BLOCK -m mac --mac-source "$mac" -j DROP >/dev/null 2>&1 || true
    iptables -D NETWATCH_BLOCK -d "$ip" -j DROP >/dev/null 2>&1 || true
    iptables -D NETWATCH_BLOCK -s "$ip" -j DROP >/dev/null 2>&1 || true
    if "$chain_created"; then
        iptables -D NETWATCH_BLOCK -m comment --comment NETWATCH-owner -j RETURN >/dev/null 2>&1 || true
        iptables -X NETWATCH_BLOCK >/dev/null 2>&1 || true
    fi
}

start_arp(){
    local ip=$1 pidfile=$2
    command -v arpspoof >/dev/null 2>&1 || return 0
    : > "$pidfile" || return 1
    chmod 600 "$pidfile" || return 1
    local p1 p2
    arpspoof -i "$IFACE" -t "$ip" "$GATEWAY" >/dev/null 2>&1 & p1=$!
    arpspoof -i "$IFACE" -t "$GATEWAY" "$ip" >/dev/null 2>&1 & p2=$!
    sleep 0.1
    if ! kill -0 "$p1" 2>/dev/null || ! kill -0 "$p2" 2>/dev/null; then
        stop_arp "$pidfile" "$ip" "$GATEWAY"
        return 1
    fi
    printf '%s\n%s\n' "$p1" "$p2" > "$pidfile"
}

stop_arp(){
    local pidfile=$1 first_target=$2 second_target=$3
    [[ -f "$pidfile" ]] || return 0
    local pid cmdline
    while IFS= read -r pid; do
        [[ "$pid" =~ ^[0-9]+$ ]] || continue
        cmdline=$(ps -p "$pid" -o args= 2>/dev/null || true)
        [[ "$cmdline" == *arpspoof* && "$cmdline" == *"-i $IFACE"* &&
           "$cmdline" == *"-t $first_target"* && "$cmdline" == *"$second_target"* ]] &&
            kill "$pid" 2>/dev/null || true
    done < "$pidfile"
    rm -f -- "$pidfile"
}

persist_ipv4(){
    local tmp="/etc/iptables/.netwatch-rules.v4.$$"
    command -v iptables-save >/dev/null 2>&1 || { err "iptables-save is required for --persistent."; return 1; }
    mkdir -p /etc/iptables || return 1
    chmod 755 /etc/iptables || return 1
    iptables-save > "$tmp" || { rm -f -- "$tmp"; return 1; }
    chmod 600 "$tmp" || { rm -f -- "$tmp"; return 1; }
    mv -f -- "$tmp" /etc/iptables/rules.v4 || return 1
}

block(){
    require_root
    local target=${1:-} ip="" mac="" pidfile=""
    [[ -n "$target" ]] || die "Usage: $SCRIPT_NAME block <ip|mac>"
    if is_valid_mac "$target"; then
        mac=$(normalize_mac "$target")
        ip=$(ip neigh show dev "$IFACE" 2>/dev/null | awk -v m="$mac" 'toupper($5)==m{print $1; exit}')
        [[ -n "$ip" ]] || die "Cannot resolve IP for $mac. Run scan first."
    elif valid_ipv4 "$target"; then
        ip=$target
        mac=$(ip neigh show dev "$IFACE" "$ip" 2>/dev/null | awk 'NR==1 {print toupper($5); exit}')
        [[ "$mac" == FAILED ]] && mac=""
    else
        die "Invalid IPv4 address or MAC: '$target'"
    fi
    [[ "$ip" != "$GATEWAY" ]] || die "Refusing to block the default gateway."
    [[ "$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || printf 0)" == 1 ]] ||
        die "Blocking requires this Linux host to be the IPv4 gateway/router."

    if $DRY_RUN; then
        warn "[DRY-RUN] Would add Netwatch-owned DROP rules for $ip${mac:+ / $mac}."
        command -v arpspoof >/dev/null 2>&1 && warn "[DRY-RUN] Would start ARP spoofing processes."
        $PERSISTENT && warn "[DRY-RUN] Would persist iptables state."
        return 0
    fi

    ensure_config_dir
    local hook_added=false
    ensure_chain iptables NETWATCH_BLOCK NETWATCH-owner
    if ! iptables -C FORWARD -j NETWATCH_BLOCK >/dev/null 2>&1; then
        iptables -I FORWARD 1 -j NETWATCH_BLOCK || { rollback_ipv4 "$ip" "$mac" false "$CHAIN_CREATED"; die "Failed to attach NETWATCH_BLOCK."; }
        hook_added=true
    fi

    if ! iptables -C NETWATCH_BLOCK -s "$ip" -j DROP >/dev/null 2>&1; then
        iptables -A NETWATCH_BLOCK -s "$ip" -j DROP || { rollback_ipv4 "$ip" "$mac" "$hook_added" "$CHAIN_CREATED"; die "Failed to add source block."; }
    fi
    if ! iptables -C NETWATCH_BLOCK -d "$ip" -j DROP >/dev/null 2>&1; then
        iptables -A NETWATCH_BLOCK -d "$ip" -j DROP || { rollback_ipv4 "$ip" "$mac" "$hook_added" "$CHAIN_CREATED"; die "Failed to add destination block."; }
    fi
    if [[ -n "$mac" && "$mac" != -- ]] && ! iptables -C NETWATCH_BLOCK -m mac --mac-source "$mac" -j DROP >/dev/null 2>&1; then
        iptables -A NETWATCH_BLOCK -m mac --mac-source "$mac" -j DROP || { rollback_ipv4 "$ip" "$mac" "$hook_added" "$CHAIN_CREATED"; die "Failed to add MAC block."; }
    fi

    pidfile="$CONFIG_DIR/arp_${ip//./_}.pid"
    if ! start_arp "$ip" "$pidfile"; then
        rollback_ipv4 "$ip" "$mac" "$hook_added" "$CHAIN_CREATED"
        die "ARP spoofing process setup failed; firewall changes were rolled back."
    fi

    if $PERSISTENT && ! persist_ipv4; then
        stop_arp "$pidfile" "$ip" "$GATEWAY"
        rollback_ipv4 "$ip" "$mac" "$hook_added" "$CHAIN_CREATED"
        die "Failed to persist firewall state; firewall changes were rolled back."
    fi

    if [[ -n "$mac" && "$mac" != -- ]] && ! write_state_line "$BLOCK_FILE" "$mac"; then
        stop_arp "$pidfile" "$ip" "$GATEWAY"
        rollback_ipv4 "$ip" "$mac" "$hook_added" "$CHAIN_CREATED"
        die 'Failed to persist MAC block state; firewall changes were rolled back.'
    fi
    if ! write_state_line "$BLOCK_IP_FILE" "$ip"; then
        stop_arp "$pidfile" "$ip" "$GATEWAY"
        rollback_ipv4 "$ip" "$mac" "$hook_added" "$CHAIN_CREATED"
        if [[ -n "$mac" && "$mac" != -- ]]; then
            remove_state_line "$BLOCK_FILE" "$mac" || true
        fi
        die 'Failed to persist IPv4 block state; firewall changes were rolled back.'
    fi
    log "block: $ip${mac:+ ($mac)}"
    ok "Blocked $ip${mac:+ ($mac)} via Netwatch-owned gateway firewall."
}

unblock(){
    require_root
    local target=${1:-} ip="" mac="" pidfile=""
    [[ -n "$target" ]] || die "Usage: $SCRIPT_NAME unblock <ip|mac>"
    if is_valid_mac "$target"; then
        mac=$(normalize_mac "$target")
        ip=$(ip neigh show dev "$IFACE" 2>/dev/null | awk -v m="$mac" 'toupper($5)==m{print $1; exit}')
    elif valid_ipv4 "$target"; then
        ip=$target
        mac=$(ip neigh show dev "$IFACE" "$ip" 2>/dev/null | awk 'NR==1 {print toupper($5); exit}')
    else
        die "Invalid IPv4 address or MAC: '$target'"
    fi

    if $DRY_RUN; then
        warn "[DRY-RUN] Would remove Netwatch-owned firewall state for ${ip:-$mac}."
        return 0
    fi

    ensure_config_dir
    local chain_exists=false
    if iptables -S NETWATCH_BLOCK >/dev/null 2>&1; then
        chain_exists=true
        chain_owned iptables NETWATCH_BLOCK NETWATCH-owner ||
            die 'Refusing to modify existing unrelated chain: NETWATCH_BLOCK'
    fi
    if [[ -n "$ip" ]]; then
        pidfile="$CONFIG_DIR/arp_${ip//./_}.pid"
        stop_arp "$pidfile" "$ip" "$GATEWAY"
    fi
    if $chain_exists; then
        [[ -z "$ip" ]] || {
            iptables -D NETWATCH_BLOCK -s "$ip" -j DROP >/dev/null 2>&1 || true
            iptables -D NETWATCH_BLOCK -d "$ip" -j DROP >/dev/null 2>&1 || true
        }
        [[ -z "$mac" || "$mac" == -- ]] || iptables -D NETWATCH_BLOCK -m mac --mac-source "$mac" -j DROP >/dev/null 2>&1 || true
    fi
    if [[ -n "$ip" ]] && ! remove_state_line "$BLOCK_IP_FILE" "$ip"; then
        die 'Failed to update blocked IP state.'
    fi
    if [[ -n "$mac" && "$mac" != -- ]] && ! remove_state_line "$BLOCK_FILE" "$mac"; then
        die 'Failed to update blocked MAC state.'
    fi
    if $chain_exists && chain_only_marker iptables NETWATCH_BLOCK NETWATCH-owner; then
        iptables -D FORWARD -j NETWATCH_BLOCK >/dev/null 2>&1 || true
        iptables -D NETWATCH_BLOCK -m comment --comment NETWATCH-owner -j RETURN >/dev/null 2>&1 || true
        iptables -X NETWATCH_BLOCK >/dev/null 2>&1 || true
    fi
    $PERSISTENT && ! persist_ipv4 && die "Firewall changed, but persistence could not be updated."
    log "unblock: ${ip:-$mac}"
    ok "Unblock operation completed for ${ip:-$mac}."
}

throttle(){
    require_root
    local mac=${1:-} speed=${2:-}
    is_valid_mac "$mac" || die "Invalid MAC: '$mac'"
    is_valid_speed "$speed" || die "Invalid speed '$speed'."
    die "Throttle is unavailable in this stabilized build; no QoS rules are installed."
}

unthrottle(){
    require_root
    local mac=${1:-}
    is_valid_mac "$mac" || die "Invalid MAC: '$mac'"
    die "Unthrottle is unavailable because NETWATCH does not install QoS rules in this build."
}

list(){
    printf 'Blocked MACs:\n'
    [[ -f "$BLOCK_FILE" ]] && cat -- "$BLOCK_FILE" || printf '  (none)\n'
    printf '\nBlocked IPv4s:\n'
    [[ -f "$BLOCK_IP_FILE" ]] && cat -- "$BLOCK_IP_FILE" || printf '  (none)\n'
    printf '\nThrottle state: unavailable (QoS is disabled in v%s)\n' "$VERSION"
}

export_scan(){
    local fmt=${1:-csv}
    [[ "$fmt" == csv || "$fmt" == json ]] || die "Export format must be csv or json."
    check_deps export
    detect_network
    ensure_config_dir
    local outfile="$CONFIG_DIR/export_$(date '+%Y%m%d_%H%M%S').$fmt"
    scan "$fmt" > "$outfile" || die "Export failed."
    ok "Saved to $outfile"
}

identify(){
    local target=${1:-} ip="" rc
    [[ -n "$target" ]] || die "Usage: $SCRIPT_NAME identify <ip|mac>"
    if is_valid_mac "$target"; then
        ip=$(ip neigh show 2>/dev/null | awk -v m="${target^^}" 'toupper($5)==m {print $1; exit}')
    elif valid_ipv4 "$target"; then
        ip=$target
    else
        die "Invalid IPv4 address or MAC: '$target'"
    fi
    [[ -n "$ip" ]] || die 'Target not found.'
    printf 'Device Profile: %s\n' "$ip"
    nmap -sV -O --osscan-guess --max-retries 1 --host-timeout 30s -T4 "$ip"
    rc=$?
    ((rc==0)) || { err "Identification failed for $ip."; log "identify: $ip (failed rc=$rc)"; return "$rc"; }
    log "identify: $ip (success)"
}

update_cmd(){
    local remote_version
    if [[ ! "$VERSION" =~ ^[0-9]+([.][0-9]+){0,2}$ ]]; then die "Local version is invalid: $VERSION"; fi
    if command -v curl >/dev/null 2>&1; then
        remote_version=$(curl -fsSL --max-time 8 "$UPDATE_URL" 2>/dev/null | grep '^VERSION=' | head -n1 | cut -d'"' -f2)
    elif command -v wget >/dev/null 2>&1; then
        remote_version=$(wget -qO- --timeout=8 "$UPDATE_URL" 2>/dev/null | grep '^VERSION=' | head -n1 | cut -d'"' -f2)
    else
        die "Neither curl nor wget is installed."
    fi
    [[ -n "$remote_version" && "$remote_version" =~ ^[0-9]+([.][0-9]+){0,2}$ ]] ||
        die "Failed to retrieve a valid remote version."
    if version_compare "$remote_version" "$VERSION"; then
        warn "A newer version is available: v$remote_version (current v$VERSION)."
        warn "Automatic self-update is disabled. Review a release and install it manually."
    else
        local cmp=$?
        if ((cmp==1)); then
            ok "netwatch is up to date (v$VERSION)."
        else
            die "Version comparison failed."
        fi
    fi
}

reset_cmd(){
    require_root
    if $DRY_RUN; then
        warn "[DRY-RUN] Would remove only Netwatch-owned IPv4 firewall rules, ARP processes, and control state."
        return 0
    fi
    ensure_config_dir
    local pidfile ip
    shopt -s nullglob
    for pidfile in "$CONFIG_DIR"/arp_*.pid; do
        if [[ -z "$GATEWAY" ]]; then
            GATEWAY=$(ip -4 route show default 2>/dev/null | awk 'NR==1 {print $3}')
            if [[ -z "$GATEWAY" ]] || ! valid_ipv4 "$GATEWAY"; then
                warn "Cannot verify the current gateway; refusing to kill ARP process recorded in $pidfile."
                continue
            fi
        fi
        ip=$(basename "$pidfile" .pid)
        ip=${ip#arp_}
        ip=${ip//_/.}
        stop_arp "$pidfile" "$ip" "$GATEWAY"
    done
    shopt -u nullglob

    if iptables -S NETWATCH_BLOCK >/dev/null 2>&1; then
        chain_owned iptables NETWATCH_BLOCK NETWATCH-owner || die "Refusing reset: NETWATCH_BLOCK is not marked as Netwatch-owned."
        if [[ -f "$BLOCK_IP_FILE" ]]; then
            while IFS= read -r ip; do
                valid_ipv4 "$ip" || continue
                iptables -D NETWATCH_BLOCK -s "$ip" -j DROP >/dev/null 2>&1 || true
                iptables -D NETWATCH_BLOCK -d "$ip" -j DROP >/dev/null 2>&1 || true
            done < "$BLOCK_IP_FILE"
        fi
        if [[ -f "$BLOCK_FILE" ]]; then
            while IFS= read -r ip; do
                is_valid_mac "$ip" || continue
                iptables -D NETWATCH_BLOCK -m mac --mac-source "$ip" -j DROP >/dev/null 2>&1 || true
            done < "$BLOCK_FILE"
        fi
        if chain_only_marker iptables NETWATCH_BLOCK NETWATCH-owner; then
            iptables -D FORWARD -j NETWATCH_BLOCK >/dev/null 2>&1 || true
            iptables -D NETWATCH_BLOCK -m comment --comment NETWATCH-owner -j RETURN >/dev/null 2>&1 || true
            iptables -X NETWATCH_BLOCK >/dev/null 2>&1 || true
        else
            die "Reset left unexpected rules in NETWATCH_BLOCK; refusing to delete the chain."
        fi
    fi
    rm -f -- "$BLOCK_FILE" "$BLOCK_IP_FILE" "$THROTTLE_FILE"
    log "reset: Netwatch-owned IPv4 state cleared"
    ok "Netwatch-owned IPv4 control state reset."
}

help_cmd(){
    cat <<EOF
netwatch v$VERSION — Linux network monitor and controlled gateway operations

Usage:
  $SCRIPT_NAME [--dry-run] [--persistent] <command> [args]

Commands:
  scan [table|json|csv]     Discover devices on the detected IPv4 subnet
  monitor [seconds]         Refresh the scan periodically
  identify <ip|mac>         Run Nmap service/OS identification
  block <ip|mac>            Block a target on a Linux gateway
  unblock <ip|mac>          Remove a Netwatch-owned block
  list                      Show Netwatch control state
  export [csv|json]         Save scan output to the config directory
  reset                     Remove only Netwatch-owned IPv4 control state
  throttle <mac> <speed>    Unavailable in v$VERSION
  unthrottle <mac>          Unavailable in v$VERSION
  update                    Check for a newer version (no auto-update)
  help                      Show this help

Safety:
  - IPv4 control requires root and IPv4 forwarding.
  - The default gateway is never a valid block target.
  - Existing iptables chains are modified only when marked NETWATCH-owned.
  - --dry-run performs no firewall, QoS, ARP, or persistent-state changes.
  - Runtime state defaults to $CONFIG_DIR.
EOF
}

menu(){
    check_deps scan
    while :; do
        printf '\nNETWATCH v%s\n' "$VERSION"
        printf '%s\n' '1) Scan  2) Identify  3) Block  4) Unblock  5) List  6) Export  7) Update  8) Reset  Q) Quit'
        read -r -p 'Choice: ' choice || return 0
        case "${choice,,}" in
            1) detect_network; scan table ;;
            2) read -r -p 'IP/MAC: ' target; check_deps identify; identify "$target" ;;
            3) read -r -p 'IP/MAC: ' target; check_deps block; detect_network; block "$target" ;;
            4) read -r -p 'IP/MAC: ' target; check_deps unblock; detect_network; unblock "$target" ;;
            5) list ;;
            6) read -r -p 'Format [csv/json]: ' format; export_scan "${format:-csv}" ;;
            7) check_deps update; update_cmd ;;
            8) check_deps reset; reset_cmd ;;
            q) return 0 ;;
            *) warn 'Unknown option.' ;;
        esac
    done
}

cleanup(){ :; }

if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
    return 0
fi

args=()
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        --persistent) PERSISTENT=true ;;
        *) args+=("$arg") ;;
    esac
done
set -- "${args[@]}"
CMD=${1:-menu}
shift || true

case "$CMD" in
    menu) menu ;;
    scan) check_deps scan; detect_network; scan "${1:-table}" ;;
    monitor) check_deps monitor; detect_network; monitor "${1:-30}" ;;
    identify) check_deps identify; identify "${1:-}" ;;
    block) check_deps block; detect_network; block "${1:-}" ;;
    unblock) check_deps unblock; detect_network; unblock "${1:-}" ;;
    throttle) check_deps throttle; throttle "${1:-}" "${2:-}" ;;
    unthrottle) check_deps unthrottle; unthrottle "${1:-}" ;;
    list) list ;;
    export) export_scan "${1:-csv}" ;;
    reset) check_deps reset; reset_cmd ;;
    update) check_deps update; update_cmd ;;
    help|-h|--help) help_cmd ;;
    *) die "Unknown command: $CMD. Run '$SCRIPT_NAME help'." ;;
esac
