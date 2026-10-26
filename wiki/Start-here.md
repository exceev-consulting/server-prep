A beginner path from "I just rented a server" to "audit 0 FAIL, panel connected", one step at a time.

## Before you start

You need:

- **A fresh server** with Debian 12 or 13, or Ubuntu 22.04, 24.04 or 26.04. A VPS, a dedicated server or an office machine all work. See [VPS or dedicated](VPS-or-dedicated) for the differences.
- **A console that works without SSH.** On a VPS, this is the provider's web console. On a dedicated server, it is IPMI, iDRAC, iLO, KVM, the host's rescue mode, or a screen and keyboard. If an SSH change goes wrong, this is how you get back in.
- **Your own computer** with a terminal and an SSH key (see below).
- **Your panel** (optional): Coolify, Dokploy or another panel that logs in over SSH with a key. You need the public part of the key it uses for servers.
- **A Tailscale account** (optional but recommended): a free private network between your computer, the panel server and this server. See [Tailscale](Concepts#tailscale).

Two rules for the whole path:

- You run every `sudo` command yourself, on the server.
- Never paste a token, a private key or a password into a chat, an issue or a forum post. Type them only into the script prompts.

If a word is new to you, check the [Glossary](Glossary).

## 1. Open the console first

Log in to your provider's dashboard and open the web console of the server, or plug in a screen. Check that you can log in there. Keep it open in a tab.

Do this **before** anything else. Later steps change SSH. The scripts have safety nets, but the console is the one that always works.

## 2. Make an SSH key on your computer

An SSH key is a pair of files: a private key that stays on your computer, and a public key that you put on servers. Skip this step if you already have one. On your computer (not the server):

```bash
ssh-keygen -t ed25519
```

Press Enter to accept the file name, then choose a passphrase. It creates `~/.ssh/id_ed25519` (private, never share it) and `~/.ssh/id_ed25519.pub` (public).

```bash
cat ~/.ssh/id_ed25519.pub
```

It prints one line that starts with `ssh-ed25519 AAAA`. This is the line the scripts ask for. You can also add it to your GitHub account: the preconfig script can then fetch it from `github.com/<your-login>.keys`.

## 3. Get the scripts onto the server

Log in to the server (SSH with a password, or the console). Then:

```bash
git clone https://github.com/exceev-consulting/server-prep.git && cd server-prep
```

You get a `server-prep` folder. If `git` is missing, run `sudo apt install -y git` first. If SSH is refused, [server-preconfig.md](https://github.com/exceev-consulting/server-prep/blob/main/server-preconfig.md#1-get-the-script-onto-the-server) shows other ways, like copying the folder with `scp`.

## 4. Preconfig: make the server reachable and reboot-safe

```bash
sudo ./server-preconfig.sh
```

If `sudo` is not installed yet (common on a fresh Debian), run it as root with `su - -c "$HOME/server-prep/server-preconfig.sh"`.

It asks a few questions. Enter picks the default:

| Question | What to answer |
|---|---|
| Admin user | your user |
| GitHub login | your GitHub login, to add your key. Or Enter to skip |
| Hostname | a short name, for example `web-01` |
| Network to save | on a VPS: `keep`. On a dedicated server: `current` if the IP is not saved yet |
| Tailscale | `yes`. Open the printed URL on your computer and approve the machine |

It ends with a `Result` line. You want `0 FAIL`. Fix every FAIL before you go on: each one says what to run.

Two common WARN lines:

- `Tailscale key expires <date>`: in the Tailscale admin console, open Machines, pick the server, then **Disable key expiry**. Otherwise access stops on that date.
- `<user> has no SSH key`: from your computer, run `ssh-copy-id <user>@<server-ip>`. You need a key, because password login gets turned off later.

## 5. Reboot test

A server must come back on its own after a reboot or a power cut. Test it now, while nothing important runs on it.

```bash
sudo reboot
```

Your SSH session closes. Wait about two minutes, then from your computer:

```bash
ssh <user>@<server-ip> 'hostname; ping -c2 debian.org'
```

It prints the hostname and two ping replies. If you use Tailscale, use the Tailscale IP (it starts with `100.`). If it fails, open the console and run `sudo ./server-preconfig.sh --check`.

## 6. Baseline audit

```bash
sudo ./server-audit.sh
```

It changes nothing. It ends with a line like `Score: 65/100 - 20 PASS, 10 WARN, 8 FAIL, 6 INFO`. A fresh server usually has FAILs (password SSH, no firewall...). Keep this result: at the end you compare it with the final one.

## 7. Choose your answers, then preview

`server-prep.sh` asks about 25 questions (more if you turn on extras). You can answer them one by one, or prepare them first.

**Option A: the setup console.** Open the [setup console](https://exceev-consulting.github.io/server-prep/), pick your server type and panel, and copy the config file it makes. It holds no secrets: the script asks for them. Save it as `web-01.conf` on the server (in the `server-prep` folder), for example with `nano web-01.conf`. Never commit a filled config.

**Option B: the questions.** Just run the script. Each question has a short explanation.

The answers that matter most:

- **Admin public key:** the line from step 2.
- **Panel key:** the public part of the key your panel uses (Coolify: Keys & Tokens, Private Keys, the key, Public Key).
- **Panel access:** how the panel reaches this server. `tailscale` is the simplest when the panel server is in your tailnet.
- **SSH port:** `822` (the default).
- **Admin IPs:** the IPs allowed to SSH, for example `203.0.113.4 192.168.1.0/24`. With Tailscale, your computer can also connect through the tailnet.
- **Expose 80/443:** `yes` if visitors reach your apps on this server's IP. `no` if you use a Cloudflare Tunnel.

Now preview. With a config file:

```bash
sudo ./server-prep.sh --config web-01.conf --dry-run
```

Without one, run `sudo ./server-prep.sh --dry-run`. It shows the plan and what each step would do. Nothing changes.

## 8. Real run, with the SSH safety check

On the first run, **don't add `--yes`**. With a config file, its values become the defaults, so you mostly press Enter:

```bash
sudo ./server-prep.sh --config web-01.conf
```

It shows the plan and waits for you to confirm. Nothing changes before that. Then the steps run one by one.

At the SSH step it stops and shows `SSH SAFETY CHECK`. Do this carefully:

1. Keep the current terminal open.
2. Open a **new** terminal on your computer.
3. Log in on the new port:

```bash
ssh -p 822 <user>@<server-ip>
```

You should get a shell on the server, without a password prompt (your key is used).

4. Go back to the first terminal and answer `y` if it worked, or `n` to roll back now.

If you answer nothing, the SSH change rolls back by itself after 10 minutes. With Tailscale-only access, use the server's Tailscale IP in the test: the address the script prints may be blocked by the firewall (fix planned in [issue #73](https://github.com/exceev-consulting/server-prep/issues/73)).

Today, `--yes` skips this test and confirms on its own ([issue #65](https://github.com/exceev-consulting/server-prep/issues/65)). That is why the first run should be without it.

At the end, the audit runs again and shows the before and after. The report is in `/root/server-prep-reports/`, with a copy in your home folder.

## 9. Final audit

If the report says a reboot is needed (for example after a kernel update), reboot first. Then:

```bash
sudo ./server-audit.sh
```

You want `0 FAIL`. A prepared server usually shows around 40 PASS. Some WARNs are normal:

- regular (non-security) updates are pending;
- a reboot is pending right after an upgrade;
- many services run on a desktop machine.

If a FAIL is left, re-run only that step with the saved answers:

```bash
sudo ./server-prep.sh --config /etc/server-prep/server-prep.conf --only <step>
```

The saved answers become the defaults, so you can press Enter at each question. For any step except `ssh`, you can add `--yes` to skip the questions. The step names are listed by `sudo ./server-prep.sh --list-steps`. See [Troubleshooting](Troubleshooting) for known problems.

## 10. Connect the panel

In your panel, add a new server (Coolify: **Servers**, then **+ Add**):

| Field | Value |
|---|---|
| IP or host | the Tailscale IP with `tailscale` access, the public IP with `public`, or the tunnel SSH hostname with `cloudflared` |
| User | `root` |
| Port | `822` (or your SSH port) |
| Key | the panel key whose public part you gave |

Then validate the connection. Only the panel's key can log in as root, and only from the route you chose. Your own login stays your admin user.

More on each panel: [Coolify](Panels#coolify), [Dokploy](Panels#dokploy), [Openship](Panels#openship).

## What next

- Publish apps without opening ports: [docs/cloudflare-tunnel.md](https://github.com/exceev-consulting/server-prep/blob/main/docs/cloudflare-tunnel.md).
- Add metrics: [docs/monitoring.md](https://github.com/exceev-consulting/server-prep/blob/main/docs/monitoring.md).
- Enroll CrowdSec in its web console: see [CrowdSec](Concepts#fail2ban-and-crowdsec).
- Stuck? Ask in [Discussions](https://github.com/exceev-consulting/server-prep/discussions) with the audit summary line (remove IPs and hostnames).

Claude Code users can run `/new-server` in the repo to be guided question by question. A full beginner mode for AI agents is planned: [issue #7](https://github.com/exceev-consulting/server-prep/issues/7).
