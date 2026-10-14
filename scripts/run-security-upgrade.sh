#!/usr/bin/env bash
set -euo pipefail

mode="${1:-}"
if [[ -n "$mode" ]]; then shift; fi

manifest_url=""
manifest_sha256=""
upgrade_height=""
minimum_gas_prices="1000000000SAVDR"
confirmed=false

usage() {
  cat <<'EOF'
Usage:
  sudo ./scripts/run-security-upgrade.sh preflight --manifest-url URL --manifest-sha256 SHA256
  sudo ./scripts/run-security-upgrade.sh apply --manifest-url URL --manifest-sha256 SHA256 --upgrade-height HEIGHT --yes
  sudo ./scripts/run-security-upgrade.sh verify

The manifest checksum and upgrade height must come from the signed operator
announcement. Apply is fail-closed without --yes and always enables validator
RPC hardening. Apply may be started before activation: it keeps the old binary
running with an exact halt guard until the release height, then replaces it.
Run in a persistent root terminal session; no automatic downgrade is permitted.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --manifest-url) manifest_url="$2"; shift 2 ;;
    --manifest-sha256) manifest_sha256="$2"; shift 2 ;;
    --upgrade-height) upgrade_height="$2"; shift 2 ;;
    --minimum-gas-prices) minimum_gas_prices="$2"; shift 2 ;;
    --yes) confirmed=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
updater="$script_dir/upgrade-validator.sh"

if [[ "$mode" == "verify" ]]; then
  exec "$updater" verify
fi
if [[ "$mode" != "preflight" && "$mode" != "apply" ]]; then
  usage
  exit 1
fi
if [[ ! "$manifest_url" =~ ^https:// ]]; then
  echo "--manifest-url must use HTTPS." >&2
  exit 1
fi
if [[ ! "$manifest_sha256" =~ ^[0-9a-fA-F]{64}$ ]]; then
  echo "--manifest-sha256 must be a 64-character SHA-256 value." >&2
  exit 1
fi
if [[ "$mode" == "apply" ]]; then
  if [[ "$confirmed" != "true" ]]; then
    echo "Apply requires --yes after the announced height and manifest are verified." >&2
    exit 1
  fi
  if [[ ! "$upgrade_height" =~ ^[0-9]+$ || "$upgrade_height" -lt 1 ]]; then
    echo "Apply requires --upgrade-height HEIGHT." >&2
    exit 1
  fi
fi

for command in curl jq sha256sum uname; do
  command -v "$command" >/dev/null 2>&1 || { echo "Missing required command: $command" >&2; exit 1; }
done

manifest="$(mktemp -t salvorias-security-manifest.XXXXXX.json)"
trap 'rm -f "$manifest"' EXIT
curl -fL --retry 3 --retry-delay 2 -o "$manifest" "$manifest_url"
actual_manifest_sha256="$(sha256sum "$manifest" | awk '{print $1}')"
if [[ "${actual_manifest_sha256,,}" != "${manifest_sha256,,}" ]]; then
  echo "Release manifest checksum mismatch." >&2
  exit 1
fi

case "$(uname -m)" in
  x86_64|amd64) arch=amd64 ;;
  aarch64|arm64) arch=arm64 ;;
  *) echo "Unsupported validator architecture: $(uname -m)" >&2; exit 1 ;;
esac

upgrade_name="$(jq -er '.upgrade_name' "$manifest")"
manifest_height="$(jq -er '.activation_height | numbers' "$manifest")"
if [[ ! "$manifest_height" =~ ^[0-9]+$ || "$manifest_height" -lt 1 ]]; then
  echo "Manifest must contain a positive fixed activation height." >&2
  exit 1
fi
if [[ "$mode" == "apply" && "$upgrade_height" != "$manifest_height" ]]; then
  echo "Requested height does not match the checksum-pinned release manifest." >&2
  exit 1
fi
image="$(jq -er --arg arch "$arch" '.platforms[$arch].image' "$manifest")"
archive="$(jq -er --arg arch "$arch" '.platforms[$arch].archive' "$manifest")"
archive_sha256="$(jq -er --arg arch "$arch" '.platforms[$arch].archive_sha256' "$manifest")"
binary_sha256="$(jq -er --arg arch "$arch" '.platforms[$arch].binary_sha256' "$manifest")"

if [[ "$upgrade_name" != "salvorias-security-v1.2.0" ]]; then
  echo "Unexpected upgrade name in manifest: $upgrade_name" >&2
  exit 1
fi
if [[ ! "$archive_sha256" =~ ^[0-9a-fA-F]{64}$ || ! "$binary_sha256" =~ ^[0-9a-fA-F]{64}$ ]]; then
  echo "Manifest contains an invalid artifact checksum." >&2
  exit 1
fi
archive_url="${manifest_url%/*}/$archive"

args=(
  "$mode"
  --harden-rpc
  --image "$image"
  --image-tarball-url "$archive_url"
  --image-tarball-sha256 "$archive_sha256"
  --binary-sha256 "$binary_sha256"
)
if [[ "$mode" == "apply" ]]; then
  args+=(
    --fixed-height
    --upgrade-name "$upgrade_name"
    --upgrade-height "$upgrade_height"
    --minimum-gas-prices "$minimum_gas_prices"
  )
fi

exec "$updater" "${args[@]}"
