#!/usr/bin/env bash
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
help=$(bash "$ROOT/netwatch.sh" help)
grep -q 'netwatch v1.3.1' <<< "$help"
grep -q 'Throttle is unavailable' <<< "$help"
grep -q 'reset' <<< "$help"
if bash "$ROOT/netwatch.sh" definitely-not-a-command >/dev/null 2>&1; then
    echo 'FAIL invalid command returned success'; exit 1
fi
bash "$ROOT/netwatch-ipv6.sh" help | grep -q 'netwatch-ipv6 v1.3.1'
bash "$ROOT/netwatch-router.sh" help | grep -q 'StrictHostKeyChecking=yes'
echo 'PASS CLI help and failure behavior'
