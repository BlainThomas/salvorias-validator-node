#!/usr/bin/env bash
set -euo pipefail

IMAGE="${IMAGE:-}"
IMAGE_TARBALL_URL="${IMAGE_TARBALL_URL:-}"
IMAGE_TARBALL_SHA256="${IMAGE_TARBALL_SHA256:-}"
DOCKER_PLATFORM="${DOCKER_PLATFORM:-linux/amd64}"
CONTAINER_NAME="${CONTAINER_NAME:-salvorias-validator}"
VOLUME_NAME="${VOLUME_NAME:-salvorias-validator-data}"
KEY_NAME="${KEY_NAME:-validator}"
CHAIN_ID="${CHAIN_ID:-salvorias_7282-1}"
EVM_CHAIN_ID="${EVM_CHAIN_ID:-7282}"
DENOM="${DENOM:-SAVDR}"
MINIMUM_GAS_PRICES="${MINIMUM_GAS_PRICES:-1000000000SAVDR}"
STATE_SYNC_RPC="${STATE_SYNC_RPC:-http://134.199.216.166:26660}"
PERSISTENT_PEERS="${PERSISTENT_PEERS:-bc9decb51c24982322c756b7c9a0c837ed7a7216@134.199.216.166:26656,7883bda6e4de7db2b7056ead781a0a6383bd31c8@45.32.168.97:26656,e870477adf4f8b7a35c86d9910409482a573bfbb@149.28.244.23:26656,eb33b07b52618fce53f755aac07337e8a8c91a2e@64.177.113.190:26656,f2d72c52432db11bdbe02e6c14726a06def0de2e@147.182.223.228:26656}"
TRUST_OFFSET="${TRUST_OFFSET:-2000}"
STATE_SYNC_DISCOVERY_TIME="${STATE_SYNC_DISCOVERY_TIME:-60s}"
HOME_DIR="/home/evmos/.evmosd"
HOST_P2P_PORT="${HOST_P2P_PORT:-26656}"
HOST_RPC_PORT="${HOST_RPC_PORT:-26657}"
HOST_API_PORT="${HOST_API_PORT:-1317}"
HOST_EVM_RPC_PORT="${HOST_EVM_RPC_PORT:-8545}"
HOST_EVM_WS_PORT="${HOST_EVM_WS_PORT:-8546}"
HOST_GRPC_PORT="${HOST_GRPC_PORT:-9090}"
HOST_LOCAL_BIND="${HOST_LOCAL_BIND:-127.0.0.1}"
LOG_MAX_SIZE="${LOG_MAX_SIZE:-100m}"
LOG_MAX_FILE="${LOG_MAX_FILE:-5}"
INSTALL_WATCHDOG="${INSTALL_WATCHDOG:-true}"
MONIKER=""
EXTERNAL_IP=""
MNEMONIC=""
MNEMONIC_FILE=""
FORCE="false"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/security-guards.sh
source "$SCRIPT_DIR/lib/security-guards.sh"

usage() {
  cat <<EOF
Usage: $0 --moniker NAME --external-ip IP [options]

Options:
  --moniker NAME          Validator moniker.
  --external-ip IP        Public IP advertised for P2P.
  --mnemonic-file PATH    Read validator mnemonic from file.
  --mnemonic "WORDS"      Pass mnemonic directly. Prefer --mnemonic-file or prompt.
  --image IMAGE           Immutable Docker image reference ending in @sha256:...
  --force                 Remove existing container before starting.
  -h, --help              Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --moniker) MONIKER="$2"; shift 2 ;;
    --external-ip) EXTERNAL_IP="$2"; shift 2 ;;
    --mnemonic-file) MNEMONIC_FILE="$2"; shift 2 ;;
    --mnemonic) MNEMONIC="$2"; shift 2 ;;
    --image) IMAGE="$2"; shift 2 ;;
    --force) FORCE="true"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done

is_root() {
  [[ "$(id -u)" -eq 0 ]]
}

install_base_packages() {
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y ca-certificates curl jq
  else
    echo "Missing curl/jq and this script only auto-installs packages on apt-based systems." >&2
    echo "Install curl, jq, and Docker, then rerun this script." >&2
    exit 1
  fi
}

ensure_base_packages() {
  if command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
    return
  fi
  if ! is_root; then
    echo "curl/jq are missing. Rerun with sudo/root so the script can install them." >&2
    exit 1
  fi
  echo "Installing required packages: curl jq"
  install_base_packages
}

ensure_docker() {
  if command -v docker >/dev/null 2>&1 && docker version >/dev/null 2>&1; then
    return
  fi
  if ! is_root; then
    echo "Docker is missing or not running. Rerun with sudo/root so the script can install/start Docker." >&2
    exit 1
  fi
  echo "Installing Docker..."
  curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
  sh /tmp/get-docker.sh
  systemctl enable docker >/dev/null 2>&1 || true
  systemctl start docker >/dev/null 2>&1 || service docker start >/dev/null 2>&1 || true
  docker version >/dev/null
}

ensure_base_packages
ensure_docker

validate_onboarding_security_inputs "$IMAGE" "$HOST_LOCAL_BIND" "$IMAGE_TARBALL_URL" "$IMAGE_TARBALL_SHA256"

if [[ -z "$MONIKER" ]]; then
  read -r -p "Validator moniker: " MONIKER
fi

if [[ -z "$EXTERNAL_IP" ]]; then
  DETECTED_IP="$(curl -fsS --max-time 10 https://ifconfig.me 2>/dev/null || true)"
  read -r -p "External public IP [${DETECTED_IP}]: " EXTERNAL_IP
  EXTERNAL_IP="${EXTERNAL_IP:-$DETECTED_IP}"
fi

if [[ -z "$MONIKER" || -z "$EXTERNAL_IP" ]]; then
  echo "moniker and external-ip are required." >&2
  exit 1
fi

if [[ -n "$MNEMONIC_FILE" ]]; then
  MNEMONIC="$(tr '\n' ' ' < "$MNEMONIC_FILE" | sed 's/[[:space:]]*$//')"
fi

echo "============================================"
echo " Salvorias Validator Onboarding"
echo "============================================"
echo " Moniker:       $MONIKER"
echo " External IP:   $EXTERNAL_IP"
echo " Image:         $IMAGE"
echo " Chain ID:      $CHAIN_ID"
echo " Native denom:  $DENOM"
echo " Min gas price: $MINIMUM_GAS_PRICES"
echo " State sync:    $STATE_SYNC_RPC"
echo " Log cap:       ${LOG_MAX_FILE} files x ${LOG_MAX_SIZE}"
echo

if ! docker pull "$IMAGE"; then
  echo
  echo "Docker registry pull failed for $IMAGE."
  echo "Falling back to release image tarball:"
  echo "  $IMAGE_TARBALL_URL"
  TMP_IMAGE="$(mktemp -t salvorias-validator-image.XXXXXX.tar.gz)"
  curl -fL --retry 3 --retry-delay 3 -o "$TMP_IMAGE" "$IMAGE_TARBALL_URL"
  verify_sha256 "$TMP_IMAGE" "$IMAGE_TARBALL_SHA256"
  docker load -i "$TMP_IMAGE"
  rm -f "$TMP_IMAGE"
fi

if docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
  if [[ "$FORCE" == "true" ]]; then
    docker rm -f "$CONTAINER_NAME" >/dev/null
  else
    echo "Container already exists: $CONTAINER_NAME"
    echo "Use --force to replace it, or run ./scripts/status.sh to inspect it."
    exit 1
  fi
fi

docker volume create "$VOLUME_NAME" >/dev/null

SETUP_CONTAINER="${CONTAINER_NAME}-setup-$$"
cleanup() {
  docker rm -f "$SETUP_CONTAINER" >/dev/null 2>&1 || true
}
trap cleanup EXIT

docker run -d --name "$SETUP_CONTAINER" \
  --platform "$DOCKER_PLATFORM" \
  -v "$VOLUME_NAME:$HOME_DIR" \
  --entrypoint sleep \
  "$IMAGE" infinity >/dev/null

echo "Fetching genesis from state-sync RPC..."
GENESIS_FILE="$(mktemp)"
curl -fsS "$STATE_SYNC_RPC/genesis" | jq '.result.genesis' > "$GENESIS_FILE"
docker cp "$GENESIS_FILE" "$SETUP_CONTAINER:/tmp/genesis.json"
rm -f "$GENESIS_FILE"

echo "Initializing node home..."
docker exec "$SETUP_CONTAINER" sh -lc "
  rm -rf '$HOME_DIR/config' '$HOME_DIR/data'
  evmosd init '$MONIKER' --chain-id '$CHAIN_ID' --home '$HOME_DIR' >/dev/null 2>&1
  cp /tmp/genesis.json '$HOME_DIR/config/genesis.json'
  evmosd config set client chain-id '$CHAIN_ID' --home '$HOME_DIR' >/dev/null 2>&1 || true
  evmosd config set client keyring-backend test --home '$HOME_DIR' >/dev/null 2>&1 || true
"

if [[ -z "$MNEMONIC" ]]; then
  echo
  echo "Paste existing validator mnemonic and press enter."
  echo "Leave blank to create a new validator key."
  read -r -s -p "Mnemonic: " MNEMONIC
  echo
fi

if [[ -n "$MNEMONIC" ]]; then
  echo "Importing validator key..."
  MNEMONIC_TMP="$(mktemp)"
  printf '%s\n' "$MNEMONIC" > "$MNEMONIC_TMP"
  docker cp "$MNEMONIC_TMP" "$SETUP_CONTAINER:/tmp/validator.mnemonic"
  rm -f "$MNEMONIC_TMP"
  if ! docker exec "$SETUP_CONTAINER" sh -lc "
    set -e
    evmosd keys delete '$KEY_NAME' --yes --keyring-backend test --home '$HOME_DIR' >/dev/null 2>&1 || true
    evmosd keys add '$KEY_NAME' \
      --recover \
      --algo eth_secp256k1 \
      --keyring-backend test \
      --home '$HOME_DIR' \
      --source /tmp/validator.mnemonic >/tmp/key.out
    rm -f /tmp/validator.mnemonic
    cat /tmp/key.out
  "; then
    docker exec "$SETUP_CONTAINER" rm -f /tmp/validator.mnemonic >/dev/null 2>&1 || true
    echo "Failed to import validator mnemonic." >&2
    exit 1
  fi
else
  if docker exec "$SETUP_CONTAINER" evmosd keys show "$KEY_NAME" --keyring-backend test --home "$HOME_DIR" >/dev/null 2>&1; then
    echo "Using existing validator key '$KEY_NAME' from Docker volume."
    docker exec "$SETUP_CONTAINER" evmosd keys show "$KEY_NAME" --keyring-backend test --home "$HOME_DIR"
  else
    echo "Creating new validator key. Save this mnemonic now; it will not be printed again."
    docker exec "$SETUP_CONTAINER" sh -lc "
      evmosd keys add '$KEY_NAME' \
        --algo eth_secp256k1 \
        --keyring-backend test \
        --home '$HOME_DIR'
    "
  fi
fi

echo "Configuring state sync..."
LATEST="$(curl -fsS "$STATE_SYNC_RPC/status" | jq -r '.result.sync_info.latest_block_height')"
TRUST_HEIGHT=$((LATEST - TRUST_OFFSET))
if [[ "$TRUST_HEIGHT" -lt 1 ]]; then
  TRUST_HEIGHT=1
fi
TRUST_HASH="$(curl -fsS "$STATE_SYNC_RPC/commit?height=$TRUST_HEIGHT" | jq -r '.result.signed_header.commit.block_id.hash')"

docker exec "$SETUP_CONTAINER" sh -lc "
  CFG='$HOME_DIR/config/config.toml'
  APP='$HOME_DIR/config/app.toml'

  sed -i 's|^moniker = .*|moniker = \"'$MONIKER'\"|' \"\$CFG\"
  sed -i 's|^external_address = .*|external_address = \"'$EXTERNAL_IP':26656\"|' \"\$CFG\"
  sed -i 's|^persistent_peers = .*|persistent_peers = \"'$PERSISTENT_PEERS'\"|' \"\$CFG\"
  sed -i 's|^addr_book_strict = .*|addr_book_strict = false|' \"\$CFG\"

  sed -i '/^\\[statesync\\]/,/^\\[/ s|^enable = .*|enable = true|' \"\$CFG\"
  sed -i '/^\\[statesync\\]/,/^\\[/ s|^rpc_servers = .*|rpc_servers = \"'$STATE_SYNC_RPC','$STATE_SYNC_RPC'\"|' \"\$CFG\"
  sed -i '/^\\[statesync\\]/,/^\\[/ s|^trust_height = .*|trust_height = '$TRUST_HEIGHT'|' \"\$CFG\"
  sed -i '/^\\[statesync\\]/,/^\\[/ s|^trust_hash = .*|trust_hash = \"'$TRUST_HASH'\"|' \"\$CFG\"
  sed -i '/^\\[statesync\\]/,/^\\[/ s|^trust_period = .*|trust_period = \"168h0m0s\"|' \"\$CFG\"
  sed -i '/^\\[statesync\\]/,/^\\[/ s|^discovery_time = .*|discovery_time = \"'$STATE_SYNC_DISCOVERY_TIME'\"|' \"\$CFG\"

  sed -i 's|^minimum-gas-prices = .*|minimum-gas-prices = \"'$MINIMUM_GAS_PRICES'\"|' \"\$APP\"
  sed -i '/^\\[api\\]/,/^\\[/ s|^enable = .*|enable = true|' \"\$APP\"
  sed -i '/^\\[api\\]/,/^\\[/ s|^swagger = .*|swagger = true|' \"\$APP\"
  sed -i '/^\\[rosetta\\]/,/^\\[/ s|^enable = .*|enable = false|' \"\$APP\"
  sed -i '/^\\[json-rpc\\]/,/^\\[/ s|^api = .*|api = \"eth,net,web3\"|' \"\$APP\"
  sed -i '/^\\[json-rpc\\]/,/^\\[/ s|^allow-insecure-unlock = .*|allow-insecure-unlock = false|' \"\$APP\"

  awk '
    /^\\[json-rpc\\]\$/ { in_json_rpc=1; next }
    /^\\[/ { in_json_rpc=0 }
    in_json_rpc && /^api = \"eth,net,web3\"\$/ { safe_api=1 }
    in_json_rpc && /^allow-insecure-unlock = false\$/ { safe_unlock=1 }
    END { exit !(safe_api && safe_unlock) }
  ' \"\$APP\"
"

echo "Starting validator container..."
docker stop "$SETUP_CONTAINER" >/dev/null
docker rm "$SETUP_CONTAINER" >/dev/null
trap - EXIT

docker run -d \
  --name "$CONTAINER_NAME" \
  --restart unless-stopped \
  --platform "$DOCKER_PLATFORM" \
  --log-driver json-file \
  --log-opt "max-size=$LOG_MAX_SIZE" \
  --log-opt "max-file=$LOG_MAX_FILE" \
  -v "$VOLUME_NAME:$HOME_DIR" \
  -p "$HOST_P2P_PORT:26656" \
  -p "$HOST_LOCAL_BIND:$HOST_RPC_PORT:26657" \
  -p "$HOST_LOCAL_BIND:$HOST_API_PORT:1317" \
  -p "$HOST_LOCAL_BIND:$HOST_EVM_RPC_PORT:8545" \
  -p "$HOST_LOCAL_BIND:$HOST_EVM_WS_PORT:8546" \
  -p "$HOST_LOCAL_BIND:$HOST_GRPC_PORT:9090" \
  "$IMAGE" evmosd start \
    --home "$HOME_DIR" \
    --chain-id "$CHAIN_ID" \
    --minimum-gas-prices "$MINIMUM_GAS_PRICES" \
    --rpc.laddr tcp://0.0.0.0:26657 \
    --p2p.laddr tcp://0.0.0.0:26656 \
    --json-rpc.enable \
    --json-rpc.address 0.0.0.0:8545 \
    --json-rpc.ws-address 0.0.0.0:8546 \
    --grpc.enable \
    --grpc.address 0.0.0.0:9090 >/dev/null

if [[ "$INSTALL_WATCHDOG" == "true" && -f "./scripts/watchdog.sh" ]]; then
  echo "Installing validator watchdog..."
  install -m 0755 ./scripts/watchdog.sh /usr/local/sbin/salvorias-validator-watchdog
  cat > /etc/default/salvorias-validator-watchdog <<EOF
CONTAINER_NAME=$CONTAINER_NAME
MIN_PEERS=2
STALE_AFTER_SECONDS=180
CATCHING_UP_AFTER_SECONDS=600
RESTART_COOLDOWN_SECONDS=300
EOF
  if command -v systemctl >/dev/null 2>&1; then
    cat > /etc/systemd/system/salvorias-validator-watchdog.service <<'EOF'
[Unit]
Description=Salvorias validator watchdog
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
EnvironmentFile=-/etc/default/salvorias-validator-watchdog
ExecStart=/usr/local/sbin/salvorias-validator-watchdog
EOF
    cat > /etc/systemd/system/salvorias-validator-watchdog.timer <<'EOF'
[Unit]
Description=Run Salvorias validator watchdog every minute

[Timer]
OnBootSec=2min
OnUnitActiveSec=1min
AccuracySec=10s
Unit=salvorias-validator-watchdog.service

[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload
    systemctl enable --now salvorias-validator-watchdog.timer >/dev/null
  else
    (crontab -l 2>/dev/null | grep -v '/usr/local/sbin/salvorias-validator-watchdog'; echo '* * * * * . /etc/default/salvorias-validator-watchdog 2>/dev/null; /usr/local/sbin/salvorias-validator-watchdog >/dev/null 2>&1') | crontab -
  fi
fi

echo "Waiting for validator RPC..."
for _ in $(seq 1 60); do
  if docker exec "$CONTAINER_NAME" sh -lc "curl -fsS http://127.0.0.1:26657/status >/dev/null 2>&1"; then
    break
  fi
  if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
    echo "Container stopped during startup. Recent logs:" >&2
    docker logs --tail 120 "$CONTAINER_NAME" >&2 || true
    exit 1
  fi
  sleep 2
done

if ! docker exec "$CONTAINER_NAME" sh -lc "curl -fsS http://127.0.0.1:26657/status >/dev/null 2>&1"; then
  echo "Validator RPC did not become ready. Recent logs:" >&2
  docker logs --tail 160 "$CONTAINER_NAME" >&2 || true
  exit 1
fi

echo
echo "Validator container started."
echo
echo "Account:"
docker exec "$CONTAINER_NAME" evmosd keys show "$KEY_NAME" --keyring-backend test --home "$HOME_DIR" --bech acc
echo
echo "Valoper:"
docker exec "$CONTAINER_NAME" evmosd keys show "$KEY_NAME" --keyring-backend test --home "$HOME_DIR" --bech val
echo
docker exec "$CONTAINER_NAME" evmosd tendermint show-validator --home "$HOME_DIR" | sed 's/^/Consensus Pubkey: /'
NODE_ID="$(docker exec "$CONTAINER_NAME" evmosd tendermint show-node-id --home "$HOME_DIR")"
echo "Node ID: $NODE_ID"
echo "Peer: ${NODE_ID}@${EXTERNAL_IP}:26656"
echo
echo "Sync status:"
docker exec "$CONTAINER_NAME" sh -lc "curl -s http://127.0.0.1:26657/status | jq '.result.sync_info'"
echo
echo "Next:"
echo "  1. Send Account, Valoper, Consensus Pubkey, and Peer to the Salvorias operator."
echo "  2. Wait for funding and whitelist approval."
echo "  3. Run ./scripts/status.sh until catching_up is false."
echo "  4. Run ./scripts/activate-validator.sh --moniker \"$MONIKER\""
