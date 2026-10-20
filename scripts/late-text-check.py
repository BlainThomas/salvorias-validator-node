#!/usr/bin/env python3
"""Read-only compatibility gate for the state-preserving legacy-text update."""
import argparse
import json
import subprocess
import urllib.request
from datetime import datetime, timezone

NEW = '486e971ecf8321be52d5b34c568273b68e22b494ce1af3c91bb1d72e4ac15a83'
OLD = '903694262846d4badc8db8825d8c78b6a5ae80ab6e6f8849e205a2b760067072'

def validate(local, remote, left, right, digest, require_new=False):
    assert digest in ({NEW} if require_new else {OLD, NEW}), 'Unreviewed binary; stop and contact Blain'
    for status in (local, remote):
        assert status['node_info']['network'] == 'salvorias_7282-1', 'Wrong chain'
        assert status['sync_info']['catching_up'] is False, 'Still catching up'
        assert int(status['sync_info']['latest_block_height']) > 4031650, 'Not past activation'
        stamp = datetime.fromisoformat(status['sync_info']['latest_block_time'].replace('Z', '+00:00'))
        age = (datetime.now(timezone.utc) - stamp).total_seconds()
        assert -30 <= age <= 120, 'Stale block timestamp'
    assert abs(int(local['sync_info']['latest_block_height']) - int(remote['sync_info']['latest_block_height'])) <= 10, 'RPC lag too large'
    for b in (left, right):
        assert b['block']['header']['chain_id'] == 'salvorias_7282-1', 'Wrong block chain'
    assert left['block_id']['hash'] == right['block_id']['hash'], 'Block mismatch'
    assert left['block']['header']['app_hash'] == right['block']['header']['app_hash'], 'Application state mismatch'
    assert left['block']['header']['height'] == right['block']['header']['height'], 'Height mismatch'

def main():
    p = argparse.ArgumentParser()
    p.add_argument('--container', required=True)
    p.add_argument('--rpc', required=True)
    p.add_argument('--require-new', action='store_true')
    a = p.parse_args()
    def run(*args):
        return subprocess.check_output(args, text=True, timeout=30)
    def local(path):
        return json.loads(run('docker', 'exec', a.container, 'curl', '-fsS', '--max-time', '10', 'http://127.0.0.1:26657/'+path))['result']
    def remote(path):
        with urllib.request.urlopen(a.rpc.rstrip('/')+'/'+path, timeout=15) as response:
            return json.load(response)['result']
    digest = run('docker', 'exec', a.container, 'sh', '-lc', 'sha256sum "$(command -v evmosd)"').split()[0]
    l, r = local('status'), remote('status')
    height = min(int(l['sync_info']['latest_block_height']), int(r['sync_info']['latest_block_height'])) - 2
    assert height >= 4031650, 'Not enough post-upgrade blocks'
    left, right = local('block?height='+str(height)), remote('block?height='+str(height))
    validate(l, r, left, right, digest, a.require_new)
    print(json.dumps({'compatible': True, 'binary_sha256': digest, 'height': height,
                      'block_hash': left['block_id']['hash'],
                      'validator': l['validator_info']['address']}))

if __name__ == '__main__':
    main()
