#!/usr/bin/env bash
# Late, state-preserving update for the approved legacy-text handler only.
set -euo pipefail
main() {
  [[ $(id -u) == 0 && $(uname -m) == x86_64 ]] || { echo 'Requires sudo on x86_64.'; return 1; }
  for tool in curl docker jq python3 systemctl tar sha256sum flock; do command -v "$tool" >/dev/null; done
  local c="${CONTAINER_NAME:-}" unit=salvorias-late-text-h4031650
  local root=/var/lib/salvorias-upgrades/late-h4031650
  if [[ -z "$c" ]]; then
    local found=()
    for candidate in salvorias-validator salvorias-droplet; do
      if docker container inspect "$candidate" >/dev/null 2>&1; then found+=("$candidate"); fi
    done
    [[ ${#found[@]} == 1 ]] || { echo 'Cannot uniquely identify validator; contact Blain.'; return 1; }
    c="${found[0]}"
  fi
  [[ "$c" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ && "$c" != salvorias-rpc-node ]] || return 1
  local backup=/var/backups/salvorias-validator extra=""
  if [[ "$c" == salvorias-qa-* ]]; then
    unit="salvorias-late-text-$c"
    root="/var/lib/salvorias-qa-upgrades/late-$c"
    backup="/var/backups/$c"
    [[ "${QA_TRUSTED_RPC:-}" =~ ^http://172\.30\.94\.2:26657$ ]] || return 1
    extra="Environment=QA_TRUSTED_RPC=$QA_TRUSTED_RPC"
  fi
  exec 8>"/run/lock/$unit-launcher.lock"
  flock -n 8 || { echo 'Another launcher is running.'; return 1; }
  for existing in "$unit" salvorias-legacy-h4031650; do
    if [[ "$(systemctl show "$existing" -p ActiveState --value)" =~ ^(active|activating|reloading)$ ]]; then
      echo "An upgrade is already running. Check: sudo journalctl -u $existing -n 40 --no-pager"; return 1
    fi
  done
  umask 077
  install -d -m 0700 "$root"
  local url=https://github.com/BlainThomas/salvorias-validator-node/releases/download/legacy-text-h4031650
  curl -fL --retry 3 "$url/validator-operator-late-h4031650-r2.tar.gz" -o "$root/operator.tar.gz"
  printf '%s  %s\n' ee00a1218c0b467467fd415de817fa51e4c5f6cc32dd0817c86eadbe970738d5 "$root/operator.tar.gz" | sha256sum -c -
  tar -xzf "$root/operator.tar.gz" -C "$root"
  cat >"/etc/systemd/system/$unit.service" <<EOF
[Unit]
Description=Verified late Salvorias text-handler update
After=docker.service network-online.target
Requires=docker.service
[Service]
Type=oneshot
TimeoutStartSec=1800
Restart=no
Environment=CONTAINER_NAME=$c
Environment=BACKUP_ROOT=$backup
$extra
ExecStart=$root/scripts/run-late-text-upgrade.sh
EOF
  systemctl daemon-reload
  systemctl start --no-block "$unit"
  echo "Update running independently of this terminal. Please wait. Logs: sudo journalctl -fu $unit"
  sleep 2
  while [[ "$(systemctl show "$unit" -p ActiveState --value)" == activating ]]; do sleep 3; done
  journalctl -u "$unit" -n 35 --no-pager -o cat
  [[ "$(systemctl show "$unit" -p Result --value)" == success ]] || {
    echo 'NOT VERIFIED. Send the output to Blain. Do not reset, restore, or start a retained old container.'; return 1;
  }
}
main "$@"
