#!/usr/bin/env bash
# Immutable operator launcher. Stage before H4031650; never reuse H3900000.
set -euo pipefail
main() {
  [[ $(id -u) == 0 ]] || { echo 'Run with sudo.' >&2; return 1; }
  for tool in curl sha256sum tar systemctl docker jq flock python3; do
    command -v "$tool" >/dev/null || { echo "Missing $tool; contact Blain." >&2; return 1; }
  done
  [[ $(uname -m) == x86_64 ]] || { echo 'This release is verified for x86_64 only.' >&2; return 1; }
  local c="${CONTAINER_NAME:-}" key="${OPERATOR_KEY_NAME:-validator}"
  local unit=salvorias-legacy-h4031650 root=/var/lib/salvorias-upgrades/h4031650
  if [[ -z "$c" ]]; then
    for candidate in salvorias-validator salvorias-droplet; do
      if docker container inspect "$candidate" >/dev/null 2>&1; then c="$candidate"; break; fi
    done
  fi
  [[ "$c" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ && "$key" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || {
    echo 'Invalid or missing container/key name.' >&2; return 1;
  }
  # Only disposable QA containers may override the service/root for rehearsal.
  if [[ "$c" == salvorias-qa-* ]]; then
    unit="salvorias-qa-legacy-$c"
    root="/var/lib/salvorias-qa-upgrades/$c-h4031650"
  fi
  exec 8>"/run/lock/$unit-launcher.lock"
  flock -n 8 || { echo 'Launcher already running.' >&2; return 1; }
  if systemctl is-active --quiet "$unit"; then
    echo "Already staged/running. Check: sudo journalctl -fu $unit"; return 0
  fi
  local status height
  status=$(docker exec "$c" curl -fsS --max-time 10 http://127.0.0.1:26657/status)
  jq -e '.result.node_info.network=="salvorias_7282-1" and .result.sync_info.catching_up==false' <<<"$status" >/dev/null || {
    echo 'Wrong chain or still catching up; contact Blain before staging.' >&2; return 1;
  }
  height=$(docker exec "$c" curl -fsS --max-time 10 http://127.0.0.1:26657/abci_info | jq -er '.result.response.last_block_height|tonumber')
  (( height < 4031650 )) || { echo 'Past the activation boundary. Do not reset or restore signing state; contact Blain.' >&2; return 1; }
  umask 077
  install -d -m 0700 "$root"
  local url=https://github.com/BlainThomas/salvorias-validator-node/releases/download/legacy-text-h4031650
  curl -fL --retry 3 "$url/validator-operator-h4031650.tar.gz" -o "$root/operator.tar.gz"
  printf '%s  %s\n' 4480f1aa2b4ebd089b8040f2afc89b84ba582583d1f303921b8ef8c628fa964b "$root/operator.tar.gz" | sha256sum -c -
  tar -xzf "$root/operator.tar.gz" -C "$root"
  local extra=--unjail-if-needed
  [[ "$c" != salvorias-rpc-node ]] || extra=
  local backup="/var/backups/salvorias-validator"
  [[ "$c" != salvorias-qa-* ]] || backup="/var/backups/$c"
  # Persistent service survives SSH disconnection and is retried on the next boot.
  # No restart loop: ambiguous failures remain stopped for operator investigation.
  cat >"/etc/systemd/system/$unit.service" <<EOF
[Unit]
Description=Salvorias legacy text upgrade at height 4031650
After=docker.service network-online.target
Wants=network-online.target
Requires=docker.service
ConditionPathExists=!$root/completed
[Service]
Type=oneshot
TimeoutStartSec=infinity
Restart=no
Environment=CONTAINER_NAME=$c
Environment=OPERATOR_KEY_NAME=$key
Environment=BACKUP_ROOT=$backup
ExecStart=$root/scripts/run-legacy-text-upgrade.sh apply --manifest-url $url/legacy-text-release.json --manifest-sha256 f55f432e064b0943e1e5f5ed9f24865f0c7a1e8ad7ab78df437d8163bac50966 --upgrade-height 4031650 --yes $extra
ExecStartPost=/usr/bin/touch $root/completed
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable "$unit.service" >/dev/null
  systemctl start --no-block "$unit.service"
  echo "Staging started, not yet confirmed: sudo journalctl -fu $unit"
  echo 'Current binary stays running until the coordinated handoff. Do not start a retained old container.'
  echo 'Contact Blain if the job fails. Never delete signing state or retry an uncertain unjail transaction.'
}
main "$@"
