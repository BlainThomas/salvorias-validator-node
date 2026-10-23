#!/usr/bin/env bash
# Reviewed release manifest only; never substitute the disabled staging binary.
set -euo pipefail
mode="${1:-}"
[[ $# == 0 ]] || shift
manifest_url= manifest_sha256= upgrade_height=
confirmed=false
unjail_if_needed=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --manifest-url) manifest_url="$2"; shift 2 ;;
    --manifest-sha256) manifest_sha256="$2"; shift 2 ;;
    --upgrade-height) upgrade_height="$2"; shift 2 ;;
    --yes) confirmed=true; shift ;;
    --unjail-if-needed) unjail_if_needed=true; shift ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done
dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ "$mode" == preflight || "$mode" == apply || "$mode" == verify ]] || { echo 'Use preflight, apply or verify.' >&2; exit 1; }
[[ "$manifest_url" == https://* && "$manifest_sha256" =~ ^[a-fA-F0-9]{64}$ ]] || {
  echo 'A published HTTPS manifest and its SHA-256 are required.' >&2; exit 1;
}
if [[ "$mode" == apply ]]; then
  [[ "$confirmed" == true && "$upgrade_height" =~ ^[0-9]+$ && "$upgrade_height" -gt 0 ]] || {
    echo 'Apply requires --yes and the published positive --upgrade-height.' >&2; exit 1;
  }
fi
for tool in curl jq sha256sum uname; do command -v "$tool" >/dev/null || exit 1; done
manifest="$(mktemp -t salvorias-license-manifest.XXXXXX.json)"
trap 'rm -f "$manifest"' EXIT
curl -fL --retry 3 --retry-delay 2 "$manifest_url" -o "$manifest"
actual="$(sha256sum "$manifest" | awk '{print $1}')"
[[ "${actual,,}" == "${manifest_sha256,,}" ]] || { echo 'Manifest checksum mismatch.' >&2; exit 1; }
jq -e '
  .release_ready == true and .chain_id == "salvorias_7282-1" and
  .upgrade_name == "salvorias-license-governance-v1.3.0" and
  .governance.node_license_weight == 1 and .governance.validator_license_weight == 10 and
  .governance.voting_period_seconds == 604800 and
  .governance.proposal_26.voting_end == "2026-10-27T23:10:18.793614692Z" and
  .governance.proposal_26.ownership_manifest_sha256 == "48e897e20294f430b074faf4726569d7660bd13266e4d8ae4fc7c778072a80c6"
' "$manifest" >/dev/null || { echo 'Unarmed or incompatible Charter release manifest.' >&2; exit 1; }
height="$(jq -er '.activation_height | numbers' "$manifest")"
[[ "$height" =~ ^[0-9]+$ && "$height" -gt 0 ]] || { echo 'Missing fixed activation height.' >&2; exit 1; }
[[ "$mode" != apply || "$upgrade_height" == "$height" ]] || { echo 'Requested height differs from manifest.' >&2; exit 1; }
case "$(uname -m)" in
  x86_64|amd64) arch=amd64 ;;
  aarch64|arm64) arch=arm64 ;;
  *) echo 'Unsupported validator architecture.' >&2; exit 1 ;;
esac
image="$(jq -er --arg arch "$arch" '.platforms[$arch].image | strings | select(length > 0)' "$manifest")"
archive="$(jq -er --arg arch "$arch" '.platforms[$arch].archive' "$manifest")"
archive_hash="$(jq -er --arg arch "$arch" '.platforms[$arch].archive_sha256' "$manifest")"
binary_hash="$(jq -er --arg arch "$arch" '.platforms[$arch].binary_sha256' "$manifest")"
[[ "$archive" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*[.]tar[.]gz$ && "$archive_hash" =~ ^[a-fA-F0-9]{64}$ && "$binary_hash" =~ ^[a-fA-F0-9]{64}$ ]] || {
  echo 'Invalid release artifact names or checksums.' >&2; exit 1;
}
args=("$mode" --harden-rpc --image "$image" --image-tarball-url "${manifest_url%/*}/$archive"
      --image-tarball-sha256 "$archive_hash" --binary-sha256 "$binary_hash")
if [[ "$mode" == apply ]]; then
  args+=(--fixed-height --upgrade-name salvorias-license-governance-v1.3.0
         --upgrade-height "$height" --minimum-gas-prices 1000000000SAVDR)
fi
if [[ "$mode" == verify ]]; then args+=(--upgrade-height "$height"); fi
# A repeat of the same operator command must not replace an already updated node.
# Never skip the ordinary handoff for an old or unknown binary.
already_updated=false
if [[ "$mode" == apply && -n "${CONTAINER_NAME:-}" ]]; then
  running_hash=$(docker exec "$CONTAINER_NAME" sha256sum /usr/bin/evmosd 2>/dev/null | awk '{print $1}') || running_hash=
  [[ "$running_hash" != "$binary_hash" ]] || already_updated=true
fi
if [[ "$already_updated" == false ]]; then
  "$dir/upgrade-validator.sh" "${args[@]}"
fi
if [[ "$mode" == apply && "$unjail_if_needed" == true ]]; then
  "$dir/finish-license-upgrade.sh" "$binary_hash" "$height"
fi
