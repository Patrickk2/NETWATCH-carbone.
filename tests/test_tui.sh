#!/usr/bin/env bash
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

python3 -m py_compile "$ROOT/ui/netwatch_tui.py" || { echo 'FAIL TUI Python syntax'; exit 1; }
grep -q 'NETWATCH' "$ROOT/ui/netwatch_tui.py" || { echo 'FAIL TUI identity'; exit 1; }
grep -q 'NETWATCH-owned' "$ROOT/ui/netwatch_tui.py" || { echo 'FAIL ownership wording'; exit 1; }
grep -q 'Enter Confirm' "$ROOT/ui/netwatch_tui.py" || { echo 'FAIL confirmation UX'; exit 1; }
grep -q 'NO DEVICES DISCOVERED' "$ROOT/ui/netwatch_tui.py" || { echo 'FAIL empty state'; exit 1; }
grep -q 'StrictHostKeyChecking=yes' "$ROOT/netwatch-router.sh" || { echo 'FAIL router verification policy'; exit 1; }
echo 'PASS TUI syntax and UX regression checks'
