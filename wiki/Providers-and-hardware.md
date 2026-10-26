Which systems, server types and panels server-prep is known to work on, which ones still need a report, and how you can send yours.

## What "tested" means here

The README names the tested targets: **Ubuntu 22.04, 24.04 and 26.04, and Debian 12 and 13, on cloud VPS and on dedicated / on-premise servers**. Those are the only cells marked "tested by maintainers" below.

The README does not say which panel was used on which system. So every panel cell says "needs a report" until someone shares a run. This page is honest on purpose: a gap is more useful than a guess.

- **VPS:** a virtual server you rent from a cloud provider.
- **Dedicated / on-premise:** a physical machine, rented in a data center or in your own office.
- **Other machines:** a laptop or an old PC used as a server, or a local VM (for example with `multipass`).

See the [Glossary](Glossary) for other words.

## Compatibility matrix

`server-prep + audit` means `server-preconfig.sh`, `server-prep.sh` and `server-audit.sh` on that system, with any panel or none.

| OS | Server type | server-prep + audit | Coolify | Dokploy | Openship |
|---|---|---|---|---|---|
| Ubuntu 22.04 | VPS | tested by maintainers | needs a report | needs a report | needs a report |
| Ubuntu 22.04 | dedicated / on-premise | tested by maintainers | needs a report | needs a report | needs a report |
| Ubuntu 24.04 | VPS | tested by maintainers | needs a report | needs a report | needs a report (test planned, [#57](https://github.com/exceev-consulting/server-prep/issues/57)) |
| Ubuntu 24.04 | dedicated / on-premise | tested by maintainers | needs a report | needs a report | needs a report |
| Ubuntu 26.04 | VPS | tested by maintainers | needs a report | needs a report | needs a report |
| Ubuntu 26.04 | dedicated / on-premise | tested by maintainers | needs a report | needs a report | needs a report |
| Debian 12 | VPS | tested by maintainers | needs a report | needs a report | needs a report |
| Debian 12 | dedicated / on-premise | tested by maintainers | needs a report | needs a report | needs a report |
| Debian 13 | VPS | tested by maintainers | needs a report | needs a report | needs a report |
| Debian 13 | dedicated / on-premise | tested by maintainers | needs a report | needs a report | needs a report (test planned, [#57](https://github.com/exceev-consulting/server-prep/issues/57)) |
| any of the above | laptop or old PC | needs a report | needs a report | needs a report | needs a report |
| any of the above | local VM | needs a report | needs a report | needs a report | needs a report |
| other Debian / Ubuntu versions | any | needs a report | needs a report | needs a report | needs a report |

What exists for each panel today is on the [Panels](Panels) page. In short: Coolify has its own code paths and two guides, Dokploy has a few, and Openship only changes the name in messages ([epic #10](https://github.com/exceev-consulting/server-prep/issues/10)).

**Planned:** a matrix with one row per real run (OS, server type, provider or hardware, panel, version, audit result, notes, link), in [#29](https://github.com/exceev-consulting/server-prep/issues/29). Automatic tests on Ubuntu and Debian in CI are planned in [#38](https://github.com/exceev-consulting/server-prep/issues/38).

## Known quirks by system

These are handled by the scripts today. Each one links to its fix on [Troubleshooting](Troubleshooting).

| System | Quirk | What server-prep does |
|---|---|---|
| Ubuntu 26.04 | uses **sudo-rs**, which rejects the sudo log file setting | skips the log file; sudo-rs logs to the journal, and the audit counts it as PASS ([fix](Troubleshooting#passwords-and-sudo)) |
| Ubuntu with Ubuntu Pro | ESM offers an old CrowdSec 1.4.x | pins CrowdSec to its official repo at priority 900 and upgrades it ([fix](Troubleshooting#packages-and-apt)) |
| Ubuntu | apport forces `fs.suid_dumpable=2` | disables apport ([fix](Troubleshooting#kernel-settings-and-services)) |
| Any system with UFW | `/etc/ufw/sysctl.conf` turns `log_martians` back off at boot | rewrites that file ([fix](Troubleshooting#kernel-settings-and-services)) |
| Fresh Debian | no `openssh-server`, and only `vim-tiny` | `server-preconfig.sh` installs SSH; the `update` step installs `vim` ([fix](Troubleshooting#reaching-a-new-server)) |
| Minimal installs | `cracklib-runtime` is missing, so `passwd` fails | installs it and builds the password dictionary ([fix](Troubleshooting#passwords-and-sudo)) |
| Any fresh server | apt runs in the background at boot | waits up to 10 minutes for the apt lock ([fix](Troubleshooting#packages-and-apt)) |

## Tips per server type

**VPS**

- Keep the provider's network config. At the network question of `server-preconfig.sh`, press Enter (`keep`).
- Find the provider's web console **before** you start. You need it if SSH breaks.
- Many providers put a **cloud firewall** in front of the server. Open the new SSH port (`822`) there too, and keep 22 open until the SSH step is confirmed. Otherwise the server works but you can't reach it.
- Cloud images can add their own file in `/etc/ssh/sshd_config.d/`. server-prep's `00-server-prep.conf` is read first and wins, and the SSH step lists the other files in its notes.

**Dedicated or on-premise**

- Save the network so it survives a reboot:
  ```bash
  sudo ./server-preconfig.sh --static-ip current
  ```
  The check at the end should say `OK <iface> saved as static`. A DHCP reservation on the router also works.
- Keep a remote console: IPMI, iDRAC, iLO or KVM, the host's rescue mode, or a screen and keyboard.
- In the BIOS, set **Restore on AC Power Loss** to **Power On**.
- Behind NAT, use Tailscale for SSH and the panel, and a Cloudflare Tunnel for the apps.

**Laptop or old PC:** the `laptop` step ignores the lid and turns off sleep (`LAPTOP_MODE=auto`). Never forward port 22 or 822 on your router: use Tailscale.

Beginner notes for each common VPS provider are planned in [#19](https://github.com/exceev-consulting/server-prep/issues/19).

## Report your result

Every report fills a cell in the matrix. A short "it works" is as useful as a bug report.

**Where to post today:**

- It works, or works after some manual steps: [Discussions → Show and tell](https://github.com/exceev-consulting/server-prep/discussions/categories/show-and-tell).
- You have a question: [Discussions → Q&A](https://github.com/exceev-consulting/server-prep/discussions/categories/q-a).
- Something is broken: open an [issue](https://github.com/exceev-consulting/server-prep/issues/new/choose).
- A security problem: report it privately, as [SECURITY.md](https://github.com/exceev-consulting/server-prep/blob/main/SECURITY.md) explains. Never in public.

**Planned:** a "Compatibility reports" category with a form ([#26](https://github.com/exceev-consulting/server-prep/issues/26)), a matching issue form ([#42](https://github.com/exceev-consulting/server-prep/issues/42)) and a `/compat-report` skill that turns a report into a matrix row ([#44](https://github.com/exceev-consulting/server-prep/issues/44)).

### What to include

| Field | Example |
|---|---|
| OS and version | Debian 13 |
| Server type | VPS, dedicated, laptop or old PC, VM |
| Provider or hardware, in generic words | "VPS 2 vCPU / 4 GB at <provider>", "mini PC", "rack server" |
| Panel and `PANEL_ACCESS` | Coolify, `tailscale` |
| server-prep version | `v1.1.1` |
| Audit summary | the output of the command below |
| What needed manual work | "opened 822 in the provider firewall" |

### Collect it

Print your OS:

```bash
. /etc/os-release && echo "$PRETTY_NAME"
```

You see one line, for example `Debian GNU/Linux 13 (trixie)`.

Print the server-prep version:

```bash
./server-prep.sh --help | head -1
```

The line starts with `server-prep.sh v` and the version number.

Write the audit as JSON. This changes nothing on the server:

```bash
sudo ./server-audit.sh --quiet --no-txt --json audit.json
```

Print the summary without your host name and public IP:

```bash
jq '{version, os, score, summary, problems: [.checks[] | select(.status == "FAIL" or .status == "WARN") | {id, status, message}]}' audit.json
```

You get the audit version, the OS, the score, the PASS / WARN / FAIL / INFO counts, and one line per WARN or FAIL. A prepared server usually shows 0 FAIL.

### Before you post

- **No secrets.** Remove every token, key and password: tunnel tokens, CrowdSec enroll keys, Tailscale keys, InfluxDB tokens, Telegram bot tokens.
- **Read every message line.** Some contain IPs, host names or user names. Replace them with examples such as `web-01`, `example.com` or `203.0.113.10`.
- **Don't paste the whole log** from `/var/log/server-prep/`. It can contain secrets today ([#64](https://github.com/exceev-consulting/server-prep/issues/64)).
- **Never name a client or a site.** Describe the machine in generic words.

Thank you: each report helps the next person pick a setup that works.
