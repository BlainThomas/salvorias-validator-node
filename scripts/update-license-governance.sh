#!/usr/bin/env bash
# Unarmed release entrypoint. Fill pins ONLY after final manifest/image QA.
set -euo pipefail
main() {
  local height=0 url='' manifest_sha='' operator_archive='' operator_sha=''
  [[ "$height" -gt 0 && "$url" == https://* && "$manifest_sha" =~ ^[a-f0-9]{64}$ && "$operator_sha" =~ ^[a-f0-9]{64}$ && "$operator_archive" =~ ^[A-Za-z0-9._-]+[.]tar[.]gz$ ]] || {
    echo 'License-governance release is not armed. No validator settings changed. Wait for the final command from Blain.' >&2; return 1;
  }
  [[ $(id -u) == 0 ]] || { echo 'Run with sudo.' >&2; return 1; }
  for tool in curl sha256sum tar systemctl docker jq flock python3; do
    command -v "$tool" >/dev/null || { echo "Missing $tool; contact Blain." >&2; return 1; }
  done
  [[ $(uname -m) == x86_64 ]] || { echo 'Only the tested amd64 release is supported by this entrypoint.' >&2; return 1; }
  local c="${CONTAINER_NAME:-}"
  if [[ -z "$c" ]]; then
    for candidate in salvorias-validator salvorias-droplet salvorias-rpc-node; do
      if docker container inspect "$candidate" >/dev/null 2>&1; then c="$candidate"; break; fi
    done
  fi
  [[ "$c" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || { echo 'Missing or invalid container; contact Blain.' >&2; return 1; }
  local unit="salvorias-license-governance-h$height" root="/var/lib/salvorias-upgrades/license-h$height"
  exec 8>"/run/lock/$unit-launcher.lock"
  flock -n 8 || { echo 'Another launcher is running.' >&2; return 1; }
  if [[ "$(systemctl show "$unit" -p ActiveState --value)" =~ ^(active|activating|reloading)$ ]]; then
    echo "Already staged: sudo journalctl -fu $unit"; return 0
  fi
  local status current
  status=$(docker exec "$c" curl -fsS --max-time 10 http://127.0.0.1:26657/status)
  jq -e '.result.node_info.network == "salvorias_7282-1" and .result.sync_info.catching_up == false' <<<"$status" >/dev/null || { echo 'Wrong chain or still syncing.' >&2; return 1; }
  current=$(docker exec "$c" curl -fsS --max-time 10 http://127.0.0.1:26657/abci_info | jq -er '.result.response.last_block_height|tonumber')
  (( current < height )) || { echo 'Past activation. Do not reset or restore signing state; contact Blain.' >&2; return 1; }
  umask 077
  install -d -m 0700 "$root"
  curl -fL --retry 3 "$url/$operator_archive" -o "$root/operator.tar.gz"
  printf '%s  %s\n' "$operator_sha" "$root/operator.tar.gz" | sha256sum -c -
  tar -xzf "$root/operator.tar.gz" -C "$root"
  if [[ "$c" == salvorias-rpc-node ]]; then
    install -m 0755 "$root/scripts/read-rpc-license-guard.sh" /usr/local/bin/salvorias-rpc-license-guard.sh
    install -m 0755 "$root/scripts/read-rpc-h4031650-guard.sh" /usr/local/bin/salvorias-rpc-h4031650-guard.sh
    /usr/local/bin/salvorias-rpc-license-guard.sh --check-installed
  fi
  cat >"/etc/systemd/system/$unit.service" <<EOF
[Unit]
Description=Salvorias license governance handoff at $height
After=docker.service network-online.target
Wants=network-online.target
Requires=docker.service
ConditionPathExists=!$root/completed
[Service]
Type=oneshot
TimeoutStartSec=infinity
Restart=no
Environment=CONTAINER_NAME=$c
ExecStart=$root/scripts/run-license-governance-upgrade.sh apply --manifest-url $url/license-governance-release.json --manifest-sha256 $manifest_sha --upgrade-height $height --yes
ExecStartPost=$root/scripts/run-license-governance-upgrade.sh verify --manifest-url $url/license-governance-release.json --manifest-sha256 $manifest_sha
ExecStartPost=/usr/bin/touch $root/completed
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable "$unit.service" >/dev/null
  systemctl start --no-block "$unit.service"
  echo "Staging started: sudo journalctl -fu $unit"
  echo 'The current binary stays running until the coordinated boundary. Never restore old signing state.'
}
main "$@"
