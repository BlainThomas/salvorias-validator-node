#!/usr/bin/env bash
set -euo pipefail

IMAGE="${IMAGE:-}"
DOCKER_PLATFORM="${DOCKER_PLATFORM:-linux/amd64}"
CONTAINER_NAME="${CONTAINER_NAME:-salvorias-validator}"
VOLUME_NAME="${VOLUME_NAME:-salvorias-validator-data}"
CHAIN_ID="${CHAIN_ID:-salvorias_7282-1}"
STATE_SYNC_RPC="${STATE_SYNC_RPC:-http://134.199.216.166:26660}"
PERSISTENT_PEERS="${PERSISTENT_PEERS:-bc9decb51c24982322c756b7c9a0c837ed7a7216@134.199.216.166:26656,7883bda6e4de7db2b7056ead781a0a6383bd31c8@45.32.168.97:26656,e870477adf4f8b7a35c86d9910409482a573bfbb@149.28.244.23:26656,eb33b07b52618fce53f755aac07337e8a8c91a2e@64.177.113.190:26656,f2d72c52432db11bdbe02e6c14726a06def0de2e@147.182.223.228:26656}"
TRUST_OFFSET="${TRUST_OFFSET:-2000}"
STATE_SYNC_DISCOVERY_TIME="${STATE_SYNC_DISCOVERY_TIME:-60s}"
HOME_DIR="/home/evmos/.evmosd"

usage() {
  cat <<EOF
Usage: $0 [options]

Reset an existing Salvorias validator container to state-sync from the current
production RPC. This removes local chain data but keeps the validator key.

Options:
  --container-name NAME   Container name. Default: $CONTAINER_NAME
  --volume-name NAME      Docker volume name. Default: $VOLUME_NAME
  --image IMAGE           Image to use for config edits. Default: current container image.
  -h, --help              Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --container-name) CONTAINER_NAME="$2"; shift 2 ;;
    --volume-name) VOLUME_NAME="$2"; shift 2 ;;
    --image) IMAGE="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done

if ! command -v docker >/dev/null 2>&1; then
  echo "Missing docker." >&2
  exit 1
fi
if ! command -v curl >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
  echo "Missing curl or jq." >&2
  exit 1
fi
if ! docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
  echo "Container not found: $CONTAINER_NAME" >&2
  exit 1
fi

if [[ -z "$IMAGE" ]]; then
  IMAGE="$(docker inspect "$CONTAINER_NAME" --format '{{.Config.Image}}')"
fi

echo "============================================"
echo " Salvorias State Sync Reset"
echo "============================================"
echo " Container:  $CONTAINER_NAME"
echo " Volume:     $VOLUME_NAME"
echo " Image:      $IMAGE"
echo " RPC:        $STATE_SYNC_RPC"
echo

LATEST="$(curl -fsS "$STATE_SYNC_RPC/status" | jq -r '.result.sync_info.latest_block_height')"
TRUST_HEIGHT=$((LATEST - TRUST_OFFSET))
if [[ "$TRUST_HEIGHT" -lt 1 ]]; then
  TRUST_HEIGHT=1
fi
TRUST_HASH="$(curl -fsS "$STATE_SYNC_RPC/commit?height=$TRUST_HEIGHT" | jq -r '.result.signed_header.commit.block_id.hash')"

if [[ -z "$TRUST_HASH" || "$TRUST_HASH" == "null" ]]; then
  echo "Could not fetch trust hash from $STATE_SYNC_RPC at height $TRUST_HEIGHT" >&2
  exit 1
fi

echo " Trust height: $TRUST_HEIGHT"
echo " Trust hash:   $TRUST_HASH"
echo

docker stop "$CONTAINER_NAME" >/dev/null 2>&1 || true

SETUP_CONTAINER="${CONTAINER_NAME}-statesync-reset-$$"
cleanup() {
  docker rm -f "$SETUP_CONTAINER" >/dev/null 2>&1 || true
}
trap cleanup EXIT

docker run -d --name "$SETUP_CONTAINER" \
  --platform "$DOCKER_PLATFORM" \
  -v "$VOLUME_NAME:$HOME_DIR" \
  --entrypoint sleep \
  "$IMAGE" infinity >/dev/null

docker exec "$SETUP_CONTAINER" sh -lc "
  set -e
  CFG='$HOME_DIR/config/config.toml'
  if [ ! -f \"\$CFG\" ]; then
    echo 'Missing config.toml in validator volume' >&2
    exit 1
  fi

  rm -rf '$HOME_DIR/data'
  mkdir -p '$HOME_DIR/data'
  # Keep the JSON opaque to this nested shell. Literal quotes in a heredoc are
  # otherwise consumed by the outer nested shell string before the inner shell
  # writes the file, producing invalid JSON and preventing the node from booting.
  printf '%s' 'eyJoZWlnaHQiOiIwIiwicm91bmQiOjAsInN0ZXAiOjB9Cg==' |
    base64 -d > '$HOME_DIR/data/priv_validator_state.json'

  sed -i 's|^persistent_peers = .*|persistent_peers = \"'$PERSISTENT_PEERS'\"|' \"\$CFG\"
  sed -i 's|^addr_book_strict = .*|addr_book_strict = false|' \"\$CFG\"

  sed -i '/^\\[statesync\\]/,/^\\[/ s|^enable = .*|enable = true|' \"\$CFG\"
  sed -i '/^\\[statesync\\]/,/^\\[/ s|^rpc_servers = .*|rpc_servers = \"'$STATE_SYNC_RPC','$STATE_SYNC_RPC'\"|' \"\$CFG\"
  sed -i '/^\\[statesync\\]/,/^\\[/ s|^trust_height = .*|trust_height = '$TRUST_HEIGHT'|' \"\$CFG\"
  sed -i '/^\\[statesync\\]/,/^\\[/ s|^trust_hash = .*|trust_hash = \"'$TRUST_HASH'\"|' \"\$CFG\"
  sed -i '/^\\[statesync\\]/,/^\\[/ s|^trust_period = .*|trust_period = \"168h0m0s\"|' \"\$CFG\"
  sed -i '/^\\[statesync\\]/,/^\\[/ s|^discovery_time = .*|discovery_time = \"'$STATE_SYNC_DISCOVERY_TIME'\"|' \"\$CFG\"
"

docker rm -f "$SETUP_CONTAINER" >/dev/null
trap - EXIT

docker start "$CONTAINER_NAME" >/dev/null

echo "State sync reset complete. Follow logs with:"
echo "  docker logs -f --tail 200 $CONTAINER_NAME"
