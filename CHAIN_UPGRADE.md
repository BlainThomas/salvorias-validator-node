# Salvorias Validator Chain Upgrade

This is the operator procedure for coordinated Salvorias mainnet upgrades. The
release announcement will provide either an immutable image digest or a public
release tarball with its SHA-256, plus the binary SHA-256 and upgrade height.
Do not substitute an unverified artifact.

## What the updater preserves

- The existing Docker volume or bind mount at `/home/evmos/.evmosd`.
- `priv_validator_key.json`, `node_key.json`, and `priv_validator_state.json`.
- The local validator account keyring.
- Existing node configuration, ports, command arguments, restart policy, and
  Docker log limits.
- The stopped old container until the network upgrade is validated.

The updater never runs node initialization, state sync reset, key import, or
data deletion.

## 1. Get the public operator package

Existing checkout:

```bash
cd ~/salvorias-validator-node
git pull --ff-only origin main
chmod +x scripts/*.sh
```

First-time checkout:

```bash
cd ~
git clone https://github.com/NodeSolutionsAI/salvorias-validator-node.git
cd salvorias-validator-node
chmod +x scripts/*.sh
```

## 2. Preflight before the upgrade height

The public GitHub Release tarball is the default distribution path. Replace all
four published placeholders exactly:

```bash
IMAGE='ghcr.io/nodesolutionsai/salvorias-validator-node:<VERSION>'
IMAGE_TARBALL_URL='<PUBLIC_RELEASE_TARBALL_URL>'
IMAGE_TARBALL_SHA256='<IMAGE_TARBALL_SHA256>'
BINARY_SHA256='<BINARY_SHA256>'
UPGRADE_HEIGHT='<UPGRADE_HEIGHT>'

sudo ./scripts/upgrade-validator.sh preflight \
  --image "$IMAGE" \
  --image-tarball-url "$IMAGE_TARBALL_URL" \
  --image-tarball-sha256 "$IMAGE_TARBALL_SHA256" \
  --binary-sha256 "$BINARY_SHA256"
```

If the published GHCR package is publicly readable, the announcement may
instead provide an `IMAGE@sha256:DIGEST` reference and omit both tarball flags.

Preflight is safe to run while the validator is active. It:

1. Detects `salvorias-validator` or `salvorias-droplet`.
2. Confirms the node is on `salvorias_7282-1`.
3. Confirms the validator home is on a persistent writable mount.
4. Pulls the exact image digest.
5. Verifies the `evmosd` binary checksum inside the image.
6. Records the consensus identity and key hashes.
7. Creates a restricted backup under
   `/var/backups/salvorias-validator/`.

The container is not stopped or replaced during preflight.

## 3. Apply at the announced halt

Wait until the operator announcement confirms that the upgrade height has
been reached. Then run:

```bash
sudo ./scripts/upgrade-validator.sh apply \
  --upgrade-height "$UPGRADE_HEIGHT" \
  --image "$IMAGE" \
  --image-tarball-url "$IMAGE_TARBALL_URL" \
  --image-tarball-sha256 "$IMAGE_TARBALL_SHA256" \
  --binary-sha256 "$BINARY_SHA256"
```

Apply repeats preflight, stops the old container, creates a final signing-state
backup, renames the stopped old container, and starts the new immutable image
against the same validator volume. It validates the chain ID, consensus
address, validator key hash, node key hash, and container stability. If those
checks fail, it automatically removes the replacement and restores the old
container.

It is normal for the height to remain at the upgrade height until validators
holding more than two-thirds of consensus power have installed the new image.

## 4. Verify after the network resumes

```bash
sudo ./scripts/upgrade-validator.sh verify

docker logs --tail 100 salvorias-validator 2>&1 | tail -100
```

For the original validator, substitute its container name when viewing logs:

```bash
docker logs --tail 100 salvorias-droplet 2>&1 | tail -100
```

Report the following to the operator team:

- Preflight passed
- Apply passed
- Validator consensus address
- Current height
- `catching_up` status
- Any error shown by the updater

## Rollback boundary

The old stopped container is retained as
`<container>-preupgrade-<UTC timestamp>`. Do not delete it or the safety backup
until the operator team confirms the network migration and post-upgrade tests
are complete.

Automatic rollback is safe before the upgraded network begins committing
post-migration blocks. After the network resumes on the new version, do not
manually start the old binary unless the operator team explicitly coordinates
a network-wide rollback.

## Never do these during an upgrade

- Do not run `onboard-validator.sh --force`.
- Do not run `reset-state-sync.sh`.
- Do not delete or recreate the Docker volume.
- Do not copy another validator's key files.
- Do not start both the old and new containers against the same validator
  volume.
- Do not use an unpinned `latest` image.
