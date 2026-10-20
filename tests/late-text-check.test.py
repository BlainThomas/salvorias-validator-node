import copy
import importlib.util
from pathlib import Path
from datetime import datetime, timezone
import unittest

spec = importlib.util.spec_from_file_location('gate', Path(__file__).resolve().parents[1]/'scripts/late-text-check.py')
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)

class LateGate(unittest.TestCase):
    def setUp(self):
        self.s={'node_info':{'network':'salvorias_7282-1'},'sync_info':{'catching_up':False,'latest_block_height':'4031700','latest_block_time':datetime.now(timezone.utc).isoformat()}}
        self.b={'block_id':{'hash':'abc'},'block':{'header':{'height':'4031698','chain_id':'salvorias_7282-1','app_hash':'def'}}}
    def check(self,s=None,b=None,digest=gate.OLD,new=False):
        gate.validate(self.s,s or self.s,self.b,b or self.b,digest,new)
    def test_old_compatible(self):self.check()
    def test_new_compatible(self):self.check(digest=gate.NEW,new=True)
    def test_old_not_complete(self):
        with self.assertRaises(AssertionError):self.check(new=True)
    def test_unknown_binary(self):
        with self.assertRaises(AssertionError):self.check(digest='unknown')
    def test_wrong_chain(self):
        s=copy.deepcopy(self.s);s['node_info']['network']='other'
        with self.assertRaises(AssertionError):self.check(s=s)
    def test_catching_up(self):
        s=copy.deepcopy(self.s);s['sync_info']['catching_up']=True
        with self.assertRaises(AssertionError):self.check(s=s)
    def test_stale(self):
        s=copy.deepcopy(self.s);s['sync_info']['latest_block_time']='2020-01-01T00:00:00Z'
        with self.assertRaises(AssertionError):self.check(s=s)
    def test_lag(self):
        s=copy.deepcopy(self.s);s['sync_info']['latest_block_height']='4031800'
        with self.assertRaises(AssertionError):self.check(s=s)
    def test_pre_activation(self):
        self.s['sync_info']['latest_block_height']='4031649'
        with self.assertRaises(AssertionError):self.check()
    def test_fork(self):
        b=copy.deepcopy(self.b);b['block_id']['hash']='other'
        with self.assertRaises(AssertionError):self.check(b=b)
    def test_state_mismatch(self):
        b=copy.deepcopy(self.b);b['block']['header']['app_hash']='other'
        with self.assertRaises(AssertionError):self.check(b=b)

if __name__=='__main__':unittest.main(verbosity=2)
