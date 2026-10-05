#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/security-guards.sh
source "$repo_root/scripts/lib/security-guards.sh"

digest="$(printf 'a%.0s' {1..64})"
image="ghcr.io/nodesolutionsai/salvorias-validator-node@sha256:$digest"

expect_pass() {
  local name="$1"
  shift
  if "$@"; then
    printf 'PASS: %s\n' "$name"
  else
    printf 'FAIL: %s\n' "$name" >&2
    exit 1
  fi
}

expect_fail() {
  local name="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    printf 'FAIL: %s\n' "$name" >&2
    exit 1
  else
    printf 'PASS: %s\n' "$name"
  fi
}

expect_pass 'immutable digest and loopback bind are accepted' \
  validate_onboarding_security_inputs "$image" 127.0.0.1 '' ''
expect_fail 'latest tag is rejected' \
  validate_onboarding_security_inputs 'ghcr.io/nodesolutionsai/salvorias-validator-node:latest' 127.0.0.1 '' ''
expect_fail 'version tag without digest is rejected' \
  validate_onboarding_security_inputs 'ghcr.io/nodesolutionsai/salvorias-validator-node:v1.2.3' 127.0.0.1 '' ''
expect_fail 'public RPC bind is rejected' \
  validate_onboarding_security_inputs "$image" 0.0.0.0 '' ''
expect_fail 'unverified fallback tarball is rejected' \
  validate_onboarding_security_inputs "$image" 127.0.0.1 'https://example.invalid/image.tar.gz' ''
expect_pass 'verified fallback tarball is accepted' \
  validate_onboarding_security_inputs "$image" 127.0.0.1 'https://example.invalid/image.tar.gz' "$digest"

if grep -q -- '--minimum-gas-prices "0${DENOM}"' "$repo_root/scripts/onboard-validator.sh"; then
  echo 'FAIL: zero minimum gas price remains in onboarding command' >&2
  exit 1
fi
printf 'PASS: onboarding does not force a zero minimum gas price\n'

grep -Fq 'api = \"eth,net,web3\"' "$repo_root/scripts/onboard-validator.sh"
grep -Fq 'allow-insecure-unlock = false' "$repo_root/scripts/onboard-validator.sh"
printf 'PASS: onboarding explicitly removes signing-capable RPC namespaces\n'

printf '\nAll validator security guard tests passed.\n'
