#!/usr/bin/env python3
import importlib.util
from pathlib import Path
import unittest
import subprocess

spec = importlib.util.spec_from_file_location("fixed", Path(__file__).with_name("fixed-height-wrapper.test.py"))
fixed = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixed)


class LegacyManifestTests(fixed.ManifestTests):
    wrapper_name = "run-legacy-text-upgrade.sh"
    upgrade_name = "salvorias-legacy-text-v1.2.1"

    def test_old_release_name_is_rejected(self):
        self.manifest["upgrade_name"] = "salvorias-security-v1.2.0"
        self.assertNotEqual(self.run_wrapper().returncode, 0)

    def test_architecture_without_artifact_is_rejected(self):
        self.manifest["platforms"] = {}
        self.assertNotEqual(self.run_wrapper().returncode, 0)


class StagingWaitTests(unittest.TestCase):
    def test_wait_keeps_services_untouched_and_rechecks_plan(self):
        source = (Path(__file__).resolve().parents[1] / "scripts/upgrade-validator.sh").read_text()
        start = source.index('if [[ "$FIXED_HEIGHT" == "true" && "$LIVE_STATUS_AVAILABLE" == "true" && "$LATE_TEXT" != true ]]; then\n  # Staging')
        block = source[start:source.index('watchdog_was_active=false', start)]
        setup = '''
set -euo pipefail
FIXED_HEIGHT=true
LATE_TEXT=false
LIVE_STATUS_AVAILABLE=true
APPLICATION_HEIGHT=4031500
UPGRADE_HEIGHT=4031650
CONTAINER_NAME=qa-only
BASE_VALIDATOR_ADDRESS=a
BASE_PRIVKEY_HASH=b
BASE_NODEKEY_HASH=c
sleep() { echo WAIT; }
read_identity() { APPLICATION_HEIGHT=4031550; VALIDATOR_ADDRESS=a; PRIVKEY_HASH=b; NODEKEY_HASH=c; }
docker() { [[ "$*" == 'exec qa-only evmosd query upgrade plan --output json' ]] || return 99; echo '{}'; }
systemctl() { echo UNEXPECTED_SERVICE_CHANGE; return 99; }
'''
        result = subprocess.run(["bash", "-c", setup + block], capture_output=True, text=True)
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn("WAIT", result.stdout)
        self.assertNotIn("UNEXPECTED_SERVICE_CHANGE", result.stdout)

if __name__ == "__main__":
    unittest.main(verbosity=2)
