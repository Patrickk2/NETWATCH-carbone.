#!/usr/bin/env bash
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$ROOT/netwatch.sh"
pass=0
fail=0
check(){
  local name=$1 expected=$2
  shift 2
  if "$@"; then actual=0; else actual=$?; fi
  if [[ "$expected" == "$actual" ]]; then printf 'PASS %s\n' "$name"; ((pass++)); else printf 'FAIL %s (expected %s got %s)\n' "$name" "$expected" "$actual"; ((fail++)); fi
}
check 'valid IPv4' 0 valid_ipv4 192.168.1.1
check 'valid IPv4 zero' 0 valid_ipv4 0.0.0.0
check 'reject 999.999.999.999' 1 valid_ipv4 999.999.999.999
check 'reject short IPv4' 1 valid_ipv4 1.2.3
check 'reject long IPv4' 1 valid_ipv4 1.2.3.4.5
check 'reject IPv4 suffix' 1 valid_ipv4 1.2.3.4x
check 'valid MAC uppercase' 0 is_valid_mac AA:BB:CC:DD:EE:FF
check 'valid MAC lowercase' 0 is_valid_mac aa:bb:cc:dd:ee:ff
check 'reject malformed MAC' 1 is_valid_mac AA:BB:CC:DD:EE
check 'reject MAC garbage' 1 is_valid_mac AA:BB:CC:DD:EE:GG
check 'valid speed' 0 is_valid_speed 10mbit
check 'invalid speed' 1 is_valid_speed 10
check '1.10 greater than 1.9' 0 version_compare 1.10 1.9
check '1.2 less than 1.3' 1 version_compare 1.2 1.3
check 'same version' 1 version_compare 1.2 1.2
check 'invalid version' 2 version_compare 1.x 1.2
printf '%d passed, %d failed\n' "$pass" "$fail"
((fail==0))
