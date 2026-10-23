#!/usr/bin/env python3
"""No node/network: regress the jq false-as-missing watchdog restart bug."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


class Tests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.script = Path(__file__).resolve().parents[1] / "scripts/watchdog.sh"
        (self.root / "date").write_text('''#!/bin/sh
if [ "$1" = +%s ]; then echo "$NOW"; else echo "fixture-time"; fi
''')
        (self.root / "docker").write_text('''#!/usr/bin/env python3
import json,os,sys
args=sys.argv[1:]
if args[0]=="ps": print("fixture-validator")
elif args[0] in ("restart","start"):
 with open(os.environ["CALLS"],"a") as f: f.write(args[0]+"\\n")
elif args[0]=="exec":
 if "net_info" in args[-1]: print(json.dumps({"result":{"n_peers":"3"}}))
 else: print(os.environ["STATUS"])
else: raise RuntimeError(args)
''')
        for name in ("date", "docker"):
            (self.root / name).chmod(0o700)

    def exercise(self, catching):
        for now, height in [(1000, 100), (2200, 200)]:
            info = {"latest_block_height": str(height)}
            if catching is not None:
                info["catching_up"] = catching
            env = dict(os.environ, PATH=str(self.root) + ":" + os.environ["PATH"], NOW=str(now),
                       STATUS=json.dumps({"result":{"sync_info":info}}),
                       STATE_DIR=str(self.root / "state"), LOG_FILE=str(self.root / "log"),
                       CALLS=str(self.root / "calls"), CONTAINER_NAME="fixture-validator")
            result = subprocess.run(["bash", str(self.script)], env=env, capture_output=True, text=True)
            self.assertEqual(0, result.returncode, result.stderr)
        calls = self.root / "calls"
        return calls.read_text() if calls.exists() else ""

    def test_healthy_false_never_turns_into_catching_up(self):
        self.assertEqual("", self.exercise(False))
        self.assertFalse((self.root / "state/catching_up_since").exists())

    def test_real_catching_up_remains_subject_to_recovery(self):
        self.assertEqual("restart\n", self.exercise(True))

    def test_missing_or_malformed_flag_is_not_assumed_healthy(self):
        self.assertEqual("restart\n", self.exercise(None))


if __name__ == "__main__":
    unittest.main(verbosity=2)
