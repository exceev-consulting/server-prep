Short definitions of the words you meet in server-prep, its questions, its report and the audit, from A to Z.

## How to use this page

Each entry says what the word means and, when it matters, what server-prep does with it. For the bigger ideas (why Docker bypasses the firewall, how the SSH rollback works), see [Concepts](Concepts).

## A to D

**AIDE** (Advanced Intrusion Detection Environment). Takes a fingerprint of the system files once, then checks every day which files changed. server-prep's `aide` step installs it and leaves out fast-changing folders such as `/var/lib/docker`.

**AllowUsers**. An SSH setting that lists who may log in. server-prep sets it to your admin user, plus `root@<source>` for each of the panel's sources. Anyone else is refused, even with a valid key.

**apt pin**. A rule that tells apt which repository wins when two offer the same package. server-prep pins CrowdSec to its official repository at priority 900, so an old copy from Ubuntu Pro ESM is not installed instead.

**auditd**. The Linux audit service. It logs changes to sensitive files (users, sudoers, SSH, cron, firewall) and root commands run by admins. Search it with `sudo ausearch -k <key>`.

**Bouncer**. The part of CrowdSec that actually blocks. CrowdSec decides, the bouncer applies the decision in the firewall. server-prep installs the firewall bouncer on the INPUT and DOCKER-USER chains.

**CIDR**. A way to write a range of addresses: `192.168.1.0/24` means `192.168.1.0` to `192.168.1.255`. `ADMIN_IPS` accepts single IPs and CIDR ranges.

**Cloudflare Tunnel / cloudflared**. `cloudflared` is a small program that connects out from your server to Cloudflare. Visitors reach your apps through Cloudflare, with no open port on the server. See [docs/cloudflare-tunnel.md](https://github.com/exceev-consulting/server-prep/blob/main/docs/cloudflare-tunnel.md).

**Console access**. A way to reach the server's screen and keyboard without SSH: the VPS provider's web console, IPMI / iDRAC / iLO / KVM, rescue mode, or a real screen. Have it ready the first time you run server-prep.

**CrowdSec**. An intrusion prevention tool. It reads the logs, detects attacks, and also uses a shared list of bad IPs reported by other users. server-prep installs it from the official repository (`ips` step).

**Docker CE**. The Docker engine from Docker's own repository (download.docker.com). The `docker` step installs it if missing and turns on log rotation (10 MB × 3 files per container).

**DOCKER-USER**. A chain (list of firewall rules) that Docker leaves for your own rules. Docker checks it before its own rules. ufw-docker and the CrowdSec bouncer put their rules there.

**Dry run**. `--dry-run` shows every change the script would make and changes nothing.

## E to M

**endlessh**. An SSH *tarpit*: a fake SSH server on port 22 that answers very slowly, so bots waste time. server-prep installs it only once the real SSH has moved to another port.

**fail2ban**. Watches the logs and bans an address after too many failed logins. server-prep sets an `sshd` jail on your SSH port: 5 tries in 10 minutes, ban 1 hour, longer for repeat offenders.

**Idempotent**. Safe to run again: a second run only does what is still missing. server-prep's steps are written this way.

**journald**. The system log of systemd. The `logging` step makes it persistent (kept after a reboot), capped at 1 GB. Read it with `journalctl`.

**LAPI** (Local API). CrowdSec's internal API. The bouncer talks to it. By default it uses port 8080, which the Traefik dashboard of Coolify and Dokploy also uses, so server-prep moves it to `127.0.0.1:8091` (`CROWDSEC_LAPI_PORT`).

**Match Address**. A block at the end of `/etc/ssh/sshd_config` that changes SSH settings for some source addresses only. server-prep uses it to allow root login with a key only from the panel's sources.

## N to R

**netplan**. The network configuration tool of Ubuntu (files in `/etc/netplan/`). On a VPS, the provider sets it up with cloud-init: `server-preconfig.sh` leaves it alone when you answer `keep`.

**PaaS panel**. A self-hosted web app that deploys your apps on your servers, such as [Coolify](https://coolify.io), [Dokploy](https://dokploy.com) or [Openship](https://openship.io/). It connects to each server over SSH as root, with its own key. `PANEL` holds its name.

**PANEL_ACCESS**. How the panel reaches the server: `cloudflared`, `tailscale` or `public` (you can combine them with commas). It decides where root login is allowed from.

**PermitRootLogin**. The SSH setting for root. server-prep sets `no` for everyone and `prohibit-password` (key only) inside the Match Address block for the panel.

**Port**. A number that tells which program on the server gets a connection: 22 or 822 for SSH, 80 for HTTP, 443 for HTTPS.

**Reverse proxy**. The program that receives web traffic on 80/443 and sends it to the right app. Coolify and Dokploy use Traefik.

**rkhunter** (Rootkit Hunter). Scans every day for known rootkits and changed system programs. Its log is `/var/log/rkhunter.log`.

**Rollback**. Going back to the files from before the run. server-prep stops SSH changes by itself after 10 minutes unless you confirm, and writes a `rollback.sh` next to the backups. See [FAQ](FAQ).

**Root**. The all-powerful account on Linux. With server-prep, only the panel logs in as root, and only from its route.

## S to Z

**SSH key**. A pair of files used to log in instead of a password. The private key stays on your computer, the public key (one line starting with `ssh-ed25519` or `ssh-rsa`) goes on the server.

**sudo**. Runs one command as root from your own account: `sudo <command>`. server-prep logs every sudo command to `/var/log/sudo.log`.

**sudo-rs**. A rewrite of sudo in Rust, used by default on Ubuntu 26.04. It has no log-file option, so server-prep skips that part. It logs every command to the journal (`journalctl _COMM=sudo`) and the audit counts that as PASS.

**SUID**. A flag that lets a program run with its owner's rights (often root). The `suid` step lists SUID files outside the usual places for you to review.

**sysctl**. Kernel settings you can change while the system runs. The `sysctl` step sets about 30 of them, in `/etc/sysctl.d/99-server-prep.conf`.

**Tailnet**. Your private Tailscale network. Its addresses are in `100.64.0.0/10` (IPv4) and `fd7a:115c:a1e0::/48` (IPv6).

**Tailscale**. A service that links your machines in a private, encrypted network, even behind a router. `server-preconfig.sh` installs it.

**UFW** (Uncomplicated Firewall). The simple firewall of Ubuntu and Debian. server-prep sets it to deny incoming traffic by default.

**ufw-docker**. A small script by chaifeng that makes published Docker ports obey UFW, through the DOCKER-USER chain. server-prep downloads one pinned version and checks its checksum.

**unattended-upgrades**. The Debian/Ubuntu service that installs security updates by itself every day. The `unattended` step turns it on.

**Zero Trust / Access**. Cloudflare's login page in front of a website. You can put it in front of admin tools (Grafana, InfluxDB) published through the tunnel.
