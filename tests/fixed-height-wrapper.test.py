#!/usr/bin/env python3
"""Exercise manifest guards without contacting a server or invoking Docker."""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest


class ManifestTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        source = Path(__file__).resolve().parents[1] / "scripts/run-security-upgrade.sh"
        self.wrapper = self.root / "run-security-upgrade.sh"
        shutil.copy2(source, self.wrapper)
        updater = self.root / "upgrade-validator.sh"
        updater.write_text('#!/usr/bin/env python3\nimport json,sys\nprint(json.dumps(sys.argv[1:]))\n')
        updater.chmod(0o700)
        curl = self.bin / "curl"
        curl.write_text('#!/usr/bin/env python3\nimport os,shutil,sys\nshutil.copyfile(os.environ["FIXTURE"],sys.argv[sys.argv.index("-o")+1])\n')
        curl.chmod(0o700)
        self.manifest = {
            "upgrade_name": "salvorias-security-v1.2.0",
            "activation_height": 3900000,
            "platforms": {arch: {"image": "qa:candidate", "archive": "image.tar.gz", "archive_sha256": "a" * 64, "binary_sha256": "b" * 64} for arch in ("amd64", "arm64")},
        }

    def run_wrapper(self, height="3900000", mode="apply", checksum_ok=True):
        fixture = self.root / "manifest.json"
        fixture.write_text(json.dumps(self.manifest))
        digest = hashlib.sha256(fixture.read_bytes()).hexdigest() if checksum_ok else "0" * 64
        env = dict(os.environ, PATH=str(self.bin) + os.pathsep + os.environ["PATH"], FIXTURE=str(fixture))
        args = ["bash", str(self.wrapper), mode, "--manifest-url", "https://example.invalid/release.json", "--manifest-sha256", digest]
        if mode == "apply":
            args += ["--yes", "--upgrade-height", height]
        return subprocess.run(args, env=env, capture_output=True, text=True)

    def test_exact_height_selects_fixed_height_and_hardening(self):
        result = self.run_wrapper()
        self.assertEqual(result.returncode, 0, result.stderr)
        args = json.loads(result.stdout)
        self.assertIn("--fixed-height", args)
        self.assertIn("--harden-rpc", args)
        self.assertNotIn("--coordinated-hardfork", args)
        self.assertEqual(args[args.index("--upgrade-height") + 1], "3900000")

    def test_wrong_height_is_rejected(self):
        self.assertNotEqual(self.run_wrapper("3900001").returncode, 0)

    def test_missing_height_is_rejected(self):
        del self.manifest["activation_height"]
        self.assertNotEqual(self.run_wrapper().returncode, 0)

    def test_zero_height_is_rejected(self):
        self.manifest["activation_height"] = 0
        self.assertNotEqual(self.run_wrapper().returncode, 0)

    def test_checksum_is_enforced(self):
        self.assertNotEqual(self.run_wrapper(checksum_ok=False).returncode, 0)

    def test_preflight_does_not_apply(self):
        result = self.run_wrapper(mode="preflight")
        self.assertEqual(result.returncode, 0, result.stderr)
        args = json.loads(result.stdout)
        self.assertEqual(args[0], "preflight")
        self.assertNotIn("--fixed-height", args)


class RollbackTests(unittest.TestCase):
    def exercise(self, candidate_started):
        updater = Path(__file__).resolve().parents[1] / "scripts/upgrade-validator.sh"
        source = updater.read_text()
        function = re.search(r"^restore_old_container\(\) \{.*?^\}", source, re.M | re.S).group(0)
        # Run the actual function with a logging Docker stub, never the daemon.
        script = '\n'.join([
            'set -euo pipefail',
            'docker() { printf "docker"; printf " [%s]" "$@"; printf "\\n" >&3; }',
            'exec 3>&1',
            'FIXED_HEIGHT=true',
            'CANDIDATE_STARTED=' + ('true' if candidate_started else 'false'),
            'CONTAINER_NAME=qa-candidate',
            'BACKUP_DIR=/qa-backup',
            'HARDEN_RPC=false',
            'watchdog_was_active=false',
            function,
            'restore_old_container qa-old',
        ])
        # Stub output must bypass the function's stdout redirections.
        script = script.replace('printf "docker"; printf " [%s]" "$@";', 'printf "docker" >&3; printf " [%s]" "$@" >&3;')
        return subprocess.run(['bash', '-c', script], capture_output=True, text=True)

    def test_candidate_failure_never_restarts_old_binary(self):
        result = self.exercise(True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('[stop] [--time] [60] [qa-candidate]', result.stdout)
        self.assertIn('[update] [--restart=no] [qa-old]', result.stdout)
        self.assertNotIn('[start]', result.stdout)
        self.assertNotIn('[rename]', result.stdout)

    def test_pre_candidate_failure_can_restore_old_container(self):
        result = self.exercise(False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('[start] [qa-candidate]', result.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
