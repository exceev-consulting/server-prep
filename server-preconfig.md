# server-preconfig: first setup of a new server

Run `server-preconfig.sh` **once, right after installing Debian/Ubuntu, before `server-prep.sh`**. It makes the server reachable and makes sure it **comes back on its own** after a reboot or a power cut: network, SSH and Tailscale.

| What it does | Why |
|---|---|
| Installs `openssh-server sudo curl jq iputils-ping` (only the missing ones), and starts and enables SSH | A Debian install without the "SSH server" option refuses connections |
| Puts the admin user in the `sudo` group, and can add its SSH keys from `github.com/<login>.keys` | If a root password is set during install, Debian creates the user **without** sudo |
| Sets the hostname, plus `/etc/hosts` and the Tailscale name | Your panel, monitoring (host/bucket) and Tailscale all use it. `/etc/hosts` stops the "unable to resolve host" warning |
| Saves the network in `/etc/network/interfaces.d/<iface>` (fixed IP or DHCP) and disables older definitions | An IP set by hand is **lost at reboot**, which means no internet, no Tailscale and no SSH |
| Masks sleep, suspend and hibernate, and makes logind ignore idle | A server must never go to sleep |
| Installs Tailscale and logs it in (login URL, or `TS_AUTHKEY`) | The panel and the admins reach the server through the tailnet, whatever the LAN IP |
| **Checks** that everything will come back after a reboot | You find problems before the reboot, not after |

**VPS or dedicated server:**
- **On a VPS**, the provider manages the network (netplan / cloud-init). The script doesn't touch it: press Enter (`keep`) at the network question. You mostly get SSH + sudo, the hostname and Tailscale.
- **On a dedicated or on-premise server**, saving the network and disabling sleep are what make it come back after a reboot or a power cut.

It only changes what is needed and can be re-run. Changed files are backed up to `/var/lib/server-prep/backups/preconfig-<date>/`.

## 1. Get the script onto the server

You need SSH on the LAN, or the console.

- **SSH already works on the LAN** (password login):
  ```bash
  # from your workstation, in the repo folder
  scp -r . <user>@<lan-ip>:~/server-prep
  ```
- **SSH refused**: at the console, as root, run `apt install -y openssh-server`, then use `scp` as above.
- **Internet works on the server**: `git clone https://github.com/exceev-consulting/server-prep.git`

## 2. Run it

```bash
cd ~/server-prep
sudo ./server-preconfig.sh            # no sudo yet? su - -c "$HOME/server-prep/server-preconfig.sh"
```

**The questions** (Enter = default):

| Question | Answer |
|---|---|
| Admin user | your user (default: the one running sudo) |
| GitHub login | e.g. `octocat` to add your workstation's key (it must be on GitHub), or Enter to skip and use `ssh-copy-id` |
| Hostname | e.g. `web-01` (a-z, 0-9, hyphens) |
| Network to save | `current` = keep the current IP as a fixed IP · `192.168.1.50/24` · `dhcp` · `keep`. The default is `current` when the IP isn't saved, otherwise `keep` |
| Gateway | default: the current one |
| Tailscale | `yes`. Open the printed URL on your workstation and approve the machine |

Without questions:
```bash
sudo ./server-preconfig.sh --hostname web-01 --static-ip current --github-keys octocat --yes
```
Other options: `--dry-run` previews the changes, `--check` only runs the checks, `--check --json` gives the checks as JSON
for an agent or a script (section 3), and `--help` lists everything.

## 3. Read the result

When a `WARN` or `FAIL` has a known fix, a `fix:` line under it says what to do.

| Line | Meaning |
|---|---|
| `OK eno1 saved as static (192.168.1.50/24)` | the network will come back after a reboot |
| `FAIL eno1 is not saved` | re-run with `--static-ip current` (or `dhcp`) |
| `OK networking / ssh / tailscaled enabled at boot` | the services start by themselves |
| `OK sleep/suspend/hibernate masked` | it never goes to sleep |
| `WARN Tailscale key expires <date>` | Tailscale admin console → Machines → the server → `…` → **Disable key expiry**, otherwise access is cut on that date |
| `WARN <user> has no SSH key` | from your workstation: `ssh-copy-id <user>@<tailscale-ip>` (needed: server-prep disables password login) |

**Two things the script can't do:**
1. **BIOS:** set *Restore on AC Power Loss* to **Power On**, or the server stays off after a power cut.
2. **Router:** a fixed IP must be **outside the DHCP range**, or reserved for this server.

### For an agent: `--check --json`

```bash
sudo ./server-preconfig.sh --check --json > preconfig.json
jq '.checks[] | select(.status == "FAIL")' preconfig.json    # what blocks the reboot
```

- **stdout** holds one JSON object, on one line. **stderr** gets the usual lines for people.
- The **exit code** is the same as without `--json`: 0, or 1 when a check FAILs.
- `--json` without `--check` exits 2.
- There is **no JSON** when the script stops before the checks (not Debian/Ubuntu, or the `ip` command missing).
  It then exits 1 with a message on stderr.
- Without sudo, `root` is `false` and some checks are approximate: the admin's SSH keys, for example, can't be read.

| Field | Meaning |
|---|---|
| `tool` | `server-preconfig` |
| `schema_version` | `1`, the version of this format |
| `date` | when the checks ran, ISO 8601 with the time zone offset (`2026-01-15T10:30:00+01:00`) |
| `root` | `true` when run as root |
| `facts.os` | `PRETTY_NAME` from `/etc/os-release` |
| `facts.virt` | `systemd-detect-virt`: `none` = bare metal, `kvm`, `xen`, `microsoft`... = a VM, `unknown` when the command is missing. With `net_manager`, it tells a VPS from a dedicated server |
| `facts.net_manager` | `ifupdown`, `netplan`, `NetworkManager`, `systemd-networkd` or `unknown` |
| `facts.iface`, `facts.cidr`, `facts.gateway` | the interface with the default route, its IP and the gateway |
| `facts.tailscale_state`, `facts.tailscale_ip` | Tailscale's state (`Running` when connected) and its IPv4 address |
| `facts.admin` | the admin user the checks looked at |
| `summary.pass`, `.warn`, `.fail`, `.info` | how many checks have each status. `fail` and `warn` match the `N FAIL, N WARN` line |
| `checks[].id` | a stable id, see the next table |
| `checks[].status` | `PASS`, `WARN`, `FAIL` or `INFO`. The console prints `OK` for `PASS` and `->` for `INFO` |
| `checks[].message` | the line for people |
| `checks[].fix` | what to do, for a WARN or a FAIL when the script knows the fix |

A fact that was not found, and a check without a fix, is `""`.

| Id | What it checks | Statuses | When it appears |
|---|---|---|---|
| `pre.hostname` | the hostname is in `/etc/hosts` | PASS, WARN | always |
| `pre.net_saved` | the network is saved for reboots | PASS, FAIL | always, except when `pre.net_valid` FAILs. On netplan, NetworkManager or systemd-networkd it is the only network check: `network managed by <name>` |
| `pre.net_valid` | ifupdown accepts the interface config | FAIL | ifupdown, only when it fails |
| `pre.net_ip_match` | the saved fixed IP is the IP the server has now | WARN | ifupdown, only when they differ |
| `pre.net_source` | `/etc/network/interfaces` reads `interfaces.d` | FAIL | ifupdown, only when it fails |
| `pre.net_boot` | `networking` starts at boot | PASS, FAIL | ifupdown |
| `pre.gateway` | the gateway answers ping | PASS, WARN | always |
| `pre.internet` | `ping 1.1.1.1` answers | PASS, FAIL | always |
| `pre.dns` | `debian.org` resolves | PASS, FAIL | always |
| `pre.dns_upstream` | Tailscale DNS has an upstream server | PASS, WARN | only with Tailscale DNS (MagicDNS) |
| `pre.ssh_boot` | `ssh` starts at boot | PASS, FAIL | always |
| `pre.tailscaled_boot` | `tailscaled` starts at boot | PASS, FAIL | Tailscale installed |
| `pre.sleep` | sleep, suspend and hibernate are masked | PASS, WARN | always |
| `pre.tailscale` | Tailscale is connected | PASS, FAIL, WARN (not installed) | always |
| `pre.tailscale_expiry` | the Tailscale key never expires | PASS, WARN | Tailscale connected |
| `pre.admin_sudo` | the admin user is in the `sudo` group | PASS, FAIL | the admin user exists |
| `pre.admin_keys` | the admin user has an SSH key | PASS, WARN, INFO (not root: the keys can't be read) | the admin user exists |
| `pre.bios` | reminder: *Restore on AC Power Loss* | INFO | always |
| `pre.router` | reminder: a fixed IP must be outside the DHCP range | INFO | ifupdown with a fixed IP |

Example on a dedicated server, spread over several lines here (the script prints one line):

```json
{
  "tool": "server-preconfig",
  "schema_version": 1,
  "date": "2026-01-15T10:30:00+01:00",
  "root": true,
  "facts": {
    "os": "Debian GNU/Linux 13 (trixie)",
    "virt": "none",
    "net_manager": "ifupdown",
    "iface": "eth0",
    "cidr": "192.168.1.50/24",
    "gateway": "192.168.1.1",
    "tailscale_state": "Running",
    "tailscale_ip": "100.x.y.z",
    "admin": "admin"
  },
  "summary": {"pass": 12, "warn": 1, "fail": 0, "info": 2},
  "checks": [
    {"id": "pre.hostname", "status": "PASS", "message": "hostname web-01 (in /etc/hosts)", "fix": ""},
    {"id": "pre.net_saved", "status": "PASS", "message": "eth0 saved as static (192.168.1.50/24)", "fix": ""},
    {"id": "pre.net_boot", "status": "PASS", "message": "networking enabled at boot", "fix": ""},
    {"id": "pre.gateway", "status": "PASS", "message": "gateway 192.168.1.1 reachable", "fix": ""},
    {"id": "pre.internet", "status": "PASS", "message": "internet reachable", "fix": ""},
    {"id": "pre.dns", "status": "PASS", "message": "DNS works", "fix": ""},
    {"id": "pre.ssh_boot", "status": "PASS", "message": "ssh enabled at boot", "fix": ""},
    {"id": "pre.tailscaled_boot", "status": "PASS", "message": "tailscaled enabled at boot", "fix": ""},
    {"id": "pre.sleep", "status": "PASS", "message": "sleep/suspend/hibernate masked", "fix": ""},
    {"id": "pre.tailscale", "status": "PASS", "message": "Tailscale connected: 100.x.y.z (web-01)", "fix": ""},
    {"id": "pre.tailscale_expiry", "status": "WARN", "message": "Tailscale key expires 2026-07-14",
     "fix": "Tailscale admin console -> Machines -> web-01 -> ... -> Disable key expiry"},
    {"id": "pre.admin_sudo", "status": "PASS", "message": "admin in the sudo group", "fix": ""},
    {"id": "pre.admin_keys", "status": "PASS", "message": "admin has 1 SSH key(s)", "fix": ""},
    {"id": "pre.bios", "status": "INFO", "message": "BIOS (cannot be checked from Linux): 'Restore on AC Power Loss' = Power On", "fix": ""},
    {"id": "pre.router", "status": "INFO", "message": "router: the fixed IP must be outside the DHCP range (or reserved)", "fix": ""}
  ]
}
```

**Privacy:** the output holds internal IPs, the admin user and the hostname. Remove them before you post it publicly,
in an issue for example.

## 4. Reboot test, then server-prep

```bash
sudo reboot
# ~2 minutes later, from your workstation:
ssh <user>@<tailscale-ip> 'hostname; ip -br a show eno1; ping -c2 debian.org'
```
If that works, the server comes back on its own. Continue with `server-prep.sh` (README.md, or `/new-server` in Claude Code).

## Troubleshooting (seen on real servers)

| Symptom | Cause | Fix |
|---|---|---|
| `Connection refused` on SSH | `openssh-server` is not installed | at the console: `apt install -y openssh-server` |
| `Permission denied` as root | Debian refuses root password login over SSH | log in with your user |
| `Could not open lock file … are you root?` | `sudo a && b`: only `a` runs as root | `sudo a && sudo b` |
| `Authentication failed` at `[sudo: authenticate]` | a token or the next command was typed or pasted at **sudo's** prompt | type the server password, and run commands one at a time |
| `sudo: unable to resolve host <name>` | hostname changed before `/etc/hosts` | harmless. The script updates `/etc/hosts` first |
| No internet or SSH after a power cut | IP set by hand, never saved | `sudo ./server-preconfig.sh --static-ip current` |
| `Some peers are advertising routes but --accept-routes is false` | another device shares a subnet | ignore. Don't enable `--accept-routes` on a LAN server |
| Machine not visible in Tailscale | logged in with another account, or waiting for approval | `tailscale switch --list`, or approve it in Machines |
| `/etc/resolv.conf` says "generated by tailscale" | MagicDNS (100.100.100.100) | normal. The upstream DNS is in `/etc/resolv.pre-tailscale-backup.conf` |
