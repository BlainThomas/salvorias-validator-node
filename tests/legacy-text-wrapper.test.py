#!/usr/bin/env python3
import importlib.util
from pathlib import Path
import unittest

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


if __name__ == "__main__":
    unittest.main(verbosity=2)
