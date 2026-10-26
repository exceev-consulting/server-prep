Short answers to the questions people ask most. For errors and fixes, see [Troubleshooting](Troubleshooting).

## Will it lock me out?

It is designed not to. The SSH change rolls itself back after 10 minutes unless you confirm that a new login works, and the firewall keeps your current SSH port open until then. Still, keep a console open the first time (see [VPS or dedicated](VPS-or-dedicated)). Do not use `--yes` on the first run: today it skips the login test ([#65](https://github.com/exceev-consulting/server-prep/issues/65)).

## Can I run it twice?

Yes. Every step checks the current state first and only changes what is missing. Re-run one step with the saved answers:

```bash
sudo ./server-prep.sh --config /etc/server-prep/server-prep.conf --only firewall
```

## How do I undo it?

Each run backs up every file it changes and writes a rollback script in `/var/lib/server-prep/backups/<date>/rollback.sh`. Read it before running it, and run it from the console: see [Troubleshooting](Troubleshooting#roll-back).

## Where are the logs, the report and the backups?

| What | Where |
|---|---|
| Run log | `/var/log/server-prep/run-<date>.log` |
| Report | `/root/server-prep-reports/` (a copy goes to your home folder) |
| Backups and `rollback.sh` | `/var/lib/server-prep/backups/<date>/` |
| Saved answers (no secrets) | `/etc/server-prep/server-prep.conf` |

## Why port 822?

Port 22 is scanned constantly. Moving SSH to 822 removes most of that noise, and a port under 1024 can only be opened by root. Change it with `SSH_PORT`. Once SSH has moved, an optional tarpit (endlessh) answers on 22 and wastes bots' time.

## Do I need Tailscale?

No, but it is the simplest safe route. Without it, give your IPs in `ADMIN_IPS`, and pick how the panel reaches the server: its public IP or a Cloudflare Tunnel. See [Panels](Panels#access-routes).

## Which panels work?

Any panel that manages servers over SSH with a key. Coolify and Dokploy are used today. Openship works as a generic SSH panel, and full support is planned in [#10](https://github.com/exceev-consulting/server-prep/issues/10).

## What does a FAIL mean?

A security basic is missing, for example password SSH or Docker bypassing the firewall. A FAIL lowers the score and makes `server-audit.sh` exit with 1. Each result line says how to fix it. A WARN is worth fixing; INFO is context only.

## How do I add a panel later?

Set `PANEL`, `PANEL_PUBKEY` and `PANEL_ACCESS` in `/etc/server-prep/server-prep.conf`, then:

```bash
sudo ./server-prep.sh --config /etc/server-prep/server-prep.conf --only users,firewall,ssh
```

## Does it work on Ubuntu 26.04 and on a desktop?

Yes. Ubuntu 26.04 uses sudo-rs, which logs to the journal: the audit counts that as a pass. On a desktop, the `laptop` step keeps the machine awake.

## Does anything keep running on the server?

Only standard system services it configures: UFW, fail2ban, CrowdSec, unattended-upgrades and, if you choose them, auditd, rkhunter, AIDE, endlessh and Telegraf. server-prep itself does not stay running.

## Is it safe to share my audit output?

Remove tokens, keys and passwords first, and replace real IPs and hostnames if you prefer. The score line and the WARN/FAIL lines are usually enough to get help in [Discussions](https://github.com/exceev-consulting/server-prep/discussions).
