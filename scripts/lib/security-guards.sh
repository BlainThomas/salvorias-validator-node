#!/usr/bin/env bash

is_loopback_bind() {
  case "$1" in
    127.0.0.1|localhost|::1|\[::1\]) return 0 ;;
    *) return 1 ;;
  esac
}

is_immutable_image() {
  [[ "$1" =~ @sha256:[0-9a-fA-F]{64}$ ]]
}

validate_onboarding_security_inputs() {
  local image="$1"
  local bind_address="$2"
  local tarball_url="$3"
  local tarball_sha256="$4"

  if [[ -z "$image" ]]; then
    echo "--image is required and must use an immutable @sha256 digest." >&2
    return 1
  fi

  if ! is_immutable_image "$image"; then
    echo "Refusing mutable validator image '$image'. Use IMAGE@sha256:DIGEST." >&2
    return 1
  fi

  if ! is_loopback_bind "$bind_address"; then
    echo "Refusing non-loopback HOST_LOCAL_BIND '$bind_address'. Only P2P may be public." >&2
    return 1
  fi

  if [[ -n "$tarball_url" && ! "$tarball_sha256" =~ ^[0-9a-fA-F]{64}$ ]]; then
    echo "IMAGE_TARBALL_SHA256 is required when IMAGE_TARBALL_URL is set." >&2
    return 1
  fi

  if [[ -z "$tarball_url" && -n "$tarball_sha256" ]]; then
    echo "IMAGE_TARBALL_URL is required when IMAGE_TARBALL_SHA256 is set." >&2
    return 1
  fi
}

verify_sha256() {
  local file="$1"
  local expected="${2,,}"
  local actual

  if command -v sha256sum >/dev/null 2>&1; then
    actual="$(sha256sum "$file" | awk '{print tolower($1)}')"
  elif command -v shasum >/dev/null 2>&1; then
    actual="$(shasum -a 256 "$file" | awk '{print tolower($1)}')"
  else
    echo "sha256sum or shasum is required to verify the release tarball." >&2
    return 1
  fi

  if [[ "$actual" != "$expected" ]]; then
    echo "Release tarball SHA-256 mismatch: expected $expected, got $actual" >&2
    return 1
  fi
}
