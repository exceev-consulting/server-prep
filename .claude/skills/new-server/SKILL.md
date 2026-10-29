---
name: new-server
description: Guide the user through preparing a new Debian/Ubuntu server (VPS or dedicated / on-premise) for a deployment panel (Coolify, Dokploy, Openship...) with server-prep.sh, question by question, from first SSH to final audit. Use when the user sets up, secures or onboards a new server.
---

# Prepare a new server

The user runs every command and pastes the output. You give short, concise, precise guidance at each step: the command or answer, plus one line on why. Read `CLAUDE.md` and `CLAUDE.local.md` (infrastructure, usual answers) first.

## 0. Before starting, ask only what is unknown
- Which OS, and is it a VPS, a bare-metal machine or a laptop?
- Which panel manages it (`PANEL`) and how it reaches the server (`PANEL_ACCESS`; see `CLAUDE.local.md`, usually **tailscale**).
- Do they have console access (provider console or physical)? This is required in case SSH locks them out.
- **IP address:**
  - **VPS:** keep the provider's network config (DHCP or cloud-init). Don't touch it.
  - **On-premise / LAN:** use a **DHCP reservation** on the router (MAC → fixed IP). A static IP on the server is only for when there is no router access, and must be outside the DHCP pool.
  - The panel doesn't depend on it when it uses Tailscale. The fixed LAN IP is for admin SSH, RDP and local access.
  - Change the network config only from the console. A mistake cuts the LAN and Tailscale together.
- **Physical server:**
  - BIOS **Restore on AC Power Loss = Power On**, otherwise it stays off after a power cut.
  - Always SSH with the **Tailscale** IP or name, because the LAN IP can change.
- **Fresh Debian:**
  - `openssh-server` may be missing.
  - Root password login over SSH is refused.
  - `apt install` needs `sudo` on each command (`sudo a && sudo b`).
  - A fixed IP must live in `/etc/network/interfaces.d/<iface>` (`auto` + `inet static` + `gateway`). An IP set by hand is lost at reboot, which means no internet, no Tailscale and no SSH. Check the file with `ifup --no-act <iface>`.
  - `/etc/resolv.conf` is written by Tailscale (100.100.100.100). The upstream DNS is in `/etc/resolv.pre-tailscale-backup.conf`.
  - On a new site, add its LAN (for example `192.168.1.0/24`) to the allowed SSH sources.

## 1. Get the scripts on the server
```bash
# from the admin machine
git clone https://github.com/exceev-consulting/server-prep.git ~/server-prep   # or scp -r it from your workstation
ssh <user>@<server>
cd ~/server-prep && chmod +x server-*.sh
```

## 2. Pre-configuration (fresh server)
```bash
sudo ./server-preconfig.sh          # hostname, SSH + sudo, network saved, no sleep, Tailscale
```
- Answer `current` for the network if the IP isn't saved yet.
- Open the Tailscale URL on the Mac.
- Read the checks: 0 FAIL is required.
- Then do the reboot test it prints, and disable Tailscale key expiry.

The guide and troubleshooting are in `server-preconfig.md`.

## 3. Baseline audit, then a preview
```bash
sudo ./server-audit.sh
sudo ./server-prep.sh --dry-run
```

## 4. Real run: answer the questions

| Question | Usual answer |
|---|---|
| Admin user | their usual user, created if missing |
| Admin public key | the content of `~/.ssh/id_ed25519.pub` **on the admin's Mac**, not on the server |
| Panel | `coolify`, `dokploy`, ... (only used in messages and the report) |
| Panel key | the public part of the SSH key the panel uses for servers (Coolify: Keys & Tokens → Private Keys → the key → Public Key) |
| Access | `tailscale` |
| SSH port | `822`; set the same port on the server in the panel |
| Admin IPs | the office LAN + office and home public IPs (`ADMIN_IPS` in `CLAUDE.local.md`), plus the LAN of the server's site |
| Expose 80/443 | `no` when apps are published through a Cloudflare Tunnel (cloudflared run by the panel), `yes` for a public VPS |
| fail2ban / CrowdSec | yes / yes. The CrowdSec enroll key can be left empty and done later |
| Services to disable | accept the defaults (avahi, cups, bluetooth, ModemManager, apport) |
| Headless | `no` on a desktop the user still uses, `yes` on a pure server |
| auditd / rkhunter / AIDE / endlessh | yes |
| Telegraf | yes. It is configured afterwards with `/monitoring` |
| Telegram | can be done later with `--only telegram` |
| Docker restart | yes, unless important containers are running |

**SSH step:** before confirming, the user must open a **new** terminal and run `ssh -p 822 <user>@<server>`. If they don't confirm, the change rolls back after 10 minutes.

## 5. If a step fails
Re-run only that step:
`sudo ./server-prep.sh --config /etc/server-prep/server-prep.conf --only <step> --yes`.

Check the known fixes in `CLAUDE.md` → *Hard-won gotchas*. The log is in `/var/log/server-prep/` and only root can read it, so ask the user to paste the errors of the last run:
`sudo sh -c 'grep -n -i -E "error|fail|warn" "$(ls -t /var/log/server-prep/run-*.log | head -1)"'`.
Logs from 1.1.1 and older can hold the tunnel token: ask them to check the lines before pasting.

## 6. Connect to the panel
In the panel, add a server (Coolify: Servers → Add).
- IP: the Tailscale IP.
- User: `root`.
- Port: `822`.
- Key: the panel key.

Then click Validate. If it fails:
- Run `sudo tail /var/log/auth.log` on the server.
- Check that the key's `from="100.64.0.0/10"` covers the VPS IP.

## 7. After the run
1. **CrowdSec:** `sudo cscli console enroll <key>` (if not done earlier), then accept the machine in app.crowdsec.net.
2. **Monitoring:** follow the `/monitoring` skill.
3. **Laptop with GitHub runners:** `sudo extras/github-runners/limit-runners-memory.sh`.
4. **Reboot** if the kernel was updated: `sudo reboot`.
5. **Final audit:** `sudo ./server-audit.sh`, then analyse it with `/audit-review`.
