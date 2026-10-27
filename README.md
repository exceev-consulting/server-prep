<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset=".github/assets/logo-dark.svg">
    <img src=".github/assets/logo.svg" width="72" height="72" alt="server-prep logo">
  </picture>
</p>

<h1 align="center">server-prep</h1>

<p align="center">
  <b>Harden a fresh Debian or Ubuntu server for your PaaS panel, and prove it with an audit.</b><br>
  VPS or dedicated server · Coolify, Dokploy, Openship · plain Bash, nothing left running on the server
</p>

<p align="center">
  <a href="https://github.com/exceev-consulting/server-prep/actions/workflows/lint.yml"><img src="https://github.com/exceev-consulting/server-prep/actions/workflows/lint.yml/badge.svg" alt="lint"></a>
  <a href="https://github.com/exceev-consulting/server-prep/releases/latest"><img src="https://img.shields.io/github/v/release/exceev-consulting/server-prep" alt="latest release"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-0B1117.svg" alt="MIT license"></a>
</p>

<p align="center">
  <a href="https://exceev-consulting.github.io/server-prep/"><b>Setup console</b></a> ·
  <a href="https://github.com/exceev-consulting/server-prep/wiki">Docs</a> ·
  <a href="https://github.com/exceev-consulting/server-prep/discussions">Discussions</a> ·
  <a href="https://github.com/orgs/exceev-consulting/projects/7">Roadmap</a> ·
  <a href="https://github.com/exceev-consulting/server-prep/releases/latest">Releases</a>
</p>

---

A fresh server is scanned within minutes. server-prep closes the usual ways in (password SSH on port 22,
no firewall, Docker bypassing the firewall) and prepares the server for a self-hosted deployment panel.
An audit runs before and after, so you see exactly what changed.

## Highlights

- **Locked-down SSH.** Keys only, on a new port, with a 10-minute auto-rollback until a new login works.
- **A firewall that also covers Docker.** UFW denies by default, and published container ports obey it too.
- **Intrusion blocking and updates.** fail2ban, CrowdSec and automatic security updates.
- **Ready for your panel.** Root logs in only with the panel's key, and only from its route: Tailscale, a Cloudflare Tunnel or its IP.
- **Proof, not promises.** A read-only audit with 56 checks, a score, and an exit code for CI or cron.
- **Safe to run.** A dry run, a backup of every file it changes, a rollback script and a Markdown report. Every step can run twice.

## Quick start

On the new server:

```bash
git clone https://github.com/exceev-consulting/server-prep.git && cd server-prep
sudo ./server-preconfig.sh        # first boot: SSH, hostname, network, Tailscale
sudo ./server-audit.sh            # where you stand, changes nothing
sudo ./server-prep.sh --dry-run   # preview every change
sudo ./server-prep.sh             # apply
```

Not sure what to answer? Build your setup in the **[setup console](https://exceev-consulting.github.io/server-prep/)**:
it shows the ports, the logins, the commands in order and a ready config file for your server and panel.
New to servers? Follow **[Start here](https://github.com/exceev-consulting/server-prep/wiki/Start-here)**.

Prefer a download? Get the scripts from the [latest release](https://github.com/exceev-consulting/server-prep/releases/latest)
and check them with `sha256sum -c SHA256SUMS`. To prepare many servers the same way, fill a copy of
[server-prep.conf.example](server-prep.conf.example) and run `sudo ./server-prep.sh --config web-01.conf --yes`.

Run part of it only: `--only ssh,firewall` / `--skip aide,endlessh` (`--list-steps` prints the names).
An unknown step name is refused. Exit 0 means every selected step completed or was skipped. Exit 1 means
a step failed or the run stopped early (not root, unsupported OS, aborted, or invalid settings). Exit 2 is
a command-line usage error, including an unknown step name or a missing option value.

## Documentation

| Guide | What it covers |
|---|---|
| [Start here](https://github.com/exceev-consulting/server-prep/wiki/Start-here) | From a rented server to "audit 0 FAIL, panel connected", step by step |
| [Concepts](https://github.com/exceev-consulting/server-prep/wiki/Concepts) | SSH keys, the firewall, Docker and UFW, Tailscale, tunnels, the audit score |
| [VPS or dedicated](https://github.com/exceev-consulting/server-prep/wiki/VPS-or-dedicated) | What changes between a cloud VPS, a dedicated server and a laptop |
| [Panels](https://github.com/exceev-consulting/server-prep/wiki/Panels) | Connect the server to Coolify, Dokploy or Openship |
| [First boot](server-preconfig.md) | `server-preconfig.sh`: SSH, hostname, a network that survives reboots, Tailscale |
| [Cloudflare Tunnel](docs/cloudflare-tunnel.md) | Publish apps with no open port, from Coolify, with a Zero Trust login |
| [Monitoring](docs/monitoring.md) | Server and Docker metrics: Telegraf, InfluxDB and Grafana |
| [Troubleshooting](https://github.com/exceev-consulting/server-prep/wiki/Troubleshooting) | Known problems, their cause and the fix |
| [FAQ](https://github.com/exceev-consulting/server-prep/wiki/FAQ) | Lockouts, re-runs, undo, logs, ports and panels |
| [Working with AI agents](https://github.com/exceev-consulting/server-prep/wiki/Working-with-AI-agents) | Guided setups with Claude Code skills, and what is planned for Codex |

## Supported systems

Tested target: Ubuntu 22.04 / 24.04 / 26.04, Debian 12 / 13, on cloud VPS and on dedicated / on-premise servers.

### VPS or dedicated server

Both work the same way. Only a few details change:

| | VPS | Dedicated / on-premise server |
|---|---|---|
| **Network** | keep the provider's config (netplan / cloud-init): `server-preconfig.sh` doesn't touch it, Enter = `keep` | save it so it survives reboots: `server-preconfig.sh --static-ip current`, or a DHCP reservation on the router |
| **Console if SSH breaks** | the provider's web console | IPMI / iDRAC / iLO / KVM, the host's rescue mode, or a screen and keyboard |
| **Power** | handled by the provider | BIOS *Restore on AC Power Loss* = **Power On** |
| **Reaching it** | public IP: open 80/443 (`EXPOSE_WEB=yes`) or use a tunnel | often behind NAT: Tailscale for SSH and the panel, a Cloudflare Tunnel for the apps |

## What server-prep does

<details>
<summary><b>All 20 steps</b>, in run order. Run some with <code>--only ssh,firewall</code> or skip some with <code>--skip aide,endlessh</code>.</summary>

| Step | Details |
|---|---|
| `update` | apt full-upgrade, base tools (curl, git, jq, ufw, chrony, vim...), timezone |
| `users` | admin user + your SSH key; the panel's key for root, restricted with `from="..."` to the panel's sources |
| `docker` | Docker CE from download.docker.com if missing, container log rotation |
| `firewall` | UFW deny-incoming; SSH only from admin IPs / tailnet / tunnel; optional 80/443; **[ufw-docker](https://github.com/chaifeng/ufw-docker) (pinned, checksum-verified) so published container ports obey UFW** (Docker networking untouched) |
| `ssh` | port 822, keys only, `PermitRootLogin no` + `Match Address <panel sources>` → root key login only from the panel, `AllowUsers`, MaxAuthTries 3, no X11/agent forwarding. **10-minute auto-rollback** until you confirm a new login works |
| `ips` | fail2ban (sshd jail on the right port) + CrowdSec with firewall bouncer (INPUT + DOCKER-USER), panel/admin IPs whitelisted, LAPI moved off 8080 |
| `unattended` | daily security updates (+ Docker CE), optional auto-reboot |
| `sysctl` | ~30 kernel/network parameters, rare protocols blacklisted (Docker/Tailscale compatible) |
| `auth` | sudo log file (`/var/log/sudo.log`), pwquality minlen 12 + complexity, password dictionary built (`cracklib-runtime`) so `passwd` works |
| `services` | disable avahi, cups, bluetooth, ModemManager; mask Ctrl-Alt-Del; optional headless boot |
| `laptop` | laptop used as a server: ignore lid close, mask sleep/suspend |
| `logging` | persistent journald (1 GB cap), swap file if none |
| `auditd` | audit rules: identity files, sudoers, SSH, Docker, cron, firewall, admin root commands |
| `rkhunter` / `aide` | rootkit scan + file-integrity baseline, daily |
| `endlessh` | SSH tarpit on port 22 once SSH has moved |
| `telegraf` | Telegraf metrics agent from the official InfluxData repo (key fingerprint checked); installed but left stopped until you configure it with `extras/telegraf/telegraf.conf.example` ([docs/monitoring.md](docs/monitoring.md)) |
| `telegram` | alert on every SSH login (except ignored users, e.g. the panel's root) + daily report at 09:00 |
| `cloudflared` | install the Cloudflare Tunnel connector with your token. With Coolify, you can run it as a service instead: [docs/cloudflare-tunnel.md](docs/cloudflare-tunnel.md) |
| `suid` | list SUID binaries outside standard paths (review only) |

Where things go (root only): the report in `/root/server-prep-reports/` (with a copy in your home), the log in
`/var/log/server-prep/`, backups and `rollback.sh` in `/var/lib/server-prep/backups/<date>/`, and your answers
(no secrets) in `/etc/server-prep/server-prep.conf`.

</details>

<details>
<summary><b>The audit</b>: what <code>server-audit.sh</code> checks and how it differs from vps-audit.</summary>

`server-audit.sh` is read-only. It writes text, Markdown, JSON and TSV, and exits with `1` when any check FAILs.

```bash
sudo ./server-audit.sh --md audit.md --json audit.json
```

It is a rework of [vps-audit](https://github.com/nuver-labs/vps-audit) v0.2.0. It reads sshd's effective config
(`sshd -T`), counts a port as exposed only when the bind address and the firewall both allow it, detects Docker
bypassing UFW, separates security updates from regular ones, and adds CrowdSec, fail2ban, sysctl, AppArmor,
auditd, rkhunter, AIDE, account and Docker checks plus a panel-readiness section.

</details>

## Safety

- Make sure you can reach a console before you start: the provider's web console, IPMI/KVM, rescue mode or a screen.
- Add your SSH key before the SSH step: password login is turned off.
- `--dry-run` changes nothing, and every step can be re-run safely.
- Found a security problem? Report it privately: see [SECURITY.md](SECURITY.md).

## Community

- **Questions:** [Q&A](https://github.com/exceev-consulting/server-prep/discussions/categories/q-a). **Ideas:** [Ideas](https://github.com/exceev-consulting/server-prep/discussions/categories/ideas). **Your setup or a compatibility report:** [Show and tell](https://github.com/exceev-consulting/server-prep/discussions/categories/show-and-tell).
- **Bugs:** [Issues](https://github.com/exceev-consulting/server-prep/issues). **What is next:** the [roadmap board](https://github.com/orgs/exceev-consulting/projects/7).
- Everyone follows the [Code of Conduct](CODE_OF_CONDUCT.md).

## Contributing

Contributions are welcome: tests on other providers and hardware, fixes, more panels and clearer docs.
Read [CONTRIBUTING.md](CONTRIBUTING.md), then pick an item from the board. The *Agent-ready* view lists tasks
that Claude Code or Codex can take on. Changes are listed in [CHANGELOG.md](CHANGELOG.md).

## Credits

`server-audit.sh` is derived from [vps-audit](https://github.com/nuver-labs/vps-audit) (MIT). The UFW/Docker fix
uses [ufw-docker](https://github.com/chaifeng/ufw-docker) (GPL-3.0), downloaded at runtime and not bundled.
Some ideas come from [vps-secure](https://github.com/rockballslab/vps-secure). See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## License

[MIT](LICENSE) © 2026 [Exceev Consulting](https://exceev.com). Built and maintained by Exceev Consulting, who use it
to set up their clients' servers. Need help with yours? [Get in touch](https://exceev.com/contact).
