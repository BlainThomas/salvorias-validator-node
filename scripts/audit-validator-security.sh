#!/usr/bin/env bash
set -euo pipefail

container="${CONTAINER_NAME:-salvorias-validator}"
home_dir="${HOME_DIR:-/home/evmos/.evmosd}"
failures=0
warnings=0

fail() { printf 'FAIL: %s\n' "$1" >&2; failures=$((failures + 1)); }
warn() { printf 'WARN: %s\n' "$1" >&2; warnings=$((warnings + 1)); }
pass() { printf 'PASS: %s\n' "$1"; }

if ! docker inspect "$container" >/dev/null 2>&1; then
  echo "Validator container not found: $container" >&2
  exit 2
fi

bindings="$(docker inspect "$container" --format '{{json .HostConfig.PortBindings}}')"
for port in 26657/tcp 1317/tcp 8545/tcp 8546/tcp 9090/tcp; do
  hosts="$(printf '%s' "$bindings" | jq -r --arg port "$port" '.[$port][]?.HostIp')"
  if [[ -z "$hosts" ]]; then
    pass "$port is not published on the host"
    continue
  fi
  while IFS= read -r host; do
    case "$host" in
      127.0.0.1|::1) pass "$port is loopback-only ($host)" ;;
      *) fail "$port is published on a non-loopback address (${host:-all interfaces})" ;;
    esac
  done <<< "$hosts"
done

app_toml="$(docker exec "$container" sh -lc "cat '$home_dir/config/app.toml'")"
json_rpc="$(printf '%s\n' "$app_toml" | awk '
  /^\[json-rpc\]$/ { active=1; next }
  /^\[/ { active=0 }
  active { print }
')"

if grep -qx 'allow-insecure-unlock = false' <<< "$json_rpc"; then
  pass 'insecure account unlocking is disabled'
else
  fail 'allow-insecure-unlock is not explicitly false'
fi

if grep -qx 'api = "eth,net,web3"' <<< "$json_rpc"; then
  pass 'JSON-RPC namespace allowlist excludes personal and debug'
else
  fail 'JSON-RPC namespace allowlist is not exactly eth,net,web3'
fi

if docker exec "$container" evmosd keys show validator \
  --keyring-backend test --home "$home_dir" >/dev/null 2>&1; then
  warn 'validator transaction key is present in keyring-test; plan migration to an offline or hardware-backed signer'
else
  pass 'default validator transaction key is not present in keyring-test'
fi

printf '\nAudit result: %d failure(s), %d warning(s).\n' "$failures" "$warnings"
(( failures == 0 ))
