#!/usr/bin/env bash
set -euo pipefail

CONTAINER="${CONTAINER:-salvorias-rpc-node}"
RPC_URL="${RPC_URL:-http://127.0.0.1:18550}"
STATUS_URL="${STATUS_URL:-http://127.0.0.1:36657/status}"
CANONICAL_RPC_URL="${CANONICAL_RPC_URL:-http://134.199.216.166:26660}"
CHAIN_ID="${CHAIN_ID:-salvorias_7282-1}"
MAX_LAG_BLOCKS="${MAX_LAG_BLOCKS:-10}"
MAX_BLOCK_AGE_SECONDS="${MAX_BLOCK_AGE_SECONDS:-90}"
FAILURES_BEFORE_RESTART="${FAILURES_BEFORE_RESTART:-2}"
SLACK_CHANNEL_ID="${SLACK_CHANNEL_ID:-}"
SLACK_BOT_TOKEN="${SLACK_BOT_TOKEN:-}"
STATE_DIR="${STATE_DIR:-/var/lib/salvorias-rpc-watchdog}"
LOG_FILE="${LOG_FILE:-/var/log/salvorias-rpc-watchdog.log}"

mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR"
FAILURE_FILE="$STATE_DIR/failure-count"
INCIDENT_FILE="$STATE_DIR/incident-open"
RESTART_ATTEMPTED_FILE="$STATE_DIR/restart-attempted"

log() {
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$LOG_FILE"
}

slack_post() {
  local message="$1" response
  if [[ -z "$SLACK_BOT_TOKEN" || -z "$SLACK_CHANNEL_ID" ]]; then
    log "Slack alert skipped: SLACK_BOT_TOKEN or SLACK_CHANNEL_ID is unset"
    return 0
  fi

  response="$(curl -fsS --connect-timeout 3 --max-time 10 \
    -H "Authorization: Bearer $SLACK_BOT_TOKEN" \
    -H "Content-Type: application/json; charset=utf-8" \
    --data "$(jq -cn --arg channel "$SLACK_CHANNEL_ID" --arg text "$message" '{channel:$channel,text:$text}')" \
    https://slack.com/api/chat.postMessage 2>&1 || true)"

  if ! jq -e '.ok == true' >/dev/null 2>&1 <<<"$response"; then
    log "Slack API rejected alert: $(jq -r '.error // "request_failed"' <<<"$response" 2>/dev/null || echo request_failed)"
    return 0
  fi
}

json_rpc_payload='{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}'
rpc_response="$(curl -sS --connect-timeout 3 --max-time 8 \
  -H 'Content-Type: application/json' --data "$json_rpc_payload" "$RPC_URL" 2>&1 || true)"
read_status="$(curl -sS --connect-timeout 3 --max-time 8 "$STATUS_URL" 2>&1 || true)"
canonical_status="$(curl -sS --connect-timeout 3 --max-time 8 "${CANONICAL_RPC_URL%/}/status" 2>&1 || true)"

reason=""
restart_required=false
read_hex="$(jq -r '.result // empty' <<<"$rpc_response" 2>/dev/null || true)"
read_height="$(jq -r '.result.sync_info.latest_block_height // empty' <<<"$read_status" 2>/dev/null || true)"
read_time="$(jq -r '.result.sync_info.latest_block_time // empty' <<<"$read_status" 2>/dev/null || true)"
read_hash="$(jq -r '.result.sync_info.latest_block_hash // empty' <<<"$read_status" 2>/dev/null || true)"
read_chain="$(jq -r '.result.node_info.network // empty' <<<"$read_status" 2>/dev/null || true)"
canonical_height="$(jq -r '.result.sync_info.latest_block_height // empty' <<<"$canonical_status" 2>/dev/null || true)"
canonical_chain="$(jq -r '.result.node_info.network // empty' <<<"$canonical_status" 2>/dev/null || true)"

if [[ ! "$read_hex" =~ ^0x[0-9a-fA-F]+$ ]]; then
  reason="eth_blockNumber failed"
  restart_required=true
elif [[ "$read_chain" != "$CHAIN_ID" ]]; then
  reason="read RPC chain ID mismatch (read=${read_chain:-missing}, expected=$CHAIN_ID)"
  restart_required=true
elif [[ ! "$read_height" =~ ^[0-9]+$ ]]; then
  reason="read RPC height unavailable"
  restart_required=true
elif [[ "$canonical_chain" != "$CHAIN_ID" || ! "$canonical_height" =~ ^[0-9]+$ ]]; then
  reason="canonical health reference unavailable or invalid"
else
  lag=$((canonical_height - read_height))
  if (( lag > MAX_LAG_BLOCKS )); then
    reason="read RPC is $lag blocks behind canonical (read=$read_height canonical=$canonical_height)"
    restart_required=true
  elif [[ -z "$read_time" ]]; then
    reason="latest block time unavailable"
    restart_required=true
  else
    block_epoch="$(date -d "$read_time" +%s 2>/dev/null || echo 0)"
    block_age=$(( $(date +%s) - block_epoch ))
    if (( block_epoch == 0 || block_age > MAX_BLOCK_AGE_SECONDS )); then
      reason="latest read-RPC block is ${block_age}s old (height=$read_height)"
      restart_required=true
    else
      canonical_block="$(curl -sS --connect-timeout 3 --max-time 8 \
        "${CANONICAL_RPC_URL%/}/block?height=$read_height" 2>&1 || true)"
      canonical_hash="$(jq -r '.result.block_id.hash // empty' <<<"$canonical_block" 2>/dev/null || true)"
      if [[ -n "$canonical_hash" && -n "$read_hash" && "$canonical_hash" != "$read_hash" ]]; then
        reason="block hash mismatch at height $read_height (read=$read_hash canonical=$canonical_hash)"
        restart_required=true
      elif [[ -z "$canonical_hash" ]]; then
        reason="canonical block-hash reference unavailable at height $read_height"
      fi
    fi
  fi
fi

if [[ -z "$reason" ]]; then
  if [[ -f "$INCIDENT_FILE" ]]; then
    previous="$(cat "$INCIDENT_FILE" 2>/dev/null || echo unknown)"
    slack_post ":white_check_mark: Salvorias Read RPC recovered. Current height $read_height; canonical height $canonical_height. Previous issue: $previous"
    log "Recovered: read=$read_height canonical=$canonical_height previous=$previous"
  fi
  rm -f "$FAILURE_FILE" "$INCIDENT_FILE" "$RESTART_ATTEMPTED_FILE"
  exit 0
fi

failures=0
[[ -f "$FAILURE_FILE" ]] && failures="$(cat "$FAILURE_FILE" 2>/dev/null || echo 0)"
[[ "$failures" =~ ^[0-9]+$ ]] || failures=0
failures=$((failures + 1))
printf '%s\n' "$failures" > "$FAILURE_FILE"
log "Health failure $failures/$FAILURES_BEFORE_RESTART: $reason"

if (( failures < FAILURES_BEFORE_RESTART )); then
  exit 0
fi

if [[ ! -f "$INCIDENT_FILE" ]]; then
  printf '%s\n' "$reason" > "$INCIDENT_FILE"
  if [[ "$restart_required" == true ]]; then
    slack_post ":rotating_light: Salvorias Read RPC unhealthy: $reason. Automatic restart is being attempted."
  else
    slack_post ":rotating_light: Salvorias chain health reference unavailable: $reason. The read RPC will not be restarted for a reference-only failure."
  fi
fi

if [[ "$restart_required" == true && ! -f "$RESTART_ATTEMPTED_FILE" ]]; then
  touch "$RESTART_ATTEMPTED_FILE"
  if docker restart "$CONTAINER" >> "$LOG_FILE" 2>&1; then
    log "Restarted $CONTAINER after: $reason"
    slack_post ":warning: Restart command completed for $CONTAINER. The watchdog will confirm recovery on the next check."
  else
    log "Restart failed for $CONTAINER after: $reason"
    slack_post ":x: Automatic restart failed for $CONTAINER. Manual intervention is required. Cause: $reason"
  fi
fi

rm -f "$FAILURE_FILE"
