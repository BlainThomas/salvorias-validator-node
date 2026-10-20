#!/usr/bin/env python3
"""Offline tests: no Docker daemon, network, private keys, or transactions."""
import copy
import datetime as dt
import importlib.util
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest

spec = importlib.util.spec_from_file_location("unjail", Path(__file__).resolve().parents[1] / "scripts/post-upgrade-unjail.py")
helper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helper)
NOW = dt.datetime(2026, 10, 20, 17, tzinfo=dt.timezone.utc)
PUB = {"@type": "/cosmos.crypto.ed25519.PubKey", "key": "PUBLIC_FIXTURE"}
TX = "A" * 64


class FakeNode:
    def __init__(self):
        self.hash = "b" * 64
        self.current = {"node_info": {"network": "salvorias_7282-1"},
                        "sync_info": {"catching_up": False, "latest_block_height": "5000001",
                                      "latest_block_time": "2026-10-20T16:59:58Z"},
                        "validator_info": {"pub_key": PUB}}
        self.validator = {"consensus_pubkey": PUB, "jailed": True, "tokens": "100",
                          "delegator_shares": "100", "min_self_delegation": "1"}
        self.info = {"tombstoned": False, "jailed_until": "2026-10-20T16:50:00Z"}
        self.operator = "evmosvaloper1fixture"
        self.balance = "1000000000000000"
        self.shares = "100"
        self.price = "1000000000"
        self.sent = []
        self.fail_broadcast = False
        self.reply = {"code": 0, "txhash": TX}

    def command(self, *words):
        assert words == ("sha256sum", "/usr/bin/evmosd")
        return self.hash + "  /usr/bin/evmosd"

    def status(self):
        return copy.deepcopy(self.current)

    def cli(self, *words):
        if words[:2] == ("keys", "show"):
            return self.operator if "--bech" in words else "evmos1fixture"
        assert words[:3] == ("tx", "slashing", "unjail")
        self.sent.append(words)
        if self.fail_broadcast:
            raise TimeoutError("unknown outcome")
        return json.dumps(self.reply)

    def query(self, *words):
        if words[:2] == ("staking", "validator"):
            value = copy.deepcopy(self.validator)
            if self.sent and self.reply.get("code") == 0:
                value["jailed"] = False
            return {"validator": value}
        if words[:2] == ("slashing", "signing-info"):
            return {"val_signing_info": self.info}
        if words[:2] == ("staking", "delegation"):
            return {"delegation_response": {"delegation": {"shares": self.shares}}}
        if words[:2] == ("feemarket", "params"):
            return {"params": {"base_fee": self.price, "min_gas_price": "0"}}
        if words[:2] == ("bank", "spendable-balances"):
            return {"balances": [{"denom": "SAVDR", "amount": self.balance}]}
        if words == ("tx", TX):
            return {"height": "5000002", "code": 0}
        raise AssertionError(words)


class Tests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.args = SimpleNamespace(container="validator", binary_sha256="b" * 64,
                                    minimum_height=5000000, valoper="evmosvaloper1fixture",
                                    key_name="validator", max_fee=1000000000000000,
                                    submit=False, state_dir=self.tmp.name)
        self.node = FakeNode()

    def run_helper(self):
        return helper.run(self.node, self.args, NOW)

    def test_checks_do_not_send(self):
        self.assertIn("nothing sent", self.run_helper())
        self.assertEqual([], self.node.sent)

    def test_healthy_does_not_send(self):
        self.args.submit = True
        self.node.validator["jailed"] = False
        self.assertIn("not jailed", self.run_helper())
        self.assertEqual([], self.node.sent)

    def test_proto_omitted_false_fields(self):
        del self.node.validator["jailed"]
        self.assertIn("not jailed", self.run_helper())
        self.node.validator["jailed"] = True
        del self.node.info["tombstoned"]
        self.assertIn("nothing sent", self.run_helper())

    def test_live_cli_public_key_encoding(self):
        self.node.validator["consensus_pubkey"] = {"type": PUB["@type"], "value": PUB["key"]}
        self.node.current["validator_info"]["pub_key"] = {"type": "tendermint/PubKeyEd25519", "value": PUB["key"]}
        self.assertIn("nothing sent", self.run_helper())

    def test_send_once_and_confirm(self):
        self.args.submit = True
        self.assertIn("Unjail confirmed", self.run_helper())
        self.assertEqual(1, len(self.node.sent))
        self.assertIn("1000000000000000SAVDR", self.node.sent[0])
        self.assertIn("not jailed", self.run_helper())
        self.assertEqual(1, len(self.node.sent))

    def test_existing_attempt_blocks_retry(self):
        self.args.submit = True
        Path(self.tmp.name, "validator-unjail.json").write_text("{}")
        with self.assertRaises(helper.Refused):
            self.run_helper()
        self.assertEqual([], self.node.sent)

    def test_ambiguous_broadcast_is_not_retried(self):
        self.args.submit = True
        self.node.fail_broadcast = True
        with self.assertRaises(TimeoutError):
            self.run_helper()
        self.node.sent = []
        with self.assertRaises(helper.Refused):
            self.run_helper()
        self.assertEqual([], self.node.sent)

    def test_checktx_rejection_is_retained(self):
        self.args.submit = True
        self.node.reply["code"] = 5
        with self.assertRaises(helper.Refused):
            self.run_helper()
        saved = json.loads(Path(self.tmp.name, "validator-unjail.json").read_text())
        self.assertEqual(5, saved["checktx_code"])

    def test_fail_closed_guards(self):
        changes = [
            lambda n: setattr(n, "hash", "c" * 64),
            lambda n: n.current["node_info"].update(network="salvorias_7283-1"),
            lambda n: n.current["sync_info"].update(catching_up=True),
            lambda n: n.current["sync_info"].update(latest_block_height="1"),
            lambda n: n.current["sync_info"].update(latest_block_time="2026-10-20T16:00:00Z"),
            lambda n: n.validator.update(consensus_pubkey={"key": "WRONG"}),
            lambda n: n.info.update(tombstoned=True),
            lambda n: n.info.update(jailed_until="2026-10-20T18:00:00Z"),
            lambda n: setattr(n, "operator", "evmosvaloper1wrong"),
            lambda n: setattr(n, "balance", "0"),
            lambda n: setattr(n, "shares", "0"),
            lambda n: setattr(n, "price", "1000000001"),
        ]
        for i, change in enumerate(changes):
            with self.subTest(guard=i):
                self.node = FakeNode()
                change(self.node)
                self.args.submit = True
                with self.assertRaises(helper.Refused):
                    self.run_helper()
                self.assertEqual([], self.node.sent)


if __name__ == "__main__":
    unittest.main(verbosity=2)
