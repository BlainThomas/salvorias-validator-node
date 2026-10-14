# Validator deployment hardening

Status: local-only candidate. No validator has been changed by this branch.

The onboarding path now requires a digest-pinned container image, verifies the
checksum of any fallback binary, rejects non-loopback RPC publication, uses a
nonzero minimum gas price, disables insecure account unlock, and excludes the
`personal` and `debug` EVM namespaces.

`scripts/audit-validator-security.sh` is read-only. Run it on each validator to
identify public Docker ports, unsafe JSON-RPC settings, and operator keys left
in the node's test keyring. The consensus signing key is separate and is not
changed by this audit. Treat a finding as a review item; the script does
not modify configuration or restart a node.

Before rollout, test the candidate against a disposable validator, verify peer
and sentry connectivity, confirm signing continuity, and record the image
digest. Production changes should be applied one validator at a time only after
the coordinated chain upgrade plan is approved.
