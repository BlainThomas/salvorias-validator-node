#!/usr/bin/env bash
set -euo pipefail

# Safely replaces a Salvorias validator container while preserving its mounted
# node home. The old container is retained, stopped, for pre-migration rollback.

MODE="${1:-}"
if [[ -n "$MODE" ]]; then shift; fi

IMAGE="${UPGRADE_IMAGE:-}"
BINARY_SHA256="${UPGRADE_BINARY_SHA256:-}"
IMAGE_TARBALL_URL="${UPGRADE_IMAGE_TARBALL_URL:-}"
IMAGE_TARBALL_SHA256="${UPGRADE_IMAGE_TARBALL_SHA256:-}"
UPGRADE_HEIGHT="${UPGRADE_HEIGHT:-}"
UPGRADE_NAME="${UPGRADE_NAME:-}"
MINIMUM_GAS_PRICES="${MINIMUM_GAS_PRICES:-}"
COORDINATED_HARDFORK="${COORDINATED_HARDFORK:-false}"
POST_HARDFORK_RECOVERY="${POST_HARDFORK_RECOVERY:-false}"
TRUSTED_RPC="${TRUSTED_RPC:-http://134.199.216.166:26660}"
CONTAINER_NAME="${CONTAINER_NAME:-}"
BACKUP_ROOT="${BACKUP_ROOT:-/var/backups/salvorias-validator}"
HOME_DIR="/home/evmos/.evmosd"
CHAIN_ID="${CHAIN_ID:-salvorias_7282-1}"
START_TIMEOUT="${START_TIMEOUT:-120}"

usage() {
  cat <<'EOF'
Usage:
  sudo ./scripts/upgrade-validator.sh preflight --image IMAGE@sha256:DIGEST --binary-sha256 SHA256 [--container NAME]
  sudo ./scripts/upgrade-validator.sh apply     --upgrade-name NAME --upgrade-height HEIGHT --minimum-gas-prices PRICE --image IMAGE@sha256:DIGEST --binary-sha256 SHA256 [--container NAME]
  sudo ./scripts/upgrade-validator.sh apply     --coordinated-hardfork --upgrade-name NAME --upgrade-height HEIGHT --minimum-gas-prices PRICE --image IMAGE_TAG --image-tarball-url URL --image-tarball-sha256 SHA256 --binary-sha256 SHA256
  sudo ./scripts/upgrade-validator.sh apply     --post-hardfork-recovery --trusted-rpc URL --upgrade-name NAME --upgrade-height HEIGHT --minimum-gas-prices PRICE --image IMAGE_TAG --image-tarball-url URL --image-tarball-sha256 SHA256 --binary-sha256 SHA256
  sudo ./scripts/upgrade-validator.sh preflight --image IMAGE_TAG --image-tarball-url URL --image-tarball-sha256 SHA256 --binary-sha256 SHA256
  sudo ./scripts/upgrade-validator.sh apply     --upgrade-name NAME --upgrade-height HEIGHT --minimum-gas-prices PRICE --image IMAGE_TAG --image-tarball-url URL --image-tarball-sha256 SHA256 --binary-sha256 SHA256
  sudo ./scripts/upgrade-validator.sh verify                                          [--container NAME]

Use either a registry image pinned by digest or a public release tarball pinned
by SHA-256. Preflight verifies the image and backs up validator keys,
configuration, and signing state without stopping the node. Apply repeats that
backup after stopping the old container, retains the old container under a
timestamped name, starts the new image against the same persistent volume, and
automatically rolls back if identity/startup checks fail.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --image) IMAGE="$2"; shift 2 ;;
    --binary-sha256) BINARY_SHA256="$2"; shift 2 ;;
    --image-tarball-url) IMAGE_TARBALL_URL="$2"; shift 2 ;;
    --image-tarball-sha256) IMAGE_TARBALL_SHA256="$2"; shift 2 ;;
    --upgrade-height) UPGRADE_HEIGHT="$2"; shift 2 ;;
    --upgrade-name) UPGRADE_NAME="$2"; shift 2 ;;
    --minimum-gas-prices) MINIMUM_GAS_PRICES="$2"; shift 2 ;;
    --coordinated-hardfork) COORDINATED_HARDFORK=true; shift ;;
    --post-hardfork-recovery) POST_HARDFORK_RECOVERY=true; shift ;;
    --trusted-rpc) TRUSTED_RPC="$2"; shift 2 ;;
    --container) CONTAINER_NAME="$2"; shift 2 ;;
    --backup-root) BACKUP_ROOT="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done

if [[ "$MODE" != "preflight" && "$MODE" != "apply" && "$MODE" != "verify" ]]; then
  usage
  exit 1
fi

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run this script as root or with sudo." >&2
  exit 1
fi

for command in curl docker jq sha256sum tar; do
  command -v "$command" >/dev/null 2>&1 || { echo "Missing required command: $command" >&2; exit 1; }
done

detect_container() {
  if [[ -n "$CONTAINER_NAME" ]]; then return; fi
  for candidate in salvorias-validator salvorias-droplet; do
    if docker container inspect "$candidate" >/dev/null 2>&1; then
      CONTAINER_NAME="$candidate"
      return
    fi
  done

  mapfile -t candidates < <(
    docker ps --format '{{.Names}}' | while read -r candidate; do
      docker exec "$candidate" sh -lc 'command -v evmosd >/dev/null 2>&1' 2>/dev/null && echo "$candidate"
    done
  )
  if [[ "${#candidates[@]}" -ne 1 ]]; then
    echo "Could not uniquely detect the validator container; use --container NAME." >&2
    exit 1
  fi
  CONTAINER_NAME="${candidates[0]}"
}

detect_container
docker container inspect "$CONTAINER_NAME" >/dev/null

container_status() {
  docker exec "$CONTAINER_NAME" evmosd status 2>/dev/null
}

container_file_hash() {
  local path="$1"
  docker exec "$CONTAINER_NAME" sh -lc "test -f '$path' && sha256sum '$path' | cut -d' ' -f1 || true" 2>/dev/null
}

read_identity() {
  local status
  status="$(container_status)"
  [[ -n "$status" ]] || return 1
  STATUS_JSON="$status"
  NETWORK="$(jq -r '.node_info.network // empty' <<<"$status")"
  HEIGHT="$(jq -r '.sync_info.latest_block_height // "0"' <<<"$status")"
  VALIDATOR_ADDRESS="$(jq -r '.validator_info.address // empty' <<<"$status")"
  CATCHING_UP="$(jq -r 'if .sync_info.catching_up == null then true else .sync_info.catching_up end' <<<"$status")"
  BLOCK_TIME="$(jq -r '.sync_info.latest_block_time // empty' <<<"$status")"
  PRIVKEY_HASH="$(container_file_hash "$HOME_DIR/config/priv_validator_key.json")"
  NODEKEY_HASH="$(container_file_hash "$HOME_DIR/config/node_key.json")"
  SIGNING_STATE_HASH="$(container_file_hash "$HOME_DIR/data/priv_validator_state.json")"

  [[ "$NETWORK" == "$CHAIN_ID" ]] || { echo "Wrong chain: $NETWORK (expected $CHAIN_ID)" >&2; return 1; }
  [[ -n "$VALIDATOR_ADDRESS" && -n "$PRIVKEY_HASH" && -n "$NODEKEY_HASH" ]] || {
    echo "Could not read validator identity or key hashes." >&2
    return 1
  }
}

read_identity_offline() {
  local key_file="$NODE_HOME_MOUNT_SOURCE/config/priv_validator_key.json"
  local node_key_file="$NODE_HOME_MOUNT_SOURCE/config/node_key.json"
  local genesis_file="$NODE_HOME_MOUNT_SOURCE/config/genesis.json"
  local signing_file="$NODE_HOME_MOUNT_SOURCE/data/priv_validator_state.json"

  STATUS_JSON='{}'
  NETWORK="$(jq -r '.chain_id // empty' "$genesis_file")"
  HEIGHT="$(jq -r '.height // "0"' "$signing_file")"
  VALIDATOR_ADDRESS="$(jq -r '.address // empty' "$key_file")"
  CATCHING_UP="unknown (old binary halted)"
  BLOCK_TIME=""
  PRIVKEY_HASH="$(sha256sum "$key_file" | cut -d' ' -f1)"
  NODEKEY_HASH="$(sha256sum "$node_key_file" | cut -d' ' -f1)"
  SIGNING_STATE_HASH="$(sha256sum "$signing_file" | cut -d' ' -f1)"

  [[ "$NETWORK" == "$CHAIN_ID" ]] || { echo "Wrong offline chain: $NETWORK (expected $CHAIN_ID)" >&2; return 1; }
  [[ "$HEIGHT" =~ ^[0-9]+$ && -n "$VALIDATOR_ADDRESS" && -n "$PRIVKEY_HASH" && -n "$NODEKEY_HASH" ]] || {
    echo "Could not read offline validator height, identity, or key hashes." >&2
    return 1
  }
}

validate_halt_plan() {
  local info_file="$NODE_HOME_MOUNT_SOURCE/data/upgrade-info.json"
  [[ -f "$info_file" ]] || { echo "Missing on-disk upgrade plan: $info_file" >&2; return 1; }
  jq -e --arg name "$UPGRADE_NAME" --argjson height "$UPGRADE_HEIGHT" '
    .name == $name and (.height | tonumber) == $height
  ' "$info_file" >/dev/null || {
    echo "On-disk upgrade plan does not match $UPGRADE_NAME at height $UPGRADE_HEIGHT." >&2
    return 1
  }
}

node_home_mount() {
  docker inspect "$CONTAINER_NAME" | jq -r --arg home "$HOME_DIR" '
    .[0].Mounts[] | select(.Destination == $home) |
    [.Type, (.Name // ""), .Source, .Destination, (.RW|tostring), (.Mode // "")] | join("|")
  '
}

validate_mount() {
  local rows
  rows="$(node_home_mount)"
  if [[ "$(wc -l <<<"$rows" | tr -d ' ')" -ne 1 ]]; then
    echo "Expected exactly one persistent mount at $HOME_DIR." >&2
    return 1
  fi
  local type name source destination rw mode
  IFS='|' read -r type name source destination rw mode <<<"$rows"
  if [[ "$rw" != "true" || ( "$type" != "volume" && "$type" != "bind" ) ]]; then
    echo "Node home must be a writable Docker volume or bind mount." >&2
    return 1
  fi
  NODE_HOME_MOUNT_TYPE="$type"
  NODE_HOME_MOUNT_NAME="$name"
  NODE_HOME_MOUNT_SOURCE="$source"
}

backup_node() {
  local phase="$1" timestamp dir archive path
  local -a paths
  timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
  dir="$BACKUP_ROOT/$timestamp-$phase"
  archive="validator-safety-backup.tgz"
  install -d -m 0700 "$dir"

  docker inspect "$CONTAINER_NAME" > "$dir/container-inspect.json"
  printf '%s\n' "$STATUS_JSON" > "$dir/status.json"
  cat > "$dir/identity.env" <<EOF
CONTAINER_NAME=$CONTAINER_NAME
NETWORK=$NETWORK
HEIGHT=$HEIGHT
VALIDATOR_ADDRESS=$VALIDATOR_ADDRESS
PRIVKEY_HASH=$PRIVKEY_HASH
NODEKEY_HASH=$NODEKEY_HASH
SIGNING_STATE_HASH=$SIGNING_STATE_HASH
NODE_HOME_MOUNT_TYPE=$NODE_HOME_MOUNT_TYPE
NODE_HOME_MOUNT_NAME=$NODE_HOME_MOUNT_NAME
NODE_HOME_MOUNT_SOURCE=$NODE_HOME_MOUNT_SOURCE
EOF

  paths=()
  for path in \
    config/priv_validator_key.json config/node_key.json config/genesis.json \
    config/config.toml config/app.toml config/client.toml \
    data/priv_validator_state.json keyring-test; do
    [[ ! -e "$NODE_HOME_MOUNT_SOURCE/$path" ]] || paths+=("$path")
  done
  [[ "${#paths[@]}" -gt 0 ]] || { echo "No validator safety files found to back up." >&2; return 1; }
  tar -C "$NODE_HOME_MOUNT_SOURCE" -czf "$dir/$archive" "${paths[@]}"
  sha256sum "$dir/$archive" > "$dir/$archive.sha256"
  tar -tzf "$dir/$archive" >/dev/null
  chmod 0600 "$dir"/*
  ln -sfn "$dir" "$BACKUP_ROOT/latest"
  BACKUP_DIR="$dir"
  echo "Safety backup: $dir"
}

verify_upgrade_image() {
  if [[ -z "$IMAGE" || -z "$BINARY_SHA256" ]]; then
    echo "--image and --binary-sha256 are required for $MODE." >&2
    exit 1
  fi
  if [[ ! "$BINARY_SHA256" =~ ^[0-9a-fA-F]{64}$ ]]; then
    echo "Invalid --binary-sha256 value." >&2
    exit 1
  fi

  if [[ -n "$IMAGE_TARBALL_URL" || -n "$IMAGE_TARBALL_SHA256" ]]; then
    if [[ -z "$IMAGE_TARBALL_URL" || ! "$IMAGE_TARBALL_SHA256" =~ ^[0-9a-fA-F]{64}$ ]]; then
      echo "Tarball upgrades require both --image-tarball-url and a valid --image-tarball-sha256." >&2
      exit 1
    fi
    local archive actual_archive
    archive="$(mktemp -t salvorias-validator-upgrade.XXXXXX.tar.gz)"
    curl -fL --retry 3 --retry-delay 2 -o "$archive" "$IMAGE_TARBALL_URL"
    actual_archive="$(sha256sum "$archive" | cut -d' ' -f1)"
    if [[ "${actual_archive,,}" != "${IMAGE_TARBALL_SHA256,,}" ]]; then
      rm -f "$archive"
      echo "Upgrade image tarball checksum mismatch: expected $IMAGE_TARBALL_SHA256, got $actual_archive" >&2
      exit 1
    fi
    docker load -i "$archive" >/dev/null
    rm -f "$archive"
    docker image inspect "$IMAGE" >/dev/null 2>&1 || {
      echo "Verified tarball did not contain the expected image tag: $IMAGE" >&2
      exit 1
    }
  else
    if [[ "$IMAGE" != *@sha256:* ]]; then
      echo "Registry upgrades must use an immutable IMAGE@sha256:DIGEST reference." >&2
      exit 1
    fi
    docker pull "$IMAGE"
  fi

  local actual
  actual="$(docker run --rm --entrypoint sh "$IMAGE" -lc 'sha256sum "$(command -v evmosd)" | cut -d" " -f1')"
  if [[ "${actual,,}" != "${BINARY_SHA256,,}" ]]; then
    echo "Upgrade binary checksum mismatch: expected $BINARY_SHA256, got $actual" >&2
    exit 1
  fi
  echo "Upgrade image and binary checksum verified."
}

print_preflight() {
  local current_image current_binary
  current_image="$(docker inspect -f '{{.Config.Image}}' "$CONTAINER_NAME")"
  if [[ "$LIVE_STATUS_AVAILABLE" == "true" ]]; then
    current_binary="$(docker exec "$CONTAINER_NAME" sh -lc 'sha256sum "$(command -v evmosd)" | cut -d" " -f1')"
  else
    current_binary="$(docker run --rm --entrypoint sh "$current_image" -lc 'sha256sum "$(command -v evmosd)" | cut -d" " -f1')"
  fi
  echo "Preflight passed"
  echo "  Container:         $CONTAINER_NAME"
  echo "  Current image:     $current_image"
  echo "  Current binary:    $current_binary"
  echo "  Upgrade image:     $IMAGE"
  echo "  Upgrade binary:    $BINARY_SHA256"
  echo "  Chain:             $NETWORK"
  echo "  Height:            $HEIGHT"
  echo "  Catching up:       $CATCHING_UP"
  echo "  Validator address: $VALIDATOR_ADDRESS"
  echo "  Node home:         $NODE_HOME_MOUNT_TYPE:$NODE_HOME_MOUNT_SOURCE"
}

wait_for_rpc() {
  local deadline=$((SECONDS + START_TIMEOUT))
  while (( SECONDS < deadline )); do
    if docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null | grep -qx true &&
       container_status >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  return 1
}

restore_old_container() {
  local old_name="$1"
  echo "New container did not pass validation; restoring $old_name." >&2
  docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
  docker rename "$old_name" "$CONTAINER_NAME"
  docker start "$CONTAINER_NAME" >/dev/null
  if [[ "${watchdog_was_active:-false}" == "true" ]] && command -v systemctl >/dev/null 2>&1; then
    systemctl start salvorias-validator-watchdog.timer >/dev/null 2>&1 || true
  fi
}

start_replacement() {
  local inspect_file="$1"
  local -a args cmd envs mounts ports logs
  local restart network user
  restart="$(jq -r '.[0].HostConfig.RestartPolicy.Name // "no"' "$inspect_file")"
  network="$(jq -r '.[0].HostConfig.NetworkMode // "default"' "$inspect_file")"
  user="$(jq -r '.[0].Config.User // empty' "$inspect_file")"

  args=(docker run -d --name "$CONTAINER_NAME" --restart "$restart" --network "$network")
  [[ -z "$user" ]] || args+=(--user "$user")

  mapfile -t envs < <(jq -r '.[0].Config.Env[]?' "$inspect_file")
  for item in "${envs[@]}"; do args+=(--env "$item"); done

  mapfile -t mounts < <(jq -r '.[0].Mounts[] | [.Type, (.Name // ""), .Source, .Destination, (.Mode // "")] | join("|")' "$inspect_file")
  for item in "${mounts[@]}"; do
    local type name source destination mode spec
    IFS='|' read -r type name source destination mode <<<"$item"
    if [[ "$type" == "volume" ]]; then source="$name"; fi
    [[ "$type" == "volume" || "$type" == "bind" ]] || { echo "Unsupported mount type: $type" >&2; return 1; }
    spec="$source:$destination"
    [[ -z "$mode" ]] || spec="$spec:$mode"
    args+=(--volume "$spec")
  done

  mapfile -t ports < <(jq -r '.[0].HostConfig.PortBindings // {} | to_entries[] | .key as $port | .value[]? | [$port, (.HostIp // ""), .HostPort] | join("|")' "$inspect_file")
  for item in "${ports[@]}"; do
    local port host_ip host_port spec
    IFS='|' read -r port host_ip host_port <<<"$item"
    spec="$host_port:$port"
    [[ -z "$host_ip" ]] || spec="$host_ip:$spec"
    args+=(--publish "$spec")
  done

  local log_driver
  log_driver="$(jq -r '.[0].HostConfig.LogConfig.Type // empty' "$inspect_file")"
  [[ -z "$log_driver" ]] || args+=(--log-driver "$log_driver")
  mapfile -t logs < <(jq -r '.[0].HostConfig.LogConfig.Config // {} | to_entries[] | "\(.key)=\(.value)"' "$inspect_file")
  for item in "${logs[@]}"; do args+=(--log-opt "$item"); done

  mapfile -t cmd < <(jq -r '.[0].Config.Cmd[]?' "$inspect_file")
  if [[ -n "$MINIMUM_GAS_PRICES" ]]; then
    local found_minimum_gas_prices=false index
    for ((index=0; index<${#cmd[@]}; index++)); do
      if [[ "${cmd[$index]}" == "--minimum-gas-prices" ]]; then
        if (( index + 1 >= ${#cmd[@]} )); then
          echo "Existing command has --minimum-gas-prices without a value." >&2
          return 1
        fi
        cmd[$((index + 1))]="$MINIMUM_GAS_PRICES"
        found_minimum_gas_prices=true
        break
      fi
      if [[ "${cmd[$index]}" == --minimum-gas-prices=* ]]; then
        cmd[$index]="--minimum-gas-prices=$MINIMUM_GAS_PRICES"
        found_minimum_gas_prices=true
        break
      fi
    done
    if [[ "$found_minimum_gas_prices" != "true" ]]; then
      cmd+=(--minimum-gas-prices "$MINIMUM_GAS_PRICES")
    fi
  fi
  "${args[@]}" "$IMAGE" "${cmd[@]}" >/dev/null
}

LIVE_STATUS_AVAILABLE=true
if read_identity; then
  validate_mount
else
  if [[ "$MODE" != "apply" ]]; then
    echo "Validator RPC is unavailable; live status is required for $MODE." >&2
    exit 1
  fi
  LIVE_STATUS_AVAILABLE=false
  validate_mount
  read_identity_offline
fi

if [[ "$MODE" == "preflight" ]]; then
  block_epoch="$(date -d "$BLOCK_TIME" +%s 2>/dev/null || echo 0)"
  block_age=$(( $(date +%s) - block_epoch ))
  if (( block_epoch == 0 || block_age > 180 )); then
    echo "Latest block is too old for safe preflight: $BLOCK_TIME" >&2
    exit 1
  fi
  if [[ "$CATCHING_UP" != "false" ]]; then
    echo "Warning: catching_up=true, but the latest block is current (${block_age}s old)."
  fi
fi

if [[ "$MODE" == "apply" ]]; then
  if [[ ! "$UPGRADE_HEIGHT" =~ ^[0-9]+$ || "$UPGRADE_HEIGHT" -lt 1 ]]; then
    echo "Apply requires the published --upgrade-height HEIGHT." >&2
    exit 1
  fi
  if [[ -z "$UPGRADE_NAME" ]]; then
    echo "Apply requires the published --upgrade-name NAME." >&2
    exit 1
  fi
  if [[ -z "$MINIMUM_GAS_PRICES" || ! "$MINIMUM_GAS_PRICES" =~ ^[0-9]+([.][0-9]+)?[A-Za-z][A-Za-z0-9/:._-]*$ ]]; then
    echo "Apply requires a valid published --minimum-gas-prices value." >&2
    exit 1
  fi
  if [[ "$COORDINATED_HARDFORK" == "true" && "$POST_HARDFORK_RECOVERY" == "true" ]]; then
    echo "Choose either --coordinated-hardfork or --post-hardfork-recovery, not both." >&2
    exit 1
  fi
  if [[ "$POST_HARDFORK_RECOVERY" == "true" ]]; then
    canonical_status="$(curl -fsS --max-time 10 "${TRUSTED_RPC%/}/status")" || {
      echo "Could not read trusted canonical RPC: $TRUSTED_RPC" >&2
      exit 1
    }
    canonical_chain="$(jq -r '.result.node_info.network // empty' <<<"$canonical_status")"
    canonical_height="$(jq -r '.result.sync_info.latest_block_height // "0"' <<<"$canonical_status")"
    if [[ "$canonical_chain" != "$CHAIN_ID" || ! "$canonical_height" =~ ^[0-9]+$ || "$canonical_height" -lt "$UPGRADE_HEIGHT" ]]; then
      echo "Trusted RPC has not reached $CHAIN_ID height $UPGRADE_HEIGHT (reported $canonical_chain height $canonical_height)." >&2
      exit 1
    fi
    echo "Post-hardfork recovery authorized from canonical height $canonical_height."
  elif [[ "$COORDINATED_HARDFORK" == "true" ]]; then
    if [[ "$LIVE_STATUS_AVAILABLE" != "true" ]]; then
      echo "A coordinated hard-fork replacement requires a responsive live node before activation." >&2
      exit 1
    fi
    if (( HEIGHT >= UPGRADE_HEIGHT || HEIGHT + 1000 < UPGRADE_HEIGHT )); then
      echo "Coordinated hard-fork apply is allowed only within 1,000 blocks before height $UPGRADE_HEIGHT (current $HEIGHT)." >&2
      exit 1
    fi
  else
    if [[ "$LIVE_STATUS_AVAILABLE" != "true" ]]; then
      validate_halt_plan
    fi
    if (( HEIGHT < UPGRADE_HEIGHT )) &&
       ! { [[ "$LIVE_STATUS_AVAILABLE" != "true" ]] && (( HEIGHT + 1 == UPGRADE_HEIGHT )); }; then
      echo "Refusing early apply: current height $HEIGHT is below upgrade height $UPGRADE_HEIGHT." >&2
      exit 1
    fi
  fi
fi

if [[ "$MODE" == "verify" ]]; then
  echo "Validator verification passed"
  echo "  Container:         $CONTAINER_NAME"
  echo "  Chain:             $NETWORK"
  echo "  Height:            $HEIGHT"
  echo "  Catching up:       $CATCHING_UP"
  echo "  Validator address: $VALIDATOR_ADDRESS"
  exit 0
fi

verify_upgrade_image
backup_node preflight
print_preflight

if [[ "$MODE" == "preflight" ]]; then
  echo "No container was stopped or replaced."
  exit 0
fi

BASE_VALIDATOR_ADDRESS="$VALIDATOR_ADDRESS"
BASE_PRIVKEY_HASH="$PRIVKEY_HASH"
BASE_NODEKEY_HASH="$NODEKEY_HASH"

watchdog_was_active=false
if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet salvorias-validator-watchdog.timer; then
  watchdog_was_active=true
  systemctl stop salvorias-validator-watchdog.timer
fi

echo "Stopping $CONTAINER_NAME for the upgrade..."
docker stop --time 60 "$CONTAINER_NAME" >/dev/null
if ! validate_mount; then
  docker start "$CONTAINER_NAME" >/dev/null
  [[ "$watchdog_was_active" != "true" ]] || systemctl start salvorias-validator-watchdog.timer
  exit 1
fi
SIGNING_STATE_HASH="$(test -f "$NODE_HOME_MOUNT_SOURCE/data/priv_validator_state.json" && sha256sum "$NODE_HOME_MOUNT_SOURCE/data/priv_validator_state.json" | cut -d' ' -f1 || true)"
if ! backup_node stopped; then
  docker start "$CONTAINER_NAME" >/dev/null
  [[ "$watchdog_was_active" != "true" ]] || systemctl start salvorias-validator-watchdog.timer
  exit 1
fi

OLD_CONTAINER="$CONTAINER_NAME-preupgrade-$(date -u +%Y%m%dT%H%M%SZ)"
if ! docker rename "$CONTAINER_NAME" "$OLD_CONTAINER"; then
  docker start "$CONTAINER_NAME" >/dev/null
  [[ "$watchdog_was_active" != "true" ]] || systemctl start salvorias-validator-watchdog.timer
  exit 1
fi

if ! start_replacement "$BACKUP_DIR/container-inspect.json"; then
  restore_old_container "$OLD_CONTAINER"
  exit 1
fi

if ! wait_for_rpc; then
  restore_old_container "$OLD_CONTAINER"
  exit 1
fi

if ! read_identity ||
   [[ "$VALIDATOR_ADDRESS" != "$BASE_VALIDATOR_ADDRESS" ]] ||
   [[ "$PRIVKEY_HASH" != "$BASE_PRIVKEY_HASH" ]] ||
   [[ "$NODEKEY_HASH" != "$BASE_NODEKEY_HASH" ]]; then
  echo "Validator identity changed after replacement." >&2
  restore_old_container "$OLD_CONTAINER"
  exit 1
fi

ACTIVE_MINIMUM_GAS_PRICES="$(docker inspect "$CONTAINER_NAME" | jq -r '
  .[0].Config.Cmd as $cmd |
  reduce range(0; $cmd | length) as $i ("";
    if $cmd[$i] == "--minimum-gas-prices" then $cmd[$i + 1]
    elif ($cmd[$i] | startswith("--minimum-gas-prices=")) then ($cmd[$i] | split("=")[1])
    else . end)
')"
if [[ "$ACTIVE_MINIMUM_GAS_PRICES" != "$MINIMUM_GAS_PRICES" ]]; then
  echo "Replacement minimum gas prices do not match the requested value." >&2
  restore_old_container "$OLD_CONTAINER"
  exit 1
fi

sleep 15
if [[ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME")" != "true" ]]; then
  restore_old_container "$OLD_CONTAINER"
  exit 1
fi

if [[ "$watchdog_was_active" == "true" ]]; then
  systemctl start salvorias-validator-watchdog.timer
fi

echo "Upgrade container validation passed"
echo "  New container:     $CONTAINER_NAME"
echo "  Retained rollback: $OLD_CONTAINER"
echo "  Chain:             $NETWORK"
echo "  Height:            $HEIGHT"
echo "  Catching up:       $CATCHING_UP"
echo "  Validator address: $VALIDATOR_ADDRESS"
echo "  Minimum gas price: $ACTIVE_MINIMUM_GAS_PRICES"
echo "  Safety backup:     $BACKUP_DIR"
echo
echo "Keep the rollback container until the network has resumed and the team has completed post-upgrade validation."
