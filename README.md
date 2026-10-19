# server-prep

[![lint](https://github.com/exceev-consulting/server-prep/actions/workflows/lint.yml/badge.svg)](https://github.com/exceev-consulting/server-prep/actions/workflows/lint.yml)
[![release](https://img.shields.io/github/v/release/exceev-consulting/server-prep)](https://github.com/exceev-consulting/server-prep/releases/latest)
[![license: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

Secure a new Debian/Ubuntu server, a **VPS** or a **dedicated** machine (rented or in your office),
and get it ready for a self-hosted PaaS panel
([Coolify](https://coolify.io), [Dokploy](https://dokploy.com), [Openship](https://openship.io/)... any panel
that connects to servers over SSH with a key).
A security check runs before and after, so you see exactly what changed.

Built and maintained by [Exceev Consulting](https://exceev.com).

| Script | What it does |
|---|---|
| `server-preconfig.sh` | **Run first** on a fresh server: SSH + sudo, hostname, network saved for reboots, never sleep, Tailscale, then a reboot-readiness check. Guide: [server-preconfig.md](server-preconfig.md) |
| `server-prep.sh` | Secures the server and prepares it for the panel, with questions or from a config file. Idempotent, backs up every file, writes a Markdown report. |
| `server-audit.sh` | Read-only security & panel-readiness audit. Console, text, Markdown, JSON and TSV output. |
| `server-prep.conf.example` | All settings, for non-interactive runs on client servers. |

Tested target: Ubuntu 22.04 / 24.04 / 26.04, Debian 12 / 13, on cloud VPS and on dedicated / on-premise servers.

### VPS or dedicated server

Both work the same way. Only a few details change:

| | VPS | Dedicated / on-premise server |
|---|---|---|
| **Network** | keep the provider's config (netplan / cloud-init): `server-preconfig.sh` doesn't touch it, Enter = `keep` | save it so it survives reboots: `server-preconfig.sh --static-ip current`, or a DHCP reservation on the router |
| **Console if SSH breaks** | the provider's web console | IPMI / iDRAC / iLO / KVM, the host's rescue mode, or a screen and keyboard |
| **Power** | handled by the provider | BIOS *Restore on AC Power Loss* = **Power On** |
| **Reaching it** | public IP: open 80/443 (`EXPOSE_WEB=yes`) or use a tunnel | often behind NAT: Tailscale for SSH and the panel, a Cloudflare Tunnel for the apps |

## The 5W - what you are doing when you run it

| | |
|---|---|
| **What** | Secures the server (SSH keys only on a new port, firewall, fail2ban/CrowdSec, automatic security updates, safer kernel settings, audit logs, rootkit/integrity scans, optional alerts) and prepares it for your panel (root access reserved to the panel's key and access route, Docker ready). Produces a report of every change. |
| **Why** | A fresh server is scanned within minutes. Password SSH on port 22, no firewall and Docker bypassing the firewall are the usual ways servers get compromised. A deployment panel also needs a predictable, reachable server. |
| **Who** | Run by an administrator (sudo) of the server. Afterwards: the admin logs in with their own account + SSH key; the panel logs in as root with its key, only from its access route (tunnel / tailnet / its IP); nobody else can log in. |
| **When** | Right after installing a new server, before deploying apps. Safe to re-run anytime (only missing changes are applied) - after an OS upgrade, or to change a setting. |
| **Where** | On the server itself (not remotely). Config in `/etc`, backups in `/var/lib/server-prep/backups`, log in `/var/log/server-prep`, report in `/root/server-prep-reports` (+ copy in your home). |
| **How** | Answer the questions (each is explained, Enter = default) → review the plan and confirm (nothing changes before) → steps run → audit runs again to show before/after. SSH changes auto-rollback after 10 minutes unless you confirm a new login works. `--dry-run` previews only. |

## Quick start

```bash
git clone https://github.com/exceev-consulting/server-prep.git && cd server-prep

sudo ./server-preconfig.sh             # 0. fresh server: SSH, hostname, network, Tailscale
sudo ./server-audit.sh                 # 1. see where you stand (changes nothing)
sudo ./server-prep.sh --dry-run        # 2. preview every change
sudo ./server-prep.sh                  # 3. apply (interactive questions)
```

Or download the scripts from the [latest release](https://github.com/exceev-consulting/server-prep/releases/latest)
and check them with `sha256sum -c SHA256SUMS`.

For a client server, reuse a config file:

```bash
cp server-prep.conf.example client-a.conf   # fill it in (never commit it)
sudo ./server-prep.sh --config client-a.conf --yes
```

Run part of it only: `--only ssh,firewall` / `--skip aide,endlessh` (`--list-steps` prints the names).

## What server-prep does

| Step | Details |
|---|---|
| `update` | apt full-upgrade, base tools (curl, git, jq, ufw, chrony...), timezone |
| `users` | admin user + your SSH key; the panel's key for root, restricted with `from="..."` to the panel's sources |
| `docker` | Docker CE from download.docker.com if missing, container log rotation |
| `firewall` | UFW deny-incoming; SSH only from admin IPs / tailnet / tunnel; optional 80/443; **[ufw-docker](https://github.com/chaifeng/ufw-docker) (pinned, checksum-verified) so published container ports obey UFW** (Docker networking untouched) |
| `ssh` | port 822, keys only, `PermitRootLogin no` + `Match Address <panel sources>` → root key login only from the panel, `AllowUsers`, MaxAuthTries 3, no X11/agent forwarding. **10-minute auto-rollback** until you confirm a new login works |
| `ips` | fail2ban (sshd jail on the right port) + CrowdSec with firewall bouncer (INPUT + DOCKER-USER), panel/admin IPs whitelisted, LAPI moved off 8080 |
| `unattended` | daily security updates (+ Docker CE), optional auto-reboot |
| `sysctl` | ~30 kernel/network parameters, rare protocols blacklisted (Docker/Tailscale compatible) |
| `auth` | sudo log file (`/var/log/sudo.log`), pwquality minlen 12 + complexity |
| `services` | disable avahi, cups, bluetooth, ModemManager; mask Ctrl-Alt-Del; optional headless boot |
| `laptop` | laptop used as a server: ignore lid close, mask sleep/suspend |
| `logging` | persistent journald (1 GB cap), swap file if none |
| `auditd` | audit rules: identity files, sudoers, SSH, Docker, cron, firewall, admin root commands |
| `rkhunter` / `aide` | rootkit scan + file-integrity baseline, daily |
| `endlessh` | SSH tarpit on port 22 once SSH has moved |
| `telegraf` | Telegraf metrics agent from the official InfluxData repo (key fingerprint checked); installed but left stopped until you add an InfluxDB output in `/etc/telegraf/telegraf.d/` |
| `telegram` | alert on every SSH login (except ignored users, e.g. the panel's root) + daily report at 09:00 |
| `cloudflared` | install the Cloudflare Tunnel connector with your token |
| `suid` | list SUID binaries outside standard paths (review only) |

Outputs (root only):

- report: `/root/server-prep-reports/server-prep-report-<host>-<date>.md` (copy in the invoking user's home)
- log: `/var/log/server-prep/run-<date>.log`
- backups + `rollback.sh`: `/var/lib/server-prep/backups/<date>/`
- answers (reusable, no secrets): `/etc/server-prep/server-prep.conf`

## Connecting the server to your panel

Works with any panel that manages remote servers over SSH with a key, for example
[Coolify](https://coolify.io), [Dokploy](https://dokploy.com) and [Openship](https://openship.io/).
Set `PANEL` to its name (`coolify`, `dokploy`, `openship`...): it is used in the questions,
notes and report.

The panel connects over SSH as `root`. server-prep allows that **only** with the panel's key and
**only** from the sources you chose:

| Access | Root allowed from | In the panel |
|---|---|---|
| `cloudflared` | 127.0.0.1 / ::1 (the tunnel) | add server with the tunnel SSH hostname, and enable the panel's Cloudflare Tunnel option if it has one (Coolify does) |
| `tailscale` | 100.64.0.0/10 | add server with its Tailscale IP (the panel server must be in the tailnet) |
| `public` | `PANEL_IP` | add server with its public IP |

User `root`, port `822` (or your `SSH_PORT`), private key = the one whose public key you gave.

With the Cloudflare Tunnel, add these public hostnames in Zero Trust:
`ssh-<host>.<domain>` → `ssh://localhost:822` and your app domains → `http://localhost:80` (the panel's reverse proxy).

## Extras

| File | Use |
|---|---|
| `extras/telegraf/influxdb.conf.example` | InfluxDB v2 output for Telegraf (token read from `/etc/default/telegraf`) |
| `extras/github-runners/limit-runners-memory.sh` | caps self-hosted GitHub runners to 40% of RAM (systemd slice): `sudo ./limit-runners-memory.sh [30%] [--remove]` |

## Working with Claude Code

`CLAUDE.md` holds the project context and known pitfalls. Skills in `.claude/skills/`:
`/new-server` (guided setup), `/audit-review` (analyse an audit), `/monitoring` (Telegraf → InfluxDB → Grafana),
`/add-step` (checklist for changing the scripts).

## About the audit

`server-audit.sh` is a rework of [vps-audit](https://nuverlabs.com/vps-audit) v0.2.0. Main differences:

- reads sshd's **effective** config (`sshd -T`), so drop-ins and `Match` blocks are understood
- port exposure considers the bind address **and** the firewall (localhost-only ports are not "public")
- detects Docker bypassing UFW
- separates security updates from regular ones
- adds CrowdSec, fail2ban jail/port alignment, sysctl, AppArmor, auditd, rkhunter, AIDE, UID 0,
  empty passwords, world-writable /etc files, Docker hygiene and a panel-readiness section

```bash
sudo ./server-audit.sh --md audit.md --json audit.json
```

Exit code is `1` when at least one check FAILs (handy in CI/cron).

## Safety notes

- Have console access the first time you run it: the VPS provider's web console, IPMI / KVM or rescue mode on a dedicated server, or physical access.
- Add your SSH key **before** the SSH step: password login gets disabled.
- `--dry-run` changes nothing; every step can be re-run safely.
- Docker restarts only after confirmation (running containers restart with it).

## Contributing

Help is welcome: tests on other providers and hardware, bug reports, support for more panels, clearer docs.

- Read [CONTRIBUTING.md](CONTRIBUTING.md): how to test and the rules for the scripts.
- Questions in [Discussions](https://github.com/exceev-consulting/server-prep/discussions), bugs and ideas in [Issues](https://github.com/exceev-consulting/server-prep/issues).
- Security problems: report them privately, see [SECURITY.md](SECURITY.md).
- Everyone follows the [Code of Conduct](CODE_OF_CONDUCT.md). Changes are listed in [CHANGELOG.md](CHANGELOG.md).

## About Exceev Consulting

server-prep is built and maintained by [Exceev Consulting](https://exceev.com), a consulting and tech company
(France, Morocco): AI solutions, product development, platform engineering and enterprise strategy.
We use server-prep to set up our clients' servers.

Need help securing your servers or running your own deployment platform? [Contact us](https://exceev.com/contact).

## Credits

- `server-audit.sh` is derived from [vps-audit](https://github.com/nuver-labs/vps-audit) (MIT).
- The UFW/Docker fix uses [ufw-docker](https://github.com/chaifeng/ufw-docker) (GPL-3.0). It is downloaded at runtime and not bundled.
- Some ideas come from [vps-secure](https://github.com/rockballslab/vps-secure).

See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## License

[MIT](LICENSE) © 2026 [Exceev Consulting](https://exceev.com)
