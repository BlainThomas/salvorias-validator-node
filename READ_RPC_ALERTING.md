# Salvorias Read-RPC alerting

The watchdog checks the local EVM response, block age, lag against the trusted
canonical validator, chain ID, and the canonical block hash at the read node's
height. Two consecutive failures open an incident, post to Slack, and restart
the read-RPC container. A later healthy check posts a recovery message.

Install the script and systemd units, then create a root-only environment file:

```bash
sudo install -m 0755 scripts/read-rpc-watchdog.sh /usr/local/bin/salvorias-rpc-watchdog.sh
sudo install -m 0644 systemd/salvorias-rpc-watchdog.service /etc/systemd/system/
sudo install -m 0644 systemd/salvorias-rpc-watchdog.timer /etc/systemd/system/
sudo install -m 0600 /dev/null /etc/salvorias-rpc-watchdog.env
sudoedit /etc/salvorias-rpc-watchdog.env
```

Required secret configuration:

```text
SLACK_BOT_TOKEN=xoxb-REDACTED
SLACK_CHANNEL_ID=C0BK3EQ7UCE
```

The Slack bot needs `chat:write` and must be invited to `#blockchain_alerts`.
Never commit the token. After editing the environment file:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now salvorias-rpc-watchdog.timer
sudo systemctl start salvorias-rpc-watchdog.service
sudo journalctl -u salvorias-rpc-watchdog.service -n 30 --no-pager
```
