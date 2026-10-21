#!/usr/bin/env bash
set -euo pipefail
dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
c="${CONTAINER_NAME:?}"
rpc=http://134.199.216.166:26660
if [[ "$c" == salvorias-qa-* ]]; then rpc="${QA_TRUSTED_RPC:?}"; fi
url=https://github.com/BlainThomas/salvorias-validator-node/releases/download/legacy-text-h4031650
new=486e971ecf8321be52d5b34c568273b68e22b494ce1af3c91bb1d72e4ac15a83
python3 "$dir/late-text-check.py" --container "$c" --rpc "$rpc"
current=$(docker exec "$c" sh -lc 'sha256sum "$(command -v evmosd)"' | cut -d' ' -f1)
if [[ "$current" != "$new" ]]; then
  "$dir/upgrade-validator.sh" apply --late-text --harden-rpc \
    --trusted-rpc "$rpc" --upgrade-name salvorias-legacy-text-v1.2.1 \
    --upgrade-height 4031650 --minimum-gas-prices 1000000000SAVDR \
    --image salvorias-validator-security:1.2.1-legacy-text-rc1-amd64 \
    --image-tarball-url "$url/validator-image-linux-amd64.tar.gz" \
    --image-tarball-sha256 9d97f57c59b23c0a859209af8b75085bcd195d5d17568a6eaec5682d61643b4e \
    --binary-sha256 "$new"
fi
python3 "$dir/late-text-check.py" --container "$c" --rpc "$rpc" --require-new
pubkey=$(docker exec "$c" evmosd status --node tcp://127.0.0.1:26657 | jq -er '.validator_info.pub_key.value // .validator_info.pub_key.key')
docker exec "$c" evmosd query staking validators --page-limit 1000 --output json --node tcp://127.0.0.1:26657 |
  jq -e --arg key "$pubkey" '[.validators[] | select((.consensus_pubkey.key // .consensus_pubkey.value)==$key)] | select(length==1) | .[0] | {operator_address,status,jailed} | select(.jailed != true and .status=="BOND_STATUS_BONDED")'
echo 'LATE UPDATE VERIFIED: approved binary, canonical state, caught up, bonded and not jailed. Send this output to Blain before publishing the proposal.'
