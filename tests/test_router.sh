#!/usr/bin/env bash
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

out=$(NETWATCH_ROUTER_HOST=router.example NETWATCH_ROUTER_USER=admin NETWATCH_ROUTER_PORT=2222 bash -c '
  source "$1"
  ssh(){ printf "%s\n" "$*"; }
  export NETWATCH_ROUTER_HOST=router.example NETWATCH_ROUTER_USER=admin NETWATCH_ROUTER_PORT=2222
  exec_remote show ipv6 interface
' _ "$ROOT/netwatch-router.sh")

grep -q -- '-p 2222' <<< "$out" || { echo 'FAIL router port forwarding'; exit 1; }
grep -q -- 'admin@router.example show ipv6 interface' <<< "$out" || { echo 'FAIL router command forwarding'; exit 1; }

if NETWATCH_ROUTER_HOST='bad host' NETWATCH_ROUTER_USER=admin NETWATCH_ROUTER_PORT=22 \
    bash -c 'source "$1"; require_config' _ "$ROOT/netwatch-router.sh" >/dev/null 2>&1; then
    echo 'FAIL host validation'; exit 1
fi

if NETWATCH_ROUTER_HOST=router.example NETWATCH_ROUTER_USER=admin NETWATCH_ROUTER_PORT=65536 \
    bash -c 'source "$1"; require_config' _ "$ROOT/netwatch-router.sh" >/dev/null 2>&1; then
    echo 'FAIL port range validation'; exit 1
fi

echo 'PASS router validation and argument forwarding'
