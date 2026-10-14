#!/usr/bin/env bash
set -euo pipefail

SOURCE_IMAGE="${SOURCE_IMAGE:-salvorias-chain:savdr-prod-candidate}"
TARGET_IMAGE="${TARGET_IMAGE:-}"

if [[ -z "$TARGET_IMAGE" || "$TARGET_IMAGE" == *:latest ]]; then
  echo "Set TARGET_IMAGE to an explicit version tag; publishing latest is refused." >&2
  exit 1
fi

echo "Publishing validator image"
echo "  Source: $SOURCE_IMAGE"
echo "  Target: $TARGET_IMAGE"
echo

if ! docker image inspect "$SOURCE_IMAGE" >/dev/null 2>&1; then
  echo "Source image not found: $SOURCE_IMAGE" >&2
  exit 1
fi

docker tag "$SOURCE_IMAGE" "$TARGET_IMAGE"

if ! docker info 2>/dev/null | grep -q 'Username:'; then
  echo "If push fails with auth, login first:"
  echo "  gh auth token | docker login ghcr.io -u YOUR_GITHUB_USER --password-stdin"
  echo
fi

docker push "$TARGET_IMAGE"

echo
echo "Published $TARGET_IMAGE"
