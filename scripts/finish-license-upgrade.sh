#!/usr/bin/env bash
# One-command completion: wait for verified catch-up, then unjail only if eligible.
# Never reset data/signing state, export a key, or repeat an ambiguous transaction.
set -euo pipefail
binary_hash="$1" height="$2"
c="${CONTAINER_NAME:?Explicit container required}"
[[ "$c" != salvorias-rpc-node ]] || exit 0
[[ "$binary_hash" =~ ^[a-f0-9]{64}$ && "$height" =~ ^[0-9]+$ ]] || exit 1
dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ready=false
for attempt in $(seq 1 180); do
  if "$dir/upgrade-validator.sh" verify --container "$c" --harden-rpc \
       --binary-sha256 "$binary_hash" --upgrade-height "$height"; then
    ready=true; break
  fi
  sleep 10
done
[[ "$ready" == true ]] || { echo 'Catch-up verification timed out. No unjail submitted; inspect node.' >&2; exit 1; }
pubkey="$(docker exec "$c" evmosd status | jq -er '.validator_info.pub_key.key // .validator_info.pub_key.value')"
valoper="$(docker exec "$c" evmosd query staking validators --page-limit 1000 --output json |
  jq -er --arg key "$pubkey" '[.validators[] | select((.consensus_pubkey.key // .consensus_pubkey.value) == $key) | .operator_address] | select(length == 1) | .[0]')"
python3 "$dir/post-upgrade-unjail.py" --container "$c" --binary-sha256 "$binary_hash" \
  --minimum-height "$height" --valoper "$valoper" --key-name "${OPERATOR_KEY_NAME:-validator}" --submit
