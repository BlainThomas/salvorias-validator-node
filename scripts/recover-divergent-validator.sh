#!/usr/bin/env bash
set -Eeuo pipefail

# Recover a validator that is connected to canonical peers but is halted by a
# wrong Block.Header.AppHash error. The chain/application databases are rebuilt
# with state sync; validator identity and signing state are preserved.

readonly CONTAINER_NAME="${CONTAINER_NAME:-salvorias-validator}"
readonly HOME_DIR="/home/evmos/.evmosd"
readonly CHAIN_ID="salvorias_7282-1"
readonly TRUSTED_RPC="http://134.199.216.166:26660"
readonly CURRENT_IMAGE="ghcr.io/nodesolutionsai/salvorias-validator-node:policy-v1.1.3"
readonly RECOVERY_PEERS="bc9decb51c24982322c756b7c9a0c837ed7a7216@134.199.216.166:26656,2dc40ecb6939882984604f6a1158ab0fbc7bca92@45.32.198.24:26656"
readonly PUBLIC_REF="agent/divergent-validator-recovery"
readonly PUBLIC_RAW_BASE="https://raw.githubusercontent.com/BlainThomas/salvorias-validator-node/$PUBLIC_REF"
readonly UPGRADE_SCRIPT_URL="$PUBLIC_RAW_BASE/scripts/upgrade-validator.sh"
readonly STATE_SYNC_SCRIPT_URL="$PUBLIC_RAW_BASE/scripts/reset-state-sync.sh"
readonly RELEASE_URL="https://github.com/BlainThomas/salvorias-validator-node/releases/download/v0.2.3/salvorias-validator-node-policy-v1.1.3-linux-amd64.tar.gz"
readonly RELEASE_SHA256="d7de5bd3c0f3499b71a66481802f84ddd2776c9cca94f804fb25b72459e0d2f0"
readonly BINARY_SHA256="5c350a99df5687ee18b98c26661afe1e941dda4cbf9ac0980d417b81880ed2e8"
readonly BACKUP_ROOT="/var/backups/salvorias-validator"

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

for command_name in docker curl jq sha256sum cp; do
  require_command "$command_name"
done

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  echo "Run this recovery as root (or pipe it to sudo bash)." >&2
  exit 1
fi

docker container inspect "$CONTAINER_NAME" >/dev/null 2>&1 || {
  echo "Container not found: $CONTAINER_NAME" >&2
  exit 1
}

canonical_status="$(curl -fsS --max-time 15 "$TRUSTED_RPC/status")"
canonical_chain="$(jq -r '.result.node_info.network // empty' <<<"$canonical_status")"
canonical_height="$(jq -r '.result.sync_info.latest_block_height // "0"' <<<"$canonical_status")"
if [[ "$canonical_chain" != "$CHAIN_ID" || ! "$canonical_height" =~ ^[0-9]+$ || "$canonical_height" -lt 2009500 ]]; then
  echo "Trusted RPC is not ready for recovery: chain=$canonical_chain height=$canonical_height" >&2
  exit 1
fi

mount_json="$(docker inspect "$CONTAINER_NAME" | jq -c '.[0].Mounts[] | select(.Destination == "/home/evmos/.evmosd")')"
mount_count="$(wc -l <<<"$mount_json" | tr -d ' ')"
if [[ "$mount_count" -ne 1 ]]; then
  echo "Expected exactly one persistent validator-home mount." >&2
  exit 1
fi

node_home_source="$(jq -r '.Source // empty' <<<"$mount_json")"
node_home_mount="$(jq -r '.Name // .Source // empty' <<<"$mount_json")"
[[ -n "$node_home_source" && -n "$node_home_mount" ]] || {
  echo "Could not identify the validator data mount." >&2
  exit 1
}

privkey_file="$node_home_source/config/priv_validator_key.json"
nodekey_file="$node_home_source/config/node_key.json"
signing_file="$node_home_source/data/priv_validator_state.json"
for protected_file in "$privkey_file" "$nodekey_file" "$signing_file"; do
  [[ -s "$protected_file" ]] || {
    echo "Missing protected validator file: $protected_file" >&2
    exit 1
  }
done

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
backup_dir="$BACKUP_ROOT/$timestamp-divergence-recovery"
install -d -m 0700 "$backup_dir"
cp -a "$privkey_file" "$backup_dir/priv_validator_key.json"
cp -a "$nodekey_file" "$backup_dir/node_key.json"
cp -a "$signing_file" "$backup_dir/priv_validator_state.json"

privkey_hash="$(sha256sum "$privkey_file" | cut -d' ' -f1)"
nodekey_hash="$(sha256sum "$nodekey_file" | cut -d' ' -f1)"
signing_hash="$(sha256sum "$signing_file" | cut -d' ' -f1)"
cat >"$backup_dir/hashes.txt" <<EOF
$privkey_hash  priv_validator_key.json
$nodekey_hash  node_key.json
$signing_hash  priv_validator_state.json
EOF
chmod 0600 "$backup_dir"/*

watchdog_active=false
if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet salvorias-validator-watchdog.timer; then
  watchdog_active=true
  systemctl stop salvorias-validator-watchdog.timer
fi

recovery_complete=false
finish() {
  if [[ "$watchdog_active" == "true" && "$recovery_complete" == "true" ]]; then
    systemctl start salvorias-validator-watchdog.timer 2>/dev/null || true
  fi
  if [[ "$recovery_complete" != "true" ]]; then
    docker stop "$CONTAINER_NAME" >/dev/null 2>&1 || true
    echo "Recovery stopped safely. Validator backup: $backup_dir" >&2
    echo "Leave the validator stopped and contact the operator team with the error above." >&2
  fi
}
trap finish EXIT

docker stop "$CONTAINER_NAME" >/dev/null 2>&1 || true

installed_image="$(docker inspect -f '{{.Config.Image}}' "$CONTAINER_NAME")"
installed_binary="$(docker run --rm --entrypoint sh "$installed_image" -lc 'sha256sum "$(command -v evmosd)" | cut -d" " -f1')"
if [[ "$installed_image" == "$CURRENT_IMAGE" && "${installed_binary,,}" == "${BINARY_SHA256,,}" ]]; then
  echo "Current policy-v1.1.3 image and binary already verified; skipping the completed upgrade."
else
  curl -fsSL "$UPGRADE_SCRIPT_URL" -o /tmp/salvorias-upgrade-validator.sh
  chmod 0700 /tmp/salvorias-upgrade-validator.sh
  /tmp/salvorias-upgrade-validator.sh apply \
    --post-hardfork-recovery \
    --trusted-rpc "$TRUSTED_RPC" \
    --upgrade-name salvorias-fee-exemption-v1.1.3 \
    --upgrade-height 2009500 \
    --minimum-gas-prices 1000000000SAVDR \
    --image "$CURRENT_IMAGE" \
    --image-tarball-url "$RELEASE_URL" \
    --image-tarball-sha256 "$RELEASE_SHA256" \
    --binary-sha256 "$BINARY_SHA256"
fi

curl -fsSL "$STATE_SYNC_SCRIPT_URL" -o /tmp/salvorias-reset-state-sync.sh
chmod 0700 /tmp/salvorias-reset-state-sync.sh
env \
  STATE_SYNC_RPC="$TRUSTED_RPC" \
  PERSISTENT_PEERS="$RECOVERY_PEERS" \
  CONTAINER_NAME="$CONTAINER_NAME" \
  VOLUME_NAME="$node_home_mount" \
  IMAGE="$CURRENT_IMAGE" \
  /tmp/salvorias-reset-state-sync.sh

# reset-state-sync intentionally initializes a new signer state for fresh
# nodes. A recovering validator must retain its original last-signed height.
docker stop "$CONTAINER_NAME" >/dev/null
cp -a "$backup_dir/priv_validator_state.json" "$signing_file"

[[ "$(sha256sum "$privkey_file" | cut -d' ' -f1)" == "$privkey_hash" ]] || {
  echo "Validator consensus key changed during recovery." >&2
  exit 1
}
[[ "$(sha256sum "$nodekey_file" | cut -d' ' -f1)" == "$nodekey_hash" ]] || {
  echo "Validator node key changed during recovery." >&2
  exit 1
}
[[ "$(sha256sum "$signing_file" | cut -d' ' -f1)" == "$signing_hash" ]] || {
  echo "Validator signing state was not restored exactly." >&2
  exit 1
}

docker start "$CONTAINER_NAME" >/dev/null
recovery_complete=true

echo
echo "Salvorias validator recovery started successfully."
echo "  Image:            $CURRENT_IMAGE"
echo "  Canonical height: $canonical_height"
echo "  Safety backup:    $backup_dir"
echo "  Keys preserved:   yes"
echo "  Signing state:    preserved"
echo
echo "Monitor with:"
echo "  watch -n 10 \"docker exec $CONTAINER_NAME curl -fsS http://127.0.0.1:26657/status | jq '.result.sync_info | {latest_block_height, latest_block_time, catching_up}'\""
echo
echo "Do not unjail until catching_up is false."
