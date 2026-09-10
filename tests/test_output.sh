#!/usr/bin/env bash
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export NETWATCH_CONFIG="$TMP/config"
mkdir -p "$NETWATCH_CONFIG"
source "$ROOT/netwatch.sh"
detect_network(){ SUBNET=192.168.1.0/24; GATEWAY=192.168.1.1; IFACE=eth0; }
nmap(){ printf 'Host: 192.168.1.42 () Status: Up\n'; printf 'Host: 192.168.1.43 () Status: Up\n'; }
ip(){
    if [[ "$*" == 'neigh flush nud stale' ]]; then return 0; fi
    if [[ "$1" == neigh && "$2" == show ]]; then
        case "$*" in
            *192.168.1.42*) printf '192.168.1.42 dev eth0 lladdr aa:bb:cc:dd:ee:ff REACHABLE\n' ;;
            *192.168.1.43*) printf '192.168.1.43 dev eth0 lladdr 11:22:33:44:55:66 REACHABLE\n' ;;
        esac
    fi
}
getent(){ printf '%s\n' '192.168.1.42 router"foo,bar'; printf '%s\n' '192.168.1.43 host-two'; }
json=$(scan json 2>"$TMP/json.err")
python3 - "$json" <<'PY'
import json,sys
data=json.loads(sys.argv[1])
assert len(data)==2
assert data[0]['hostname']=='router"foo,bar'
PY
! grep -q '\[•\]' <<< "$json"
csv=$(scan csv 2>/dev/null)
python3 - "$csv" <<'PY'
import csv,io,sys
rows=list(csv.DictReader(io.StringIO(sys.argv[1])))
assert rows[0]['hostname']=='router"foo,bar'
assert rows[0]['mac']=='AA:BB:CC:DD:EE:FF'
PY
printf 'PASS JSON and CSV are machine-parseable\n'
