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

## Reviewed late text-handler update (October 20, 2026)

`update-late-h4031650.sh` is a separate late-installation path, not a bypass of
the fixed-height launcher's guard. It is restricted to the reviewed old binary
`903694262846d4badc8db8825d8c78b6a5ae80ab6e6f8849e205a2b760067072`
and candidate
`486e971ecf8321be52d5b34c568273b68e22b494ce1af3c91bb1d72e4ac15a83`.
The runtime diff registers a legacy signaling TextProposal handler; it adds no
store migration. Before stopping anything, the late path requires responsive,
fresh, caught-up mainnet state and matching canonical block/application hashes
at a common post-activation height. Unknown binaries and mismatched states are
refused, not reset or resynchronized automatically.

The current pinned public bundle is `validator-operator-late-h4031650-r2.tar.gz`, SHA-256
`ee00a1218c0b467467fd415de817fa51e4c5f6cc32dd0817c86eadbe970738d5`.
Revision 2 fixes Python <3.11 parsing of Comet RFC3339 nanosecond timestamps.
Jay's revision-1 failure occurred at the first read-only compatibility check,
before any validator stop or replacement. The exact reported timestamp
`2026-10-20T22:13:29.862499866Z` is covered by regression tests; all 14 gate
tests pass under Python 3.8 as well as the current runtime. No chain binary,
upgrade semantics, or freshness limits changed. The old immutable bundle
remains available for audit; use the revision-2 launcher commit for retries.
It uses the existing release's checksum-verified image. It retains node data,
keys and signing state in place, creates preflight/stopped safety backups,
retains the old container stopped with restart disabled, and never automatically
downgrades after starting the candidate. A systemd job survives SSH disconnect.
No funding, proposal, delegation or unjail transaction is submitted. Success
requires the new binary, fresh canonical-matching state, catch-up completed,
and the matching validator bonded and not jailed. A jailed or divergent node
still requires manual review. Re-running an already-updated healthy node only
verifies it; it does not replace or restart it.

Validation: 11 late compatibility checks, 9 legacy-wrapper tests, 8 fixed-height
tests, security guard/wrapper suites pass on Linux. The post-activation isolated
two-validator rehearsal upgraded the old binary at height 4,031,813 and returned
to canonical-matching state at 4,031,819; operator identity was preserved and the
validator remained bonded/not jailed. Download/checksum/systemd launcher and
already-updated rerun are tested separately. QA uses an internal Docker network
with no published ports, separate from the real testnet node.

Operators should send the final `LATE UPDATE VERIFIED` output to Blain; keep
mainnet proposal publishing on hold until all operator versions are confirmed.
