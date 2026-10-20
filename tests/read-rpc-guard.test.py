import os
from pathlib import Path
import subprocess
import tempfile
import unittest

class GuardTests(unittest.TestCase):
    def test_handoff_guards(self):
        source = (Path(__file__).resolve().parents[1] / 'scripts/read-rpc-h4031650-guard.sh').read_text()
        with tempfile.TemporaryDirectory() as root:
            p = Path(root)
            marker = p / 'pending'
            source = source.replace('/var/lib/salvorias-rpc-watchdog/upgrade-h4031650.pending', str(marker))
            (p / 'guard').write_text(source)
            (p / 'systemctl').write_text('#!/bin/sh\n[ "$ACTIVE" = 1 ]\n')
            (p / 'docker').write_text('''#!/bin/sh
case "$*" in
  *sha256sum*) echo "$HASH" ;;
  *abci_info*) printf '{"result":{"response":{"last_block_height":"%s"}}}' "$HEIGHT" ;;
  *status*) printf '{"result":{"node_info":{"network":"%s"},"validator_info":{"address":"%s"},"sync_info":{"catching_up":%s}}}' "$CHAIN" "$IDENTITY" "$CATCHING" ;;
  *) exit 99 ;;
esac
''')
            for name in ['systemctl', 'docker']:
                (p / name).chmod(0o700)
            good = dict(os.environ, PATH=root + ':' + os.environ['PATH'], ACTIVE='0', HASH='486e971ecf8321be52d5b34c568273b68e22b494ce1af3c91bb1d72e4ac15a83', HEIGHT='4031650', CHAIN='salvorias_7282-1', IDENTITY='3AEAFB6295C6F23400C2488CCC897C2E35E617D9', CATCHING='false')
            for change in [{'ACTIVE':'1'}, {'HASH':'old'}, {'HEIGHT':'4031649'}, {'CHAIN':'wrong'}, {'IDENTITY':'wrong'}, {'CATCHING':'true'}, {}]:
                with self.subTest(change=change):
                    marker.touch()
                    result = subprocess.run(['bash', str(p / 'guard')], env=dict(good, **change), capture_output=True)
                    self.assertEqual(result.returncode == 0, not bool(change))
                    self.assertEqual(marker.exists(), bool(change))
            result = subprocess.run(['bash', str(p / 'guard')], env=dict(good, ACTIVE='1'), capture_output=True)
            self.assertEqual(result.returncode, 0, 'No marker must allow normal overnight recovery')

if __name__ == '__main__':
    unittest.main(verbosity=2)
