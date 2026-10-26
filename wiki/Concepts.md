The ideas behind server-prep, in simple words: what each protection does, why it is there, and how to check it on your server.

## How to read this page

Each section says what the idea is, what server-prep does, and gives one read-only command to check it. Words in *italics* are in the [Glossary](Glossary).

## SSH keys, and why passwords are off

SSH is how you open a terminal on the server from your own computer. You can log in with a password or with an *SSH key*. A key is a pair of files: the private key stays on your computer, the public key goes on the server. Bots try millions of passwords on servers all day. They cannot guess a key.

server-prep does two things in the `users` and `ssh` steps:

- it adds your public key (`ADMIN_PUBKEY`) to your admin account;
- it turns password login off (`PasswordAuthentication no`, `KbdInteractiveAuthentication no`, `AuthenticationMethods publickey`).

Only the users listed in *AllowUsers* can log in. **Add your key before the SSH step**: without it, you can only log in from the console afterwards.

```bash
sudo sshd -T | grep -E '^(passwordauthentication|pubkeyauthentication|allowusers)'
```

You should see `passwordauthentication no`, `pubkeyauthentication yes` and your user name after `allowusers`.

## The new SSH port and the 10-minute auto-rollback

SSH usually listens on port 22, the first port every scanner tries. server-prep moves it to `SSH_PORT`, 822 by default. Ports below 1024 can only be opened by root, so a normal program cannot take the SSH port. The audit passes any port that is not 22.

Moving SSH could cut you off, so the `ssh` step works in two phases:

1. **Phase A.** sshd listens on the old port **and** the new port. The script starts a timer: in 10 minutes, the old SSH config comes back by itself.
2. You open a **new** terminal and test `ssh -p 822 <user>@<server>`. You answer `y` (it works), `n` (roll back now) or `s` (skip, I have console access).
3. **Phase B.** After `y` or `s`, the timer stops, sshd listens only on the new port, and the temporary firewall rule for the old port is removed.

**Known limit:** with `--yes`, the script does not wait for your test, so the timer stops right away. A fix is planned in [issue #65](https://github.com/exceev-consulting/server-prep/issues/65). Until then, change SSH interactively, or have console access.

Once SSH has moved, the `endlessh` step can put a *tarpit* on port 22: bots that still knock there get stuck on a very slow fake SSH banner.

```bash
sudo sshd -T | grep '^port'
```

You should see one line, `port 822` (or your `SSH_PORT`). Two lines mean the old port is still open.

## UFW: deny by default

A firewall decides which connections can reach the server. server-prep uses *UFW*, the simple firewall of Ubuntu and Debian. The `firewall` step sets:

- **incoming: deny** everything, unless a rule allows it;
- **outgoing: allow**, so the server can download updates and images;
- **SSH** only from your `ADMIN_IPS`, from the tailnet (`tailscale0`) and from the panel IP, depending on `PANEL_ACCESS`. With no source at all, SSH is open to everyone but rate-limited;
- **80/443** only when `EXPOSE_WEB=yes`, and any `EXTRA_PORTS` you list.

```bash
sudo ufw status verbose
```

You should see `Default: deny (incoming), allow (outgoing)` and one line per allowed port and source.

## Why Docker bypasses UFW, and how ufw-docker fixes it

This is the surprise that bites most people. When a container publishes a port (for example `-p 5432:5432`), Docker writes its own firewall rules. Those rules are checked **before** UFW's. So `ufw status` says the port is closed, but the internet can still reach the database.

server-prep installs [ufw-docker](https://github.com/chaifeng/ufw-docker), a small script that adds rules to the *DOCKER-USER* chain. That chain is the place Docker leaves for your own rules. After that, traffic to containers goes through UFW too. Docker networking between containers is not changed. The script is pinned to one version and its checksum is checked before it runs.

```bash
sudo iptables -S DOCKER-USER
```

You should see a line with `-j ufw-user-forward`. If it is missing, the audit shows a FAIL on "Docker vs firewall": re-run the firewall step (see [FAQ](FAQ)).

## fail2ban and CrowdSec

Both watch the logs and block addresses that attack the server. They work in different ways, and server-prep can run both (the `ips` step).

| | fail2ban | CrowdSec |
|---|---|---|
| How it decides | counts failed logins on this server | uses its own detections **plus** a shared list of known bad IPs from other users |
| What blocks | its own firewall rules | a separate *bouncer* (the firewall bouncer) |
| server-prep settings | `sshd` jail on your SSH port, ban 1 hour, up to 1 week for repeat offenders | collections `linux` and `sshd`, bouncer on INPUT and DOCKER-USER, *LAPI* moved to port 8091 |

Your admin IPs, the panel IP, the tailnet and localhost are on the allow list of both, so you don't ban yourself. CrowdSec's local API usually uses port 8080, which the panels' Traefik dashboard also wants. That is why server-prep moves it (`CROWDSEC_LAPI_PORT=8091`).

```bash
sudo fail2ban-client status sshd
```

You should see the jail with a count of failed and banned addresses.

## Tailscale

[Tailscale](https://tailscale.com) links your machines in a private network called a *tailnet*. Each machine gets an address in `100.64.0.0/10` (for example `100.101.102.103`). The traffic is encrypted, and it works behind a home or office router with no open port.

`server-preconfig.sh` installs Tailscale and logs the server in. With `PANEL_ACCESS=tailscale`, server-prep lets SSH in on the `tailscale0` interface and allows the panel's root login from tailnet addresses. The panel server must be in the same tailnet.

Turn off **key expiry** for the server in the Tailscale admin console. If you don't, access stops on the expiry date.

```bash
tailscale ip -4
```

You should see the server's tailnet address, starting with `100.`.

## Cloudflare Tunnel

A [Cloudflare Tunnel](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/) publishes your apps **without opening any port**. A small program, `cloudflared`, connects *out* from the server to Cloudflare. Visitors reach Cloudflare, and Cloudflare sends the traffic down the tunnel to `http://localhost:80`, the panel's proxy. Your server's IP stays hidden and 80/443 stay closed (`EXPOSE_WEB=no`).

With Coolify, run cloudflared as a Coolify **service**, not with the server-level "Cloudflare Tunnel" option: that option moves Coolify's own SSH to the tunnel and Coolify can lose the server. The full steps, with *Zero Trust* login in front of admin tools, are in [docs/cloudflare-tunnel.md](https://github.com/exceev-consulting/server-prep/blob/main/docs/cloudflare-tunnel.md).

## The panel logs in as root, only from its route

Panels like Coolify and Dokploy manage the server over SSH as `root`. server-prep allows that, but in a narrow way:

- `PermitRootLogin no` for everyone;
- a *Match Address* block that says `PermitRootLogin prohibit-password` (keys only) **only** for the panel's sources;
- the panel's public key in `/root/.ssh/authorized_keys`, with a `from="..."` option that lists the same sources.

The sources come from `PANEL_ACCESS`:

| `PANEL_ACCESS` | Root allowed from |
|---|---|
| `cloudflared` | `127.0.0.1` and `::1` (the tunnel arrives on the server itself) |
| `tailscale` | `100.64.0.0/10` and `fd7a:115c:a1e0::/48` |
| `public` | `PANEL_IP`, the panel server's public IP |

From any other address, root is refused even with the right key. You log in with your own admin account and use `sudo`.

```bash
sudo sshd -T -C user=root,host=test,addr=203.0.113.7 | grep permitrootlogin
```

You should see `permitrootlogin no`: a random internet address cannot log in as root.

## Automatic security updates

The `unattended` step turns on *unattended-upgrades*: every day, the server installs security updates by itself. With `DOCKER_AUTO_UPDATE=yes`, Docker CE updates are included. Old kernels and unused packages are removed.

Some updates (like a new kernel) need a reboot. `AUTO_REBOOT=yes` reboots by itself at `AUTO_REBOOT_TIME` (04:00). It is `no` by default, because a reboot restarts your apps.

```bash
systemctl status unattended-upgrades --no-pager
```

You should see `active (running)` and `enabled`.

## auditd, rkhunter and AIDE

These three tools don't block anything. They help you see what happened.

- **auditd** writes a log entry when someone changes a sensitive file: users and passwords, sudoers, SSH config, `/root/.ssh`, Docker config, cron, the firewall. It also logs commands that admins run as root. Search by key, for example `sudo ausearch -k sshd`.
- **rkhunter** looks for known rootkits (hidden malware) and changed system programs, every day.
- **AIDE** takes a fingerprint of the system files once (the baseline), then checks every day which files changed. Fast-changing folders like `/var/lib/docker` and `/data/coolify` are left out. The first baseline is built in the background and takes a few minutes.

```bash
sudo auditctl -l
```

You should see the rules, each ending with a key such as `-k identity` or `-k sshd`.

## What the audit score means

`server-audit.sh` runs about 55 checks and gives each one a status:

- **PASS**: good.
- **WARN**: worth a look, not always a problem.
- **FAIL**: a real security gap. The script exits with code 1 when there is at least one FAIL.
- **INFO**: a fact, not scored.

The score is `(PASS × 100 + WARN × 50) / (PASS + WARN + FAIL)`, so 100 means all PASS. A prepared server usually has about 43 PASS and 0 FAIL. Some WARNs are normal: many services on a desktop (GNOME), regular updates waiting, or a reboot pending after a kernel update. Aim for **0 FAIL**, not for 100.

```bash
sudo ./server-audit.sh
```

The last line shows the score, for example `Score: 92/100 - 43 PASS, 8 WARN, 0 FAIL, 4 INFO`. Each WARN and FAIL line shows how to fix it.

## Read next

[Glossary](Glossary) for the terms, [FAQ](FAQ) for lockouts, re-runs and undo, and the [setup console](https://exceev-consulting.github.io/server-prep/) to see the ports and logins for your setup.
