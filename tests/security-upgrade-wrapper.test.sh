#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
wrapper="$repo_root/scripts/run-security-upgrade.sh"
updater="$repo_root/scripts/upgrade-validator.sh"
zeros="$(printf '0%.0s' {1..64})"

bash -n "$wrapper" "$updater"
echo 'PASS: upgrade scripts have valid shell syntax'

"$wrapper" preflight --help >/dev/null
echo 'PASS: wrapper help is available without changing a validator'

if "$wrapper" preflight --manifest-url http://example.invalid/release.json --manifest-sha256 "$zeros" >/dev/null 2>&1; then
  echo 'FAIL: insecure manifest URL was accepted' >&2
  exit 1
fi
echo 'PASS: wrapper rejects non-HTTPS manifests'

if "$wrapper" apply --manifest-url https://example.invalid/release.json --manifest-sha256 "$zeros" --upgrade-height 1 >/dev/null 2>&1; then
  echo 'FAIL: apply was accepted without explicit confirmation' >&2
  exit 1
fi
echo 'PASS: wrapper requires explicit apply confirmation'

grep -Fq -- '--harden-rpc' "$wrapper"
grep -Fq 'allow-insecure-unlock = false' "$updater"
grep -Fq 'api = "eth,net,web3"' "$updater"
echo 'PASS: security upgrade always enables RPC hardening'

echo 'All security-upgrade wrapper tests passed.'
