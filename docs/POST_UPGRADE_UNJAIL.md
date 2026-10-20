# Optional post-upgrade unjail

Status: integrated in the H4031650 launcher. Isolated two-validator rehearsals
on 2026-10-20 verified the public download/checksum path, exact old-to-new height
handoff, a healthy validator requiring no transaction, and a delayed jailed
validator catching up and successfully unjailing with its disposable QA key.
The final public launcher also recognizes systemd's `activating` state so an
overnight oneshot job cannot accidentally be launched twice. Guard tests cover
active/activating jobs, wrong binary/chain/identity/height, and catch-up.

`scripts/post-upgrade-unjail.py` is an optional completion step AFTER a successful
coordinated upgrade. It does not install a binary, restart a node, change signing
state, restore backups, transfer funds, or make an old binary safe to run.

The release launcher must supply the verified container, binary SHA-256,
activation height and expected operator address. A node using an external signer
or without its operator account in the existing test keyring needs manual signing;
the helper never imports/exports keys or asks for secrets.

Checks-only is the default. `--submit` explicitly authorizes at most one unjail
transaction. It waits up to 600 seconds for catch-up, verifies chain, binary,
activation height and fresh blocks, matches the on-chain consensus key, checks
tombstoning and jail expiry against chain time, verifies operator-key ownership
and minimum self-delegation, and checks spendable funds and the live fee floor.
The default maximum fee is 0.001 SAVDR (10^15 base units); no automatic funding
or fee-cap increase occurs. No transaction is sent if already unjailed.

A persistent attempt marker is written before broadcast. A timeout or error is
not grounds to resubmit. Inspect the saved transaction hash and chain state under
`/var/lib/salvorias-operator/` before manually reconciling an attempt. Do not delete
the marker merely to retry. After one accepted broadcast, the helper polls for
inclusion and confirms the jailed flag clears. This does not guarantee bonded
status or successful signing; monitor those separately.

Dependencies: Python 3 on Linux, Docker, standard validator evmosd CLI with local
RPC available. The helper is intended to run under the operator's privileged
release process. It uses a container-specific lock and restrictive state directory.

The activation height is 4,031,650, estimated October 20, 2026, 11:00 MDT
(17:00 UTC); wall-clock timing is approximate. Late operators must keep old binaries
stopped until upgraded. Zero downtime slashing does not disable jail or double-sign
penalties. Do not reuse the prior H3900000 update command.

The successful late rehearsal started from a node halted at H-1. A node that
was never staged and has executed old code past the boundary is refused and
requires operator-led recovery. Never reset or rewind signing state.
