# License-governance release preparation

Status: **activated, recovered and independently verified on all nine managed
signers**, October 23, 2026 around 17:48 UTC. The public read RPC is advancing
and the latest observed commit contained 11/11 signatures. Three waiting jobs
had failed before activation; those nodes required reviewed local state replay.
Do not describe the original staging check as proof of an uninterrupted rollout.
Do not reuse H4031650, its artifacts or its late-update mode for this release.

Selected target: H4,099,155, approximately October 23, 2026 at 11:00 MDT
(17:00 UTC), estimated from live H4,097,143 over the preceding 1,000 blocks.
The exact height controls activation, not wall-clock time. Final artifacts and
immutable launcher `f51cf40edb4a56931b96525ffb7087039eadb9c8` passed isolated
majority/delayed-validator handoff QA, including a confirmed eligible unjail.

The launcher requests conditional unjailing only for validator containers, never
the read RPC. Completion verifies the release binary, hardening, activation and
catch-up before using the existing bounded, journaled unjail helper. Healthy
validators send no transaction; tombstoned, underfunded or still-ineligible nodes
fail closed. Re-running on the correct binary avoids replacing it again.

Late recovery is NOT yet universally automatic: an old node that has committed
activation-height state cannot safely reuse the prior text-only late mode. The
current updater refuses that state instead of restoring signing state or
pretending a divergent database will catch up. A tested canonical resync path is
required before advertising this command as sufficient for every missed window.

The operator experience remains one immutable GitHub command, run as root:
`curl -fsSL <approved-commit-URL> | sudo bash`. The final URL must not be shared
until all of these pins exist and the command has been rehearsed end to end:

- The approved mainnet activation height and first affected proposal ID.
- Proposal 26's complete historical ownership manifest and SHA-256, with its
  original October 27 23:10:18.793614692 UTC voting end unchanged.
- The compiled binary/image checksums containing that exact activation policy.
- An anonymously downloadable release manifest, operator archive and image.

`run-license-governance-upgrade.sh` verifies manifest readiness, mainnet identity,
1/10 license weights, seven-day voting, proposal-26 pins, archive/binary checksums
and the exact height. Preflight does not stop the node. Apply uses the existing
fixed-height updater, retains keys/signing state and the old container, and keeps
the current binary running until the guarded handoff. It never silently
downgrades after the candidate starts or restores old signing state.

`update-license-governance.sh` is the single-command entrypoint template. It
currently refuses to run before touching the system. Final pins must replace
its empty constants, then the *exact* published command must be exercised on an
isolated validator before operators receive it. The persistent systemd unit
survives SSH disconnects and verifies the release hash/committed height before
marking completion. Late operators must contact Blain, not reuse old recovery.

For the read RPC, install the companion read guard/hook from the same verified
operator archive. Monitoring remains enabled; only restart recovery is held
while the unit is active or binary/height/identity checks are incomplete. The
existing watchdog resumes normal checks after the new state is verified.

Release manifest governance fields (platform checksums are in the published asset):

```json
{
  "release_ready": true,
  "chain_id": "salvorias_7282-1",
  "upgrade_name": "salvorias-license-governance-v1.3.0",
  "activation_height": 4099155,
  "governance": {
    "node_license_weight": 1,
    "validator_license_weight": 10,
    "voting_period_seconds": 604800,
    "proposal_26": {
      "voting_end": "2026-10-27T23:10:18.793614692Z",
      "ownership_manifest_sha256": "48e897e20294f430b074faf4726569d7660bd13266e4d8ae4fc7c778072a80c6"
    }
  },
  "platforms": {}
}
```

The disabled staging binary is **not** a deployable mainnet release. First
select the final activation policy (the historical snapshot is now pinned); rebuild, scan,
compare the release diff and rehearse the updater with the resulting pins.
