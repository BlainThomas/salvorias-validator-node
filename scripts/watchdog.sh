#!/usr/bin/env bash
set -euo pipefail

CONTAINER_NAME="${CONTAINER_NAME:-salvorias-validator}"
STATE_DIR="${STATE_DIR:-/var/lib/salvorias-validator-watchdog}"
MIN_PEERS="${MIN_PEERS:-2}"
STALE_AFTER_SECONDS="${STALE_AFTER_SECONDS:-180}"
CATCHING_UP_AFTER_SECONDS="${CATCHING_UP_AFTER_SECONDS:-600}"
RESTART_COOLDOWN_SECONDS="${RESTART_COOLDOWN_SECONDS:-300}"
LOG_FILE="${LOG_FILE:-/var/log/salvorias-validator-watchdog.log}"

mkdir -p "$STATE_DIR"
touch "$LOG_FILE" 2>/dev/null || LOG_FILE="/dev/stderr"

log() {
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$LOG_FILE"
}

now="$(date +%s)"
last_restart_file="$STATE_DIR/last_restart"
last_height_file="$STATE_DIR/last_height"
last_height_time_file="$STATE_DIR/last_height_time"
catching_since_file="$STATE_DIR/catching_up_since"

restart_container() {
  local reason="$1"
  local last_restart=0
  if [[ -f "$last_restart_file" ]]; then
    last_restart="$(cat "$last_restart_file" 2>/dev/null || echo 0)"
  fi

  if (( now - last_restart < RESTART_COOLDOWN_SECONDS )); then
    log "restart suppressed reason=$reason cooldown_remaining=$((RESTART_COOLDOWN_SECONDS - (now - last_restart)))"
    return
  fi

  log "restarting container=$CONTAINER_NAME reason=$reason"
  docker restart "$CONTAINER_NAME" >/dev/null
  printf '%s\n' "$now" > "$last_restart_file"
}

if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
  if docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
    log "container stopped; starting container=$CONTAINER_NAME"
    docker start "$CONTAINER_NAME" >/dev/null
    printf '%s\n' "$now" > "$last_restart_file"
  else
    log "container missing container=$CONTAINER_NAME"
  fi
  exit 0
fi

status_json="$(docker exec "$CONTAINER_NAME" sh -lc 'curl -fsS --max-time 5 http://127.0.0.1:26657/status' 2>/dev/null || true)"
if [[ -z "$status_json" ]]; then
  restart_container "rpc_unavailable"
  exit 0
fi

height="$(printf '%s' "$status_json" | jq -r '.result.sync_info.latest_block_height // "0"' 2>/dev/null || echo 0)"
catching_up="$(printf '%s' "$status_json" | jq -r '.result.sync_info.catching_up | if type == "boolean" then . else true end' 2>/dev/null || echo true)"

net_json="$(docker exec "$CONTAINER_NAME" sh -lc 'curl -fsS --max-time 5 http://127.0.0.1:26657/net_info' 2>/dev/null || true)"
peers=0
if [[ -n "$net_json" ]]; then
  peers="$(printf '%s' "$net_json" | jq -r '.result.n_peers // "0"' 2>/dev/null || echo 0)"
fi

if [[ "$height" =~ ^[0-9]+$ ]]; then
  previous_height="$(cat "$last_height_file" 2>/dev/null || echo 0)"
  previous_time="$(cat "$last_height_time_file" 2>/dev/null || echo "$now")"

  if (( height > previous_height )); then
    printf '%s\n' "$height" > "$last_height_file"
    printf '%s\n' "$now" > "$last_height_time_file"
  elif (( height > 0 && now - previous_time >= STALE_AFTER_SECONDS )); then
    restart_container "height_stalled height=$height stale_seconds=$((now - previous_time))"
    printf '%s\n' "$now" > "$last_height_time_file"
  fi
fi

if [[ "$catching_up" == "true" ]]; then
  if [[ ! -f "$catching_since_file" ]]; then
    printf '%s\n' "$now" > "$catching_since_file"
  else
    catching_since="$(cat "$catching_since_file" 2>/dev/null || echo "$now")"
    if (( now - catching_since >= CATCHING_UP_AFTER_SECONDS )); then
      restart_container "catching_up_too_long seconds=$((now - catching_since))"
      printf '%s\n' "$now" > "$catching_since_file"
    fi
  fi
else
  rm -f "$catching_since_file"
fi

if [[ "$peers" =~ ^[0-9]+$ ]] && (( peers < MIN_PEERS )); then
  restart_container "low_peer_count peers=$peers min=$MIN_PEERS"
fi

log "ok height=$height catching_up=$catching_up peers=$peers"
