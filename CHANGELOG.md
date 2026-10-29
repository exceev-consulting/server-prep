# Changelog

Highlights of each release. The full list of merged pull requests is in each
[GitHub release](https://github.com/exceev-consulting/server-prep/releases).

## [Unreleased]

- End-to-end tests ([docs/e2e-tests.md](docs/e2e-tests.md)): every supported system boots in a KVM virtual machine
  from its official cloud image and goes through `server-preconfig.sh`, a dry run, the interactive questions, a real
  run, SSH and Docker-vs-firewall checks from outside, a second run that must change nothing, and a reboot, with the
  audit at each stage. Pull requests and `main` get an HTML report on GitHub Pages
  ([latest](https://exceev-consulting.github.io/server-prep/e2e/main/)). The setup console links to them (**Test reports**),
  and `tests/e2e/preview.sh` shows the same pages from a local run.
- Security: on Debian, where UFW is not installed by default, container ports published with `-p` bypassed UFW until
  the first reboot. The ufw-docker rules were written, but `systemctl restart ufw` did not load them. server-prep now
  loads them with `ufw reload`, and the firewall step FAILs when they are still not loaded instead of reporting
  CHANGED ([#68](https://github.com/exceev-consulting/server-prep/issues/68)). Found by the new end-to-end tests.
- After a UFW reload, CrowdSec's bans covered the server again but not container ports: the reload removes the bouncer's
  rule from the DOCKER-USER chain. server-prep restarts the bouncer after reloading UFW, and `server-audit.sh` WARNs
  (`ips.crowdsec_bouncer`) when the rule is missing.
- A second `server-prep.sh` run no longer reports the firewall step as CHANGED when its rules did not change.
- Ubuntu 22.10+ (sshd started by `ssh.socket`): the SSH step could fail with "Address already in use" and roll back,
  and the rollback could then leave no SSH at all. server-prep now stops sshd before it restarts `ssh.socket`, and both
  rollback scripts do the same.
- `server-preconfig.sh` enables `ssh.socket` instead of `ssh.service` where sshd is socket-activated, and `--check`
  accepts it. Enabling both made the later port change fail.
- The default admin user `admin` could not be created on Ubuntu: its cloud images already have an `admin` group, so
  `useradd` refused and the users step FAILED with no reason given. The user now joins that group, and a failure says why.
- `server-prep.sh` exits 1 when a step fails or the run stops early, and an unknown `--only` or
  `--skip` name exits 2 with the valid steps.
- Avoid an unset-variable error when `server-prep.sh` is passed to bash through standard input or `bash -c`.
- Do not look for `server-audit.sh` in the current folder when `server-prep.sh` comes from standard input or `bash -c`.
- [Wiki](https://github.com/exceev-consulting/server-prep/wiki): beginner path, concepts, panels, troubleshooting, FAQ,
  glossary, architecture and roadmap. Its source lives in `wiki/` and `.github/workflows/wiki.yml` publishes it.
- Discussions forms for Q&A, Ideas and Show and tell (setups and compatibility reports).
- New logo: a keyhole standing on a terminal cursor, cut out of one rounded tile, black on light and white in dark mode. In the README
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
