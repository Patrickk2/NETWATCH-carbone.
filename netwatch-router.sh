#!/usr/bin/env bash
# netwatch-router — vendor-neutral router integration bridge over SSH.

set -u
ROUTER_HOST="${NETWATCH_ROUTER_HOST:-}"
ROUTER_USER="${NETWATCH_ROUTER_USER:-}"
ROUTER_PORT="${NETWATCH_ROUTER_PORT:-22}"
ROUTER_KEY="${NETWATCH_ROUTER_KEY:-}"

err(){ printf '[x] %s\n' "$*" >&2; }
ok(){ printf '[✓] %s\n' "$*"; }
die(){ err "$*"; exit 1; }

usage(){
cat <<'EOF'
netwatch-router — generic SSH router integration bridge

Environment:
  NETWATCH_ROUTER_HOST   Router hostname or IP
  NETWATCH_ROUTER_USER   SSH username
  NETWATCH_ROUTER_PORT   SSH port, 1-65535 (default: 22)
  NETWATCH_ROUTER_KEY    Optional private-key path

Usage:
  netwatch-router.sh check
  netwatch-router.sh exec <router-command> [args...]
  netwatch-router.sh apply <local-script>

Security:
  SSH host-key verification is explicit and required.
  BatchMode is enabled; password prompts are not allowed.
  The bridge does not disable StrictHostKeyChecking or replace known_hosts.
  `exec` forwards administrator-supplied arguments to the remote SSH command;
  the remote SSH server may still interpret the resulting command remotely.
EOF
}

validate_identifier(){
    local value=$1 label=$2
    [[ -n "$value" ]] || die "$label is not set."
    [[ "$value" != -* ]] || die "$label must not begin with '-'."
    [[ "$value" =~ ^[A-Za-z0-9._:-]+$ ]] || die "$label contains unsupported characters."
}

validate_user(){
    [[ -n "$ROUTER_USER" ]] || die 'NETWATCH_ROUTER_USER is not set.'
    [[ "$ROUTER_USER" != -* ]] || die 'NETWATCH_ROUTER_USER must not begin with -.'
    [[ "$ROUTER_USER" =~ ^[A-Za-z0-9._-]+$ ]] || die 'NETWATCH_ROUTER_USER contains unsupported characters.'
}

validate_port(){
    [[ "$ROUTER_PORT" =~ ^[0-9]+$ ]] || die 'NETWATCH_ROUTER_PORT must be numeric.'
    ((10#$ROUTER_PORT >= 1 && 10#$ROUTER_PORT <= 65535)) ||
        die 'NETWATCH_ROUTER_PORT must be between 1 and 65535.'
}

validate_key(){
    [[ -n "$ROUTER_KEY" ]] || return 0
    [[ -f "$ROUTER_KEY" ]] || die "SSH key not found: $ROUTER_KEY"
    local mode owner uid
    mode=$(stat -c '%a' -- "$ROUTER_KEY" 2>/dev/null) || die "Cannot inspect SSH key permissions."
    owner=$(stat -c '%u' -- "$ROUTER_KEY" 2>/dev/null) || die "Cannot inspect SSH key ownership."
    uid=${EUID:-1}
    [[ "$owner" == "$uid" || "$uid" == 0 ]] || die 'SSH private key must be owned by the invoking user (or root).'
    ((10#$mode % 100 < 1)) || die 'SSH private key must not be group/world accessible.'
}

require_config(){
    validate_identifier "$ROUTER_HOST" 'NETWATCH_ROUTER_HOST'
    validate_user
    validate_port
    validate_key
    command -v ssh >/dev/null 2>&1 || die 'ssh is required.'
}

build_ssh_base(){
    ssh_base=(ssh
        -o BatchMode=yes
        -o StrictHostKeyChecking=yes
        -o ConnectTimeout=8
        -o ServerAliveInterval=5
        -o ServerAliveCountMax=2
        -p "$ROUTER_PORT")
    [[ -n "$ROUTER_KEY" ]] && ssh_base+=( -i "$ROUTER_KEY" )
}

check(){
    require_config
    build_ssh_base
    "${ssh_base[@]}" "${ROUTER_USER}@${ROUTER_HOST}" 'printf router-connection-ok' >/dev/null ||
        die 'Router SSH connection failed. Verify network access and known_hosts.'
    ok 'Router SSH connection is available.'
}

exec_remote(){
    require_config
    [[ $# -gt 0 ]] || die 'Usage: netwatch-router.sh exec <router-command> [args...]'
    build_ssh_base
    "${ssh_base[@]}" "${ROUTER_USER}@${ROUTER_HOST}" "$@"
}

apply(){
    require_config
    local script=${1:-}
    [[ -n "$script" ]] || die 'Usage: netwatch-router.sh apply <local-script>'
    [[ -f "$script" ]] || die "Script not found: $script"
    [[ -r "$script" ]] || die "Script is not readable: $script"
    build_ssh_base
    "${ssh_base[@]}" "${ROUTER_USER}@${ROUTER_HOST}" 'sh -s' < "$script"
}

if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
    return 0
fi

case "${1:-help}" in
    check) check ;;
    exec) shift; exec_remote "$@" ;;
    apply) shift; apply "${1:-}" ;;
    help|-h|--help) usage ;;
    *) die "Unknown command: $1. Run '$0 help'." ;;
esac
