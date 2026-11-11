# Changelog

Highlights of each release. The full list of merged pull requests is in each
[GitHub release](https://github.com/exceev-consulting/server-prep/releases).

## [Unreleased]

- The setup console, the brand guidelines and the E2E reports moved to <https://server-prep.exceev.com/>. Links to
  the old address, `exceev-consulting.github.io/server-prep/`, redirect there.
- `rollback.sh` could lock you out after a run that moved SSH: SSH went back to its old port (often 22), but UFW,
  which the run turned on, no longer allowed that port, and Endlessh still held port 22 when another run had installed
  it. Before it restarts SSH, it now stops Endlessh whenever it is on and SSH goes back to 22, allows the old SSH port in
  UFW from the same addresses as the run's SSH rule, deletes the Endlessh rule, which would have left the old SSH open
  to everyone on 22, and checks the restored files with `sshd -t`. It starts with a warning to run it from the console,
  not over SSH, and prints what it does not undo.
- With `PANEL=openship`, the daily AIDE check no longer fills with Openship's deploy changes: it now leaves out
  `/var/lib/openship` (except its SSH key folders), `/etc/openship/modules`, the OpenResty configs (`/etc/openresty`,
  `/usr/local/openresty/nginx/conf`) and the certificates certbot rewrites (`live`, `archive`, `csr` and `keys` under
  `/etc/letsencrypt`). Openship's SSH keys, certbot's renewal settings, `renewal-hooks` and `cli.ini` are still
  checked. On the server that runs the Openship API, auditd also logs every change to its SSH key folders
  (`/etc/openship/ssh-keys`, `/var/lib/openship/ssh-keys`, `/var/lib/openship/host-ssh`; `sudo ausearch -k panel`).
  The audit shows both as INFO (`mon.auditd_panel`, `mon.aide_panel`). On a server prepared earlier, set
  `PANEL=openship` in `/etc/server-prep/server-prep.conf` and run:
  `sudo ./server-prep.sh --config /etc/server-prep/server-prep.conf --only aide,auditd --yes`. If AIDE already had a
  baseline, the run's to-do list says how to rebuild it. Other panels get the same files as before.
- `server-audit.sh --json` now writes `"schema_version": 1` right after `version`, so a program can tell when the
  format changes; the other keys do not change. The format is described in [docs/json-output.md](docs/json-output.md):
  every field, what PASS, WARN, FAIL and INFO mean, the score formula, the exit codes and every check id, with a JSON
  Schema in `docs/schemas/server-audit.schema.json`. `./server-audit.sh --help` links to it.
- Fix: on a server set to another language (for example Ubuntu installed in French), `server-audit.sh` reported UFW as
  inactive (FAIL), counted every port as reachable from the internet and found no swap, because `ufw` and `free`
  print those lines in that language. The audit now reads every command's output in English. In `server-prep.sh`, the
  firewall step no longer says CHANGED on every re-run there, the SSH test hint names the right address again, and
  the report shows the firewall status in English, like the audit.
- Each `server-prep.sh` run, applied or dry run, also writes the report as JSON next to the Markdown one
  (`server-prep-report-<host>-<date>.json`, root only, with a copy in your home). An agent or a script can read from it
  which steps changed or failed, the audit before and after, the files changed and what is still to do. Step results use
  stable values (`changed`, `already_ok`, `skipped`, `failed`, `would_change`). The file holds no token and no full
  public key. Both report copies in your home are now written as your user, mode 600. The Markdown report's "Root SSH
  allowed from" row now lists the sources on a run without the users and ssh steps too, as the JSON does.
- The SSH safety check now warns when `ADMIN_IPS` is empty, the firewall is on and SSH is allowed only from the panel's
  IP (`PANEL_ACCESS=public` with `PANEL_IP`) or only through the Cloudflare tunnel (`PANEL_ACCESS=cloudflared`). The
  firewall then blocks the test command with the local IP from your machine, so it says to test from the panel's host
  as root with the panel key or through the tunnel with `cloudflared access ssh` instead, or to add your IP to
  `ADMIN_IPS` and re-run the firewall step. The test command itself is unchanged.
- **Security:** CrowdSec, cloudflared, Telegraf and Tailscale now get their security fixes automatically. They come from
  their own repositories, which unattended-upgrades skipped, so a fix waited until someone upgraded by hand. The
  `unattended` step adds their repositories (new setting `THIRD_PARTY_AUTO_UPDATE`, `yes` by default), and the new audit
  check `upd.third_party` warns when an installed one is left out. Each update restarts that tool for a moment (SSH
  over Tailscale pauses a few seconds). On a server prepared before, run:
  `sudo ./server-prep.sh --config /etc/server-prep/server-prep.conf --only unattended --yes`.
- **Security:** Docker, cloudflared and CrowdSec are now installed only after their repository keys match the
  fingerprints the vendors publish, as Telegraf already was. Only that one key is kept, in `/etc/apt/keyrings/` (a
  file that bundles another key or a secret key is refused), and each repository is pinned at priority 900, so an
  older Ubuntu Pro (ESM) or distro build cannot win. CrowdSec no longer runs its remote install script
  (`curl https://install.crowdsec.net | sh`) as root: server-prep adds the repository itself. If that fails (download,
  wrong key, `apt-get update`), the `ips` step now FAILS instead of quietly installing the old distro CrowdSec. A
  distro CrowdSec is now found by where it comes from, not by its version string, so the Debian 13 and Ubuntu 26.04
  builds (`1.4.6-10`, `1.4.6-10.1`) are replaced too. Re-runs check the keys already in place (Telegraf's too), and
  check and pin a Docker CE or cloudflared installed from its vendor's repository; one installed another way is left
  as it is. Another source for the same repository, such as the `docker.list` of an older Docker guide, is removed
  (backed up first, and `rollback.sh` puts it back): apt refuses one repository listed with two keys. The new audit check `upd.repo_keys` warns when
  an installed Docker CE, CrowdSec, cloudflared or Telegraf is not from its vendor's repository, not pinned at 900,
  or signed by a key without the published fingerprint, when a source has `trusted=yes` (apt then checks no
  signature), and when `gpg` is missing so the keys cannot be checked. On a server prepared before, run
  `sudo ./server-prep.sh --config /etc/server-prep/server-prep.conf --only docker,ips,telegraf,cloudflared --yes`.
- `--dry-run` on a server without `jq` (when `server-preconfig.sh` was not run first) no longer shows the Docker CE
  step as FAILED with "/etc/docker/daemon.json is not valid JSON". The dry run only prints the `jq` install, so the step
  now says it would check that file and merge the log rotation if it is missing.
- `server-audit.sh` now has an INFO check for each of the three steps it did not cover. `sys.laptop` shows whether
  closing the lid is ignored in the logind config and names any sleep target that is not masked. It runs only on a
  machine with a battery or the laptop step's drop-in, because `server-preconfig.sh` masks sleep on every server.
  `mon.telegram` shows whether `/etc/server-prep/telegram.env` is owned by root with mode 600 and whether the SSH
  login hook is in `/etc/pam.d/sshd`, and never reads that file, which holds the bot token.
  `panel.cloudflared` shows whether the `cloudflared` service is active or cloudflared runs as a panel service in a
  container. INFO checks never change the score or the exit code.
- `server-prep.sh --upgrade` updates a downloaded copy to the latest release. It downloads the release files, checks
  each one against the release's `SHA256SUMS`, shows the version change and asks first (`--yes` skips the question,
  `--dry-run` only checks). The old files are kept in `.server-prep-old/`. Nothing is installed on the server: re-run
  the steps the release notes name. In a git clone it tells you to use `git pull`. The audit's `upd.server_prep` hint
  now gives this command.
- New audit check `upd.server_prep`: it compares the server-prep version used on the server with the latest release
  on GitHub. It is INFO, and WARN only when a newer release fixes a security problem, with where to get it. It reads
  the version from `server-prep.sh` next to the audit, or from the last report. `--no-network` skips it.
- The `logging` step no longer adds `/swapfile` to `/etc/fstab` or reports "swap created" when creating the swap
  file fails: it removes the partial file and the step shows FAILED. When `swapon` refuses a `fallocate` swap file
  (some filesystems), it writes the file with `dd` instead.
- The `/new-server` guide checks SSH journal entries and panel connection settings when validation fails.
- `server-preconfig.sh --check --json` prints the result as one JSON object, so an agent can read it instead of colored
  text. The object holds facts about the server (OS, VM or bare metal, network manager, Tailscale) and each check with
  an id, a status and, when the script knows it, how to fix it. The lines for people go to stderr, and the exit code
  does not change. WARN and FAIL lines now show their fix on a separate `fix:` line.
- The SSH safety check now also prints the test command with the server's Tailscale IP when `PANEL_ACCESS` includes
  `tailscale`. When `ADMIN_IPS` is empty and the firewall is on, it shows only that command, because the firewall blocks
  SSH on the local IP. Before, it showed only the local IP, so with Tailscale-only access the test timed out and could
  lead to a wrong answer. It also reminds you to keep the current terminal open. Without Tailscale, or when
  `tailscale ip -4` gives no address, the test command is unchanged; with Tailscale-only access and the firewall on, a
  second line warns that the firewall may block it and says to check `tailscale status` first.
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
- **Security fix:** the audit's "Exposed TCP ports" check listed a port as firewalled when a UFW application profile
  opened it (`ufw allow OpenSSH`, `ufw allow 'Nginx Full'`), so it did not count ports open to the internet. It now
  reads the ports of profile rules, including IPv6 copies and long profile names. A rule that opens a whole protocol
  (`ufw allow proto tcp from any to any`, shown as `Anywhere/tcp`) now counts too. On servers with such rules the count
  can rise to a WARN (4 ports or more) or a FAIL (6 or more); on a FAIL, `server-audit.sh` exits 1. Servers set up
  only by server-prep are not affected: its firewall step adds port rules, not profiles.
- `server-prep.sh` exits 1 when a step fails or the run stops early, and an unknown `--only` or
  `--skip` name exits 2 with the valid steps.
- Avoid an unset-variable error when `server-prep.sh` is passed to bash through standard input or `bash -c`.
- Do not look for `server-audit.sh` in the current folder when `server-prep.sh` comes from standard input or `bash -c`.
- [Wiki](https://github.com/exceev-consulting/server-prep/wiki): beginner path, concepts, panels, troubleshooting, FAQ,
  glossary, architecture and roadmap. Its source lives in `wiki/` and `.github/workflows/wiki.yml` publishes it.
- Codex and other coding agents now get the project rules: they live in a new `AGENTS.md` (project map, safety rules,
  commands, script conventions, a definition of done and the problems already fixed), which `CLAUDE.md` imports for
  Claude Code. `docs/` and `.github/` each get a short `AGENTS.md` with their own rules.
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
- Codex now finds the four skills (`new-server`, `audit-review`, `monitoring`, `add-step`): `.agents/skills` is a link
  to `.claude/skills`, so Claude Code and Codex read the same files. In Codex, type `$new-server` or pick a skill from
  `/skills`. On Windows, clone with symlinks turned on (see `AGENTS.md`).

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
