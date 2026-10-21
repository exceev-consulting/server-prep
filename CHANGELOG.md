# Changelog

Highlights of each release. The full list of merged pull requests is in each
[GitHub release](https://github.com/exceev-consulting/server-prep/releases).

## [Unreleased]

- The `update` step also installs `vim`. Fresh Debian servers only ship `vim-tiny` (or `nano`).
- New guide [docs/cloudflare-tunnel.md](docs/cloudflare-tunnel.md): publish apps through a Cloudflare Tunnel
  run from Coolify's Cloudflared template, close 80/443, and put a Zero Trust login in front of admin tools.
- New guide [docs/monitoring.md](docs/monitoring.md): server and Docker metrics with Telegraf, InfluxDB 2.8
  and Grafana, through Cloudflare Access with a service token.
- `extras/telegraf/telegraf.conf.example`: one complete Telegraf config (system + Docker metrics, Cloudflare
  Access headers, secrets from `/etc/default/telegraf`). It replaces `influxdb.conf.example`: if a server has
  `/etc/telegraf/telegraf.d/influxdb.conf`, delete it when switching, or metrics are sent twice.
- The `telegraf` step's to-do now tests with `--once`, which really sends data, after loading the
  secrets from `/etc/default/telegraf`.
- Releases also ship `telegraf.conf.example`, and the scripts' messages link to the guides on GitHub, so a
  release download (without the repo) has everything they mention.

## [1.1.1] - 2026-10-19

- Fix: changing a password failed with "BAD PASSWORD: ... error loading dictionary". The `update` and `auth`
  steps now install `cracklib-runtime` and build the password dictionary. New audit check `acc.password_dict`.
- **Security fix:** on a server where Docker was already running, the ufw-docker rules were skipped, so published
  container ports (80/443...) still bypassed UFW. The firewall step now always applies them and checks they are loaded.
  Re-run it on servers set up with 1.1.0: `sudo ./server-prep.sh --config /etc/server-prep/server-prep.conf --only firewall --yes`.

## [1.1.0] - 2026-10-19

First public release.

- **`server-preconfig.sh`**: first setup of a new server. SSH + sudo, hostname, network saved so it survives reboots,
  no sleep, Tailscale. It ends with a check that the server will come back on its own after a reboot or a power cut.
- **`server-prep.sh`**: secures the server step by step, with questions or from a config file.
  - SSH with keys only on a new port, with a 10-minute auto-rollback until you confirm a new login works.
  - UFW firewall that also covers Docker ports ([ufw-docker](https://github.com/chaifeng/ufw-docker), pinned and checksum-verified).
  - fail2ban and CrowdSec, automatic security updates, safer kernel settings, auditd, rkhunter, AIDE.
  - Optional: Telegraf, Telegram login alerts, Cloudflare Tunnel, SSH tarpit.
  - `--dry-run`, a backup of every file it changes, and a Markdown report.
- **`server-audit.sh`**: read-only security and panel-readiness check (console, text, Markdown, JSON, TSV).
  It runs before and after server-prep, so you see what changed.
- **Works with any panel** that manages servers over SSH with a key: Coolify, Dokploy, Openship...
- **VPS or dedicated server**: Ubuntu 22.04 / 24.04 / 26.04 and Debian 12 / 13.
- Claude Code context and skills for guided setups.
