# Changelog

Highlights of each release. The full list of merged pull requests is in each
[GitHub release](https://github.com/exceev-consulting/server-prep/releases).

## [Unreleased]

- The daily Telegram report now shows `rkhunter warnings: 0` for a clean log, without an extra `-` line.
- **Security fix:** server-prep no longer writes secrets to a readable log or shows them on screen. The Cloudflare tunnel
  token shows as `***` in the log and in `--dry-run` output. `/var/log/server-prep/` is now readable by root only
  (folder 700, logs 600), and the next run also fixes the folder and the old logs of servers set up before. The CrowdSec
  enroll key is typed hidden. `server-prep-notify` gives the Telegram bot token to curl on standard input instead of on
  its command line, where `ps` showed it. To update that script, run its step again; it keeps the bot token already
  installed: `sudo ./server-prep.sh --config /etc/server-prep/server-prep.conf --only telegram --yes`. New audit check
  `mon.prep_secrets` warns while the log folder or the Telegram script is still in its old state.
  Logs from 1.1.1 and older could be read by every local user and can hold the tunnel token. If one of them left the
  server (pasted, copied, backed up), rotate the token: refresh it on your tunnel in Cloudflare Zero Trust, run
  `sudo cloudflared service uninstall` from a session that does not go through the tunnel, then
  `sudo ./server-prep.sh --config /etc/server-prep/server-prep.conf --only cloudflared` and type the new token at the
  hidden prompt.
- `server-prep.sh` exits 1 when a step fails or the run stops early, and an unknown `--only` or
  `--skip` name exits 2 with the valid steps.
- Avoid an unset-variable error when `server-prep.sh` is passed to bash through standard input or `bash -c`.
- Do not look for `server-audit.sh` in the current folder when `server-prep.sh` comes from standard input or `bash -c`.
- [Wiki](https://github.com/exceev-consulting/server-prep/wiki): beginner path, concepts, panels, troubleshooting, FAQ,
  glossary, architecture and roadmap. Its source lives in `wiki/` and `.github/workflows/wiki.yml` publishes it.
- Discussions forms for Q&A, Ideas and Show and tell (setups and compatibility reports).
- New logo: a keyhole cut out of one rounded tile, black on light and white in dark mode. In the README
  and the setup console (with an SVG favicon that follows the browser theme). Files in `.github/assets/`.
- New [setup console](https://exceev-consulting.github.io/server-prep/) (`site/`): pick a VPS or a dedicated
  server, a panel (Coolify, Dokploy, Openship) and an access route, and see the open ports, who can log in, every
  step, the commands in order and a ready config file. Its data is generated from the scripts by
  `scripts/gen-data.sh`, and CI checks it stays in sync.
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
