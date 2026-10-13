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

The public GitHub Release tarball is the default distribution path. Copy the
image tag and checksums from the release manifest exactly; the image tag inside
the tarball is not necessarily a GHCR registry tag. Replace all published
placeholders exactly:

```bash
IMAGE='<IMAGE_TAG_FROM_RELEASE_MANIFEST>'
IMAGE_TARBALL_URL='<PUBLIC_RELEASE_TARBALL_URL>'
IMAGE_TARBALL_SHA256='<IMAGE_TARBALL_SHA256>'
BINARY_SHA256='<BINARY_SHA256>'
UPGRADE_HEIGHT='<UPGRADE_HEIGHT>'
UPGRADE_NAME='salvorias-security-v1.2.0'
MINIMUM_GAS_PRICES='1000000000SAVDR'

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
  --upgrade-name "$UPGRADE_NAME" \
  --upgrade-height "$UPGRADE_HEIGHT" \
  --minimum-gas-prices "$MINIMUM_GAS_PRICES" \
  --image "$IMAGE" \
  --image-tarball-url "$IMAGE_TARBALL_URL" \
  --image-tarball-sha256 "$IMAGE_TARBALL_SHA256" \
  --binary-sha256 "$BINARY_SHA256"
```

Apply repeats preflight, stops the old container, creates a final signing-state
backup, renames the stopped old container, and starts the new immutable image
against the same validator volume. It validates the chain ID, consensus
address, validator key hash, node key hash, and container stability. If the
replacement fails before it starts, the updater restores the old container.
If validation fails after the replacement starts, the updater stops it and
retains both containers for operator review. It does not automatically start
the old binary against potentially migrated state.

The published minimum gas price is applied only to the replacement container.
The retained rollback container keeps its original command unchanged.

If the old binary has already halted and its RPC is unavailable, apply verifies
that `data/upgrade-info.json` exactly matches the published upgrade name and
height, then reads the chain ID, consensus identity, and last signed height
directly from the protected validator files. It will not replace a halted node
for a different or missing upgrade plan.

If RPC is still live, normal apply instead verifies that the chain's scheduled
upgrade plan has that same name and height. It will not replace a live node
merely because a height was supplied on the command line.

It is normal for the height to remain at the upgrade height until validators
holding more than two-thirds of consensus power have installed the new image.

### Coordinated hard-fork activation

If the release announcement explicitly identifies a coordinated hard fork,
apply the new binary during the final 1,000 blocks before its activation height:

```bash
sudo ./scripts/upgrade-validator.sh apply \
  --coordinated-hardfork \
  --upgrade-name "$UPGRADE_NAME" \
  --upgrade-height "$UPGRADE_HEIGHT" \
  --minimum-gas-prices "$MINIMUM_GAS_PRICES" \
  --image "$IMAGE" \
  --image-tarball-url "$IMAGE_TARBALL_URL" \
  --image-tarball-sha256 "$IMAGE_TARBALL_SHA256" \
  --binary-sha256 "$BINARY_SHA256"
```

This mode requires the old validator to be live and current. It refuses to run
more than 1,000 blocks early or at/after activation. The policy transition remains
dormant in the new binary until the exact activation height.

### Upgrade public RPC relays before activation

Any non-validator node that accepts `eth_sendRawTransaction` must run the same
policy binary before the activation height. Transaction admission (`CheckTx`) is
performed by the RPC node before a transaction is relayed to validators. An old
read-RPC binary can therefore reject a transaction that the upgraded validator
set would accept, even though the read node does not participate in consensus.

For each public or internal broadcast RPC:

1. Load and checksum-verify the same pinned release artifact.
2. Preserve its existing data volume, command arguments, ports, and recovery
   watchdog configuration.
3. Replace the container with the new image and retain the stopped old container
   as rollback.
4. Verify it is healthy, not catching up, and matches the canonical block hash.
5. Send the post-activation transaction through the public endpoint itself; a
   direct validator-RPC test does not validate the production broadcast path.

### Validator missed the coordinated activation

If a validator did not install the release before activation, stop it and wait
until a trusted canonical RPC has passed the activation height. Then use the
same pinned release values with the explicit recovery guard:

```bash
sudo ./scripts/upgrade-validator.sh apply \
  --post-hardfork-recovery \
  --trusted-rpc http://134.199.216.166:26660 \
  --upgrade-name "$UPGRADE_NAME" \
  --upgrade-height "$UPGRADE_HEIGHT" \
  --minimum-gas-prices "$MINIMUM_GAS_PRICES" \
  --image "$IMAGE" \
  --image-tarball-url "$IMAGE_TARBALL_URL" \
  --image-tarball-sha256 "$IMAGE_TARBALL_SHA256" \
  --binary-sha256 "$BINARY_SHA256"
```

This mode remains fail-closed until the trusted RPC reports the expected chain
at or above the activation height. It preserves the validator keys, signing
state, configuration, and local block data, then starts the new binary so a
minority node halted at the fork boundary can replay and catch up normally.
It does not erase chain data or reset the validator signing height.

If the node committed blocks on a genuinely divergent fork, stop it and
escalate to the operator team. Do not use `unsafe-reset-all` or reset
`priv_validator_state.json`; a divergent signer needs a separately verified
state-sync recovery that preserves its last signed height.

## 4. Verify after the network resumes

```bash
sudo ./scripts/upgrade-validator.sh verify

docker logs --tail 100 salvorias-validator 2>&1 | tail -100
```

Verify fails if RPC is unavailable or the latest block is more than three
minutes old; a current block with `catching_up=true` is reported as a warning
for the operator to investigate.

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

If replacement creation fails before the new binary starts, the script restores
the old container. Once the new binary has started, treat its volume as
potentially migrated even if RPC never became healthy. Do not manually start
the old binary unless the operator team verifies the state and explicitly
coordinates a rollback. After the network resumes on the new version, any
rollback must be network-wide.

## Never do these during an upgrade

- Do not run `onboard-validator.sh --force`.
- Do not run `reset-state-sync.sh`.
- Do not delete or recreate the Docker volume.
- Do not copy another validator's key files.
- Do not start both the old and new containers against the same validator
  volume.
- Do not use an unpinned `latest` image.
