#!/usr/bin/env bash
# Single-command operator entry point. Only run after the coordinated notice.
# Integrity pins deliberately remain inside this immutable GitHub script.
set -euo pipefail

main() {
  [[ "$(id -u)" == 0 ]] || { echo 'Run this command with sudo.' >&2; return 1; }
  local tool
  for tool in curl sha256sum tar mktemp systemd-run systemctl docker jq flock; do
    command -v "$tool" >/dev/null || { echo "Missing requirement: $tool. Contact the operator team." >&2; return 1; }
  done
  local unit=salvorias-security-h3900000
  if systemctl is-active --quiet "$unit"; then
    echo "Update already running. View progress: sudo journalctl -fu $unit"
    return 1
  fi
  local d u
  umask 077
  d="$(mktemp -d /var/tmp/salvorias-h3900000.XXXXXX)"
  u=https://github.com/BlainThomas/salvorias-validator-node/releases/download/security-h3900000
  echo 'Preparing Salvorias update for block 3,900,000. Your validator keys and signing state are preserved.'
  if ! curl -fL --retry 3 "$u/validator-operator-h3900000-0b86e18.tar.gz" -o "$d/operator.tar.gz"; then
    echo 'Release download failed. Nothing has been stopped or updated. Contact Blain before retrying.' >&2
    return 1
  fi
  printf '%s  %s\n' 18bdca35d8b2b95ed2e7db51476f1460a01692c6d39378a3c1f09b86b1ae7e98 "$d/operator.tar.gz" | sha256sum -c -
  tar -xzf "$d/operator.tar.gz" -C "$d"
  systemd-run --unit="$unit" --collect \
    "$d/scripts/run-security-upgrade.sh" apply \
    --manifest-url "$u/security-release.json" \
    --manifest-sha256 d2266771f3190ae19db791cc44f3161c918a3e2765af21b0ae4e91bd2dd6d2e9 \
    --upgrade-height 3900000 --yes
  echo 'Update job started in the background. This is not yet confirmation of completion.'
  echo 'It checks the release, makes backups, and switches versions at the coordinated height.'
  echo "View progress: sudo journalctl -fu $unit"
  echo 'You may disconnect SSH. Do not reboot or manually restart an old validator container.'
}

main "$@"
