#!/usr/bin/env bash
# Monitoring stays enabled. Fail closed if the controlled handoff is incomplete.
set -euo pipefail
if [[ "${1:-}" == --check-installed ]]; then
  grep -Fq '/usr/local/bin/salvorias-rpc-h4031650-guard.sh' /usr/local/bin/salvorias-rpc-watchdog.sh
  exit
fi
marker=/var/lib/salvorias-rpc-watchdog/upgrade-h4031650.pending
[[ -e "$marker" ]] || exit 0
systemctl is-active --quiet salvorias-legacy-h4031650 && exit 1
c=salvorias-rpc-node
hash=$(docker exec "$c" sh -c 'sha256sum "$(command -v evmosd)"' | awk '{print $1}')
[[ "$hash" == 486e971ecf8321be52d5b34c568273b68e22b494ce1af3c91bb1d72e4ac15a83 ]] || exit 1
info=$(docker exec "$c" curl -fsS --max-time 10 http://127.0.0.1:26657/abci_info)
jq -e '.result.response.last_block_height|tonumber>=4031650' <<< "$info" >/dev/null
status=$(docker exec "$c" curl -fsS --max-time 10 http://127.0.0.1:26657/status)
jq -e '.result.node_info.network=="salvorias_7282-1" and .result.validator_info.address=="3AEAFB6295C6F23400C2488CCC897C2E35E617D9" and .result.sync_info.catching_up==false' <<< "$status" >/dev/null
rm -- "$marker"
echo 'H4031650 read RPC identity and committed state verified; watchdog recovery re-enabled.'
