#!/usr/bin/env bash
# Monitoring continues; only automatic restarts are suppressed during handoff.
set -euo pipefail
if [[ "${1:-}" == --check-installed ]]; then
  grep -Fq /usr/local/bin/salvorias-rpc-h4031650-guard.sh /usr/local/bin/salvorias-rpc-watchdog.sh
  grep -Fq /usr/local/bin/salvorias-rpc-license-guard.sh /usr/local/bin/salvorias-rpc-h4031650-guard.sh
  exit
fi
marker=/var/lib/salvorias-rpc-watchdog/license-governance.pending.json
[[ -e "$marker" ]] || exit 0
height=$(jq -er '.height | numbers | select(. > 0 and floor == .)' "$marker")
hash=$(jq -er '.binary_sha256 | select(test("^[a-f0-9]{64}$"))' "$marker")
identity=$(jq -er '.validator_address | select(test("^[A-Fa-f0-9]{40}$"))' "$marker")
unit=$(jq -er '.unit | select(test("^salvorias-license-governance-h[0-9]+$"))' "$marker")
case "$(systemctl show "$unit" -p ActiveState --value)" in active|activating|reloading) exit 1 ;; esac
c=salvorias-rpc-node
actual=$(docker exec "$c" sh -lc 'sha256sum "$(command -v evmosd)"' | awk '{print $1}')
[[ "$actual" == "$hash" ]] || exit 1
info=$(docker exec "$c" curl -fsS --max-time 10 http://127.0.0.1:26657/abci_info)
jq -e --argjson height "$height" '.result.response.last_block_height | tonumber >= $height' <<<"$info" >/dev/null
status=$(docker exec "$c" curl -fsS --max-time 10 http://127.0.0.1:26657/status)
jq -e --arg identity "$identity" '.result.node_info.network == "salvorias_7282-1" and
  .result.validator_info.address == $identity and .result.sync_info.catching_up == false' <<<"$status" >/dev/null
rm -- "$marker"
echo 'License-governance read RPC identity, binary and committed state verified; recovery re-enabled.'
