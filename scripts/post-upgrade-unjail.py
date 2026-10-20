#!/usr/bin/env python3
"""Opt-in post-upgrade unjail. Defaults to checks only; never exports keys."""
import argparse
import datetime as dt
from decimal import Decimal, ROUND_CEILING, localcontext
import fcntl
import json
from pathlib import Path
import re
import subprocess
import sys
import time


class Refused(RuntimeError):
    pass


def require(condition, message):
    if not condition:
        raise Refused(message)


def timestamp(value):
    return dt.datetime.fromisoformat(value.replace("Z", "+00:00"))


class Node:
    def __init__(self, args):
        self.args = args

    def command(self, *words):
        # No shell, interactive stdin, key export, or arbitrary environment output.
        result = subprocess.run(
            ["docker", "exec", self.args.container, *words], stdin=subprocess.DEVNULL,
            capture_output=True, text=True, timeout=30, check=False)
        require(result.returncode == 0, "Node command failed; inspect locally. No automatic retry.")
        return result.stdout.strip()

    def cli(self, *words):
        return self.command("evmosd", *words)

    def query(self, *words):
        return json.loads(self.cli("query", *words, "--node", "tcp://127.0.0.1:26657", "--output", "json"))

    def status(self):
        return json.loads(self.cli("status", "--node", "tcp://127.0.0.1:26657"))


def check(node, args, now):
    actual = node.command("sha256sum", "/usr/bin/evmosd").split()[0]
    require(actual == args.binary_sha256.lower(), "Wrong release binary; do not unjail.")
    status = node.status()
    require(status["node_info"]["network"] == "salvorias_7282-1", "Wrong chain.")
    sync = status["sync_info"]
    require(sync["catching_up"] is False, "Node is still catching up; retry checks later.")
    require(int(sync["latest_block_height"]) >= args.minimum_height, "Activation height not reached.")
    age = (now - timestamp(sync["latest_block_time"])).total_seconds()
    require(-15 <= age <= 60, "Local block is stale or clock is incorrect.")
    validator = node.query("staking", "validator", args.valoper)["validator"]
    local_pubkey = status["validator_info"]["pub_key"]
    chain_pubkey = validator["consensus_pubkey"]
    require(local_pubkey.get("key", local_pubkey.get("value")) == chain_pubkey["key"],
            "Operator does not belong to this node's consensus key.")
    require(isinstance(validator.get("jailed"), bool), "Malformed validator state.")
    if not validator["jailed"]:
        return None
    info = node.query("slashing", "signing-info", json.dumps(chain_pubkey))["val_signing_info"]
    require(info.get("tombstoned") is False, "Tombstoned validator: manual investigation required.")
    require(timestamp(info["jailed_until"]) <= timestamp(sync["latest_block_time"]),
            "Jail period has not elapsed on chain; retry checks later.")
    key_flags = ("--keyring-backend", "test", "--home", "/home/evmos/.evmosd")
    operator = node.cli("keys", "show", args.key_name, *key_flags, "--bech", "val", "-a")
    require(operator == args.valoper, "Signing key does not match the validator operator.")
    account = node.cli("keys", "show", args.key_name, *key_flags, "-a")
    delegation = node.query("staking", "delegation", account, args.valoper)["delegation_response"]
    with localcontext() as context:
        context.prec = 100
        own_tokens = (Decimal(delegation["delegation"]["shares"]) * Decimal(validator["tokens"])
                      / Decimal(validator["delegator_shares"]))
        require(own_tokens >= Decimal(validator["min_self_delegation"]), "Insufficient self-delegation.")
        fee_params = node.query("feemarket", "params")["params"]
        price = max(Decimal("1000000000"), Decimal(fee_params["base_fee"]), Decimal(fee_params["min_gas_price"]))
        fee = int((price * 500000 * 2).to_integral_value(rounding=ROUND_CEILING))
    require(0 < fee <= args.max_fee, "Required fee exceeds the authorized fee cap.")
    balances = node.query("bank", "spendable-balances", account)["balances"]
    balance = sum(int(coin["amount"]) for coin in balances if coin["denom"] == "SAVDR")
    require(balance >= fee, "Operator needs spendable SAVDR for gas; no funds moved.")
    return fee


def run(node, args, now=None):
    now = now or dt.datetime.now(dt.timezone.utc)
    fee = check(node, args, now)
    if fee is None:
        return "Validator is not jailed. No transaction needed; verify signing separately."
    if not args.submit:
        return f"Checks passed. Unjail fee would be {fee} SAVDR base units. Checks only: nothing sent."
    journal = Path(args.state_dir) / (args.container + "-unjail.json")
    # Persist BEFORE broadcast. Any ambiguity is manual review, never automatic retry.
    try:
        with journal.open("x", encoding="utf-8") as record:
            json.dump({"status": "broadcast_may_have_started", "operator": args.valoper,
                       "time": now.isoformat(), "fee": str(fee)}, record)
            record.flush()
            import os
            os.fsync(record.fileno())
    except FileExistsError:
        raise Refused("Previous attempt recorded. Reconcile its transaction before any retry.")
    reply = json.loads(node.cli(
        "tx", "slashing", "unjail", "--from", args.key_name,
        "--keyring-backend", "test", "--home", "/home/evmos/.evmosd",
        "--chain-id", "salvorias_7282-1", "--node", "tcp://127.0.0.1:26657",
        "--gas", "500000", "--fees", f"{fee}SAVDR", "--broadcast-mode", "sync",
        "--output", "json", "--yes"))
    txhash = reply.get("txhash", "")
    require(isinstance(txhash, str) and re.fullmatch(r"[A-Fa-f0-9]{64}", txhash),
            "No valid transaction hash. Manual reconciliation required; do not resubmit.")
    journal.write_text(json.dumps({"status": "submitted", "txhash": txhash,
                                  "operator": args.valoper, "checktx_code": reply.get("code")}) + "\n")
    require(reply.get("code") == 0, f"CheckTx rejected unjail ({txhash}); inspect before retry.")
    # One broadcast only. Polling cannot initiate another transaction.
    for _ in range(20):
        try:
            confirmed = node.query("tx", txhash)
        except (Refused, subprocess.TimeoutExpired):
            time.sleep(3)
            continue
        require(int(confirmed.get("height", 0)) > 0 and confirmed.get("code") == 0,
                f"Unjail transaction failed or was not included: {txhash}. Manual review required.")
        jailed = node.query("staking", "validator", args.valoper)["validator"]["jailed"]
        require(jailed is False, f"Transaction included but validator remains jailed: {txhash}.")
        return f"Unjail confirmed: {txhash}. Verify subsequent signing; bonded status is not guaranteed."
    raise Refused(f"Confirmation pending for {txhash}. Do not rebroadcast; inspect the recorded transaction.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--container", required=True)
    parser.add_argument("--binary-sha256", required=True)
    parser.add_argument("--minimum-height", required=True, type=int)
    parser.add_argument("--valoper", required=True)
    parser.add_argument("--key-name", default="validator")
    parser.add_argument("--max-fee", type=int, default=1000000000000000,
                        help="Maximum fee in SAVDR base units (default 0.001 SAVDR)")
    parser.add_argument("--submit", action="store_true")
    parser.add_argument("--wait-seconds", type=int, default=600,
                        help="Bounded wait for catch-up before eligibility checks")
    parser.add_argument("--state-dir", default="/var/lib/salvorias-operator")
    args = parser.parse_args()
    require(re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]*", args.container), "Invalid container name.")
    require(re.fullmatch(r"[a-fA-F0-9]{64}", args.binary_sha256), "Invalid binary checksum.")
    require(args.minimum_height > 0 and args.max_fee > 0, "Invalid height or fee cap.")
    require(0 <= args.wait_seconds <= 3600, "Wait must be between zero and 3600 seconds.")
    require(args.valoper.startswith("evmosvaloper1"), "Expected a mainnet operator address.")
    state = Path(args.state_dir)
    state.mkdir(mode=0o700, parents=True, exist_ok=True)
    require(not state.is_symlink(), "State directory must not be a symlink.")
    state.chmod(0o700)
    with (state / (args.container + "-unjail.lock")).open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        node = Node(args)
        deadline = time.monotonic() + args.wait_seconds
        while True:
            status = node.status()
            require(status["node_info"]["network"] == "salvorias_7282-1", "Wrong chain.")
            if status["sync_info"]["catching_up"] is False:
                break
            require(time.monotonic() < deadline, "Catch-up wait expired. Retry checks later; nothing sent.")
            time.sleep(5)
        print(run(node, args))


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        # Do not echo subprocess stderr or keyring diagnostics into shared logs.
        print(str(error) if isinstance(error, Refused) else
              "Check failed or transaction outcome unknown. Inspect locally; no automatic retry.", file=sys.stderr)
        sys.exit(1)
