# Changelog

Highlights of each release. The full list of merged pull requests is in each
[GitHub release](https://github.com/exceev-consulting/server-prep/releases).

## [Unreleased]

- The `logging` step no longer adds `/swapfile` to `/etc/fstab` or reports "swap created" when creating the swap
  file fails: it removes the partial file and the step shows FAILED. When `swapon` refuses a `fallocate` swap file
  (some filesystems), it writes the file with `dd` instead.
- The `/new-server` guide checks SSH journal entries and panel connection settings when validation fails.
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
- **Security fix:** the firewall step said CHANGED even when the ufw-docker rules could not be set up (download blocked,
  checksum mismatch, `ufw-docker install` failed, or rules not loaded), so Docker-published ports could still bypass UFW.
  The step now shows FAILED, the report says whether Docker ports still bypass UFW, and `server-prep.sh` exits 1.
  Scripts that run it will now see this failure. A re-run that changes nothing now shows `OK (already)` instead of
  CHANGED.
- **Security fix:** the audit's "Docker vs firewall" check passed when the DOCKER-USER chain only had CrowdSec or
  manual DROP rules, even though published container ports still bypassed UFW. It now passes only when the ufw-docker
  rules are loaded, with both the `ufw-user-forward` and `ufw-docker-logging-deny` jumps (or Docker's iptables
  management is off). If a server now shows this FAIL, re-run the firewall step:
  `sudo ./server-prep.sh --config /etc/server-prep/server-prep.conf --only firewall --yes`.
- Stop interactive `server-prep.sh` runs when no terminal can be opened, instead of silently accepting defaults. `--yes` still works without a terminal.
- End-to-end tests ([docs/e2e-tests.md](docs/e2e-tests.md)): every supported system boots in a KVM virtual machine
  from its official cloud image and goes through `server-preconfig.sh`, a dry run, the interactive questions, a real
  run, SSH and Docker-vs-firewall checks from outside, a second run that must change nothing, and a reboot, with the
  audit at each stage. `main` and pull requests (from forks: only those of collaborators) get an HTML report on
  GitHub Pages ([latest](https://exceev-consulting.github.io/server-prep/e2e/main/)). The setup console links to
  them (**Test reports**), and `tests/e2e/preview.sh` shows the same pages from a local run.
- Security: on Debian, where UFW is not installed by default, container ports published with `-p` bypassed UFW until
  the first reboot. The ufw-docker rules were written, but `systemctl restart ufw` did not load them. server-prep now
  loads them with `ufw reload`. Found by the new end-to-end tests.
- After a UFW reload, CrowdSec's bans covered the server again but not container ports: the reload removes the bouncer's
  rule from the DOCKER-USER chain. server-prep restarts the bouncer after reloading UFW, and `server-audit.sh` WARNs
  (`ips.crowdsec_bouncer`) when the rule is missing.
- Ubuntu 22.10+ (sshd started by `ssh.socket`): the SSH step could fail with "Address already in use" and roll back,
  and the rollback could then leave no SSH at all. server-prep now stops sshd before it restarts `ssh.socket`, and both
  rollback scripts do the same. If the restart that closes the old SSH port fails, the step rolls back too.
- `server-preconfig.sh` enables `ssh.socket` instead of `ssh.service` where sshd is socket-activated, and `--check`
  accepts it. Enabling both made the later port change fail.
- Rollbacks: when the SSH restart failed, the 10-minute rollback timer stayed armed and could undo a re-run made in
  the meantime; it is now stopped, like any timer left by an earlier run. `rollback.sh` stops the Endlessh tarpit before
  SSH goes back to port 22, and restarts the CrowdSec bouncer after its UFW reload.
- Ubuntu 24.04: the Endlessh tarpit never ran. Its packaged unit hides `/run`, which systemd 255 can't set up, so it
  exited at once (226/NAMESPACE) while the step reported CHANGED, and a re-run FAILED. server-prep's override now hides
  only `/var` and makes the rest read-only, and the step checks that port 22 really listens.
- Ubuntu 22.04: apport kept running after the services step "disabled" it, so `fs.suid_dumpable` could go back to 2
  and every re-run reported the step as CHANGED. For a unit made from an init script, `systemctl disable --now` does not
  stop it: server-prep now stops it in a second call.
- The default admin user `admin` could not be created on Ubuntu: its cloud images already have an `admin` group, so
  `useradd` refused and the users step FAILED with no reason given. The user now joins that group, and a failure says why.
- `server-prep.sh` exits 1 when a step fails or the run stops early, and an unknown `--only` or
  `--skip` name exits 2 with the valid steps.
- Avoid an unset-variable error when `server-prep.sh` is passed to bash through standard input or `bash -c`.
- Do not look for `server-audit.sh` in the current folder when `server-prep.sh` comes from standard input or `bash -c`.
- [Wiki](https://github.com/exceev-consulting/server-prep/wiki): beginner path, concepts, panels, troubleshooting, FAQ,
  glossary, architecture and roadmap. Its source lives in `wiki/` and `.github/workflows/wiki.yml` publishes it.
- Discussions forms for Q&A, Ideas and Show and tell (setups and compatibility reports).
- [Brand guidelines](https://exceev-consulting.github.io/server-prep/brand/) on the setup console site: the logo, its
  files to copy, the colours, type, interface parts and voice. Links to the repository and the site now show a preview
  card, the site has an iPhone home-screen icon and a PNG favicon for older browsers, and its colours live in one file,
  `site/tokens.css`. `scripts/check-tokens.sh` fails CI when a copy of them drifts. The setup console now loads
  IBM Plex Mono SemiBold, so its name in the top bar matches the logo.
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
- New `./server-prep.sh --config FILE --validate` checks a config file before a run, without root and without running
  it. It prints one line per problem with its line number and what to do (an unknown setting with a "did you mean", a
  bad yes/no value, access method, port, IP, time or admin user name, a placeholder or private key, a secret left in the
  file or pasted into the wrong setting, such as the Telegram bot token as the chat id, a line or value that would run a
  command, even through escapes or invisible control characters) and exits 1 when there is an error. It never prints a
  secret.

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
