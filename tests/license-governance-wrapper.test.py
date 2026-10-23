#!/usr/bin/env python3
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("fixed", Path(__file__).with_name("fixed-height-wrapper.test.py"))
fixed = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixed)


class LicenseManifestTests(fixed.ManifestTests):
    wrapper_name = "run-license-governance-upgrade.sh"
    upgrade_name = "salvorias-license-governance-v1.3.0"

    def setUp(self):
        super().setUp()
        self.manifest.update(release_ready=True, chain_id="salvorias_7282-1", governance={
            "node_license_weight": 1, "validator_license_weight": 10,
            "voting_period_seconds": 604800,
            "proposal_26": {"voting_end": "2026-10-27T23:10:18.793614692Z", "ownership_manifest_sha256": "48e897e20294f430b074faf4726569d7660bd13266e4d8ae4fc7c778072a80c6"},
        })

    def test_incompatible_release_is_rejected(self):
        for field, value in [("release_ready", False), ("chain_id", "salvorias_7283-1"), ("upgrade_name", "salvorias-legacy-text-v1.2.1")]:
            with self.subTest(field=field):
                old = self.manifest[field]
                self.manifest[field] = value
                self.assertNotEqual(self.run_wrapper().returncode, 0)
                self.manifest[field] = old

    def test_charter_and_historical_pins_are_enforced(self):
        changes = [("node_license_weight", 2), ("validator_license_weight", 1), ("voting_period_seconds", 300)]
        for field, value in changes:
            with self.subTest(field=field):
                old = self.manifest["governance"][field]
                self.manifest["governance"][field] = value
                self.assertNotEqual(self.run_wrapper().returncode, 0)
                self.manifest["governance"][field] = old
        for field, value in [("ownership_manifest_sha256", "missing"), ("ownership_manifest_sha256", "c" * 64), ("voting_end", "2026-10-28T00:00:00Z")]:
            with self.subTest(field=field):
                old = self.manifest["governance"]["proposal_26"][field]
                self.manifest["governance"]["proposal_26"][field] = value
                self.assertNotEqual(self.run_wrapper().returncode, 0)
                self.manifest["governance"]["proposal_26"][field] = old

    def test_verify_uses_release_checksum_and_height(self):
        result = self.run_wrapper(mode="verify")
        self.assertEqual(result.returncode, 0, result.stderr)
        args = json.loads(result.stdout)
        self.assertEqual(args[0], "verify")
        self.assertEqual(args[args.index("--binary-sha256") + 1], "b" * 64)
        self.assertEqual(args[args.index("--upgrade-height") + 1], "3900000")

    def test_archive_path_traversal_is_rejected(self):
        for platform in self.manifest["platforms"].values():
            platform["archive"] = "../unreviewed.tar.gz"
        self.assertNotEqual(self.run_wrapper().returncode, 0)


class LicenseReadGuardTests(unittest.TestCase):
    def test_handoff_guard_only_releases_after_verified_commit(self):
        source = (Path(__file__).resolve().parents[1] / "scripts/read-rpc-license-guard.sh").read_text()
        with tempfile.TemporaryDirectory() as root:
            p = Path(root)
            marker = p / "pending.json"
            (p / "guard").write_text(source.replace("/var/lib/salvorias-rpc-watchdog/license-governance.pending.json", str(marker)))
            (p / "systemctl").write_text('#!/bin/sh\necho "$ACTIVE"\n')
            (p / "docker").write_text('''#!/bin/sh
case "$*" in
  *sha256sum*) echo "$HASH  evmosd" ;;
  *abci_info*) printf '{"result":{"response":{"last_block_height":"%s"}}}' "$HEIGHT" ;;
  *status*) printf '{"result":{"node_info":{"network":"%s"},"validator_info":{"address":"%s"},"sync_info":{"catching_up":%s}}}' "$CHAIN" "$IDENTITY" "$CATCHING" ;;
  *) exit 99 ;;
esac
''')
            for name in ["systemctl", "docker"]:
                (p / name).chmod(0o700)
            data = {"height": 4200000, "binary_sha256": "a" * 64, "validator_address": "B" * 40, "unit": "salvorias-license-governance-h4200000"}
            good = dict(os.environ, PATH=root + ":" + os.environ["PATH"], ACTIVE="inactive", HASH="a" * 64,
                        HEIGHT="4200000", CHAIN="salvorias_7282-1", IDENTITY="B" * 40, CATCHING="false")
            for change in [{"ACTIVE": "active"}, {"ACTIVE": "activating"}, {"HASH": "old"}, {"HEIGHT": "4199999"},
                           {"CHAIN": "wrong"}, {"IDENTITY": "C" * 40}, {"CATCHING": "true"}, {}]:
                with self.subTest(change=change):
                    marker.write_text(json.dumps(data))
                    result = subprocess.run(["bash", str(p / "guard")], env=dict(good, **change), capture_output=True)
                    self.assertEqual(result.returncode == 0, not bool(change), result.stderr)
                    self.assertEqual(marker.exists(), bool(change))
            self.assertEqual(0, subprocess.run(["bash", str(p / "guard")], env=good, capture_output=True).returncode)

    def test_launcher_is_not_armed_without_final_release_pins(self):
        source = Path(__file__).resolve().parents[1] / "scripts/update-license-governance.sh"
        result = subprocess.run(["bash", str(source)], capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("release is not armed", result.stderr)


class PinnedLiveVerificationTests(unittest.TestCase):
    def test_live_verify_requires_hash_height_sync_and_hardening(self):
        source = (Path(__file__).resolve().parents[1] / "scripts/upgrade-validator.sh").read_text()
        start = source.index('if [[ "$MODE" == "verify" ]]; then')
        block = source[start:source.index('  echo "Validator verification passed"', start)] + "fi\n"
        setup = '''
set -euo pipefail
MODE=verify
CONTAINER_NAME=qa-only
docker() { echo "$RUNNING_HASH  evmosd"; }
verify_rpc_hardening() { [[ "$HARDENED" == true ]]; }
'''
        good = dict(os.environ, BINARY_SHA256="a" * 64, RUNNING_HASH="a" * 64, CATCHING_UP="false",
                    UPGRADE_HEIGHT="4200000", APPLICATION_HEIGHT="4200000", HARDEN_RPC="true", HARDENED="true")
        for change in [{"RUNNING_HASH": "b" * 64}, {"BINARY_SHA256": "bad"}, {"CATCHING_UP": "true"},
                       {"APPLICATION_HEIGHT": "4199999"}, {"HARDENED": "false"}, {}]:
            with self.subTest(change=change):
                result = subprocess.run(["bash", "-c", setup + block], env=dict(good, **change), capture_output=True)
                self.assertEqual(result.returncode == 0, not bool(change), result.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
