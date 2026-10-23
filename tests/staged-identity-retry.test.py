#!/usr/bin/env python3
import re
from pathlib import Path
import subprocess
import unittest


class Tests(unittest.TestCase):
    def exercise(self, failures):
        source = (Path(__file__).resolve().parents[1] / "scripts/upgrade-validator.sh").read_text()
        function = re.search(r"^read_identity_with_retry\(\) \{.*?^\}", source, re.M | re.S).group(0)
        script = "\n".join(["set -eu", "calls=0", "sleep() { :; }",
            "read_identity() { calls=$((calls+1)); [ \"$calls\" -gt " + str(failures) + " ]; }",
            function, "read_identity_with_retry"])
        return subprocess.run(["bash", "-c", script], capture_output=True, text=True)

    def test_healthy_identity_is_immediate(self):
        self.assertEqual(0, self.exercise(0).returncode)

    def test_transient_status_failure_does_not_abandon_waiting_job(self):
        self.assertEqual(0, self.exercise(3).returncode)

    def test_permanent_failure_is_bounded_and_never_assumed_safe(self):
        self.assertNotEqual(0, self.exercise(100).returncode)


if __name__ == "__main__":
    unittest.main(verbosity=2)
