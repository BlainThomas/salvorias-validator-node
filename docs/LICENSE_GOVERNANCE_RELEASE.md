# License-governance release preparation

Status: **not armed**. No mainnet validator was changed by preparing these files.
Do not reuse H4031650, its artifacts or its late-update mode for this release.

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

Release manifest schema (not an armed release):

```json
{
  "release_ready": false,
  "chain_id": "salvorias_7282-1",
  "upgrade_name": "salvorias-license-governance-v1.3.0",
  "activation_height": null,
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
