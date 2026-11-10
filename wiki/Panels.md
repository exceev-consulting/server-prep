How a deployment panel (Coolify, Dokploy, Openship or another one) connects to a server prepared by server-prep, and what each panel needs.

## How any panel connects

A self-hosted PaaS panel is a web app that deploys your apps on one or more servers. It runs on its own server and logs in to each managed server over **SSH as `root`**, using its own **SSH key** (a key pair: the panel keeps the private part, the server gets the public part). See the [Glossary](Glossary) for these words.

server-prep works with any panel that does this. You give it three things:

| Setting | What it is |
|---|---|
| `PANEL` | the panel's name: `coolify`, `dokploy`, `openship` or any other name. It is used in the questions, the notes and the report. Two names also change settings: `coolify` creates `/data/coolify`, and `openship` sets AIDE excludes and auditd watches (see [Openship](#openship)). |
| `PANEL_PUBKEY` | the **public** part of the key the panel uses for servers. |
| `PANEL_ACCESS` | how the panel's server reaches this server: `cloudflared`, `tailscale`, `public`, or several, separated by commas. |

With these values, server-prep:

1. adds the panel's key to `/root/.ssh/authorized_keys`, with a `from="..."` prefix, so the key only works from the panel's sources;
2. sets `PermitRootLogin no` for everyone, then adds a `Match Address` block that allows root **with a key only** from those same sources;
3. moves SSH to port `822` (or your `SSH_PORT`) and turns off password login;
4. installs Docker CE if it is missing, because every panel needs it.

So root login is refused from every other address, even with the right key. Your own admin account logs in with its own key, as a normal user with sudo.

In the panel, add the server with:

- **User:** `root`
- **Port:** `822` (or your `SSH_PORT`)
- **Private key:** the one whose public key you gave to server-prep
- **Address:** depends on the access route, see the next section

The report that server-prep writes (`/root/server-prep-reports/`, with a copy in your home) has a "Connect this server to <panel>" section with these values filled in.

## Access routes

`PANEL_ACCESS` decides where root is allowed to log in from. This is the full table:

| `PANEL_ACCESS` | Root allowed from | Address to type in the panel | Good for |
|---|---|---|---|
| `tailscale` | `100.64.0.0/10` and `fd7a:115c:a1e0::/48` (Tailscale's address ranges) | the server's Tailscale IP, for example `100.64.0.12`. The panel's server must be in the same tailnet. | most setups: VPS, dedicated, office or home servers |
| `cloudflared` | `127.0.0.1` and `::1` (the tunnel arrives locally) | the tunnel SSH hostname, for example `ssh-web-01.example.com` | servers behind NAT without Tailscale |
| `public` | `PANEL_IP` only | the server's public IP, for example `203.0.113.10` | a VPS when the panel's server has a fixed public IP |

You can combine them, for example `PANEL_ACCESS="cloudflared,tailscale"`.

**Tailscale** is a private network (a "tailnet") between your machines. `server-preconfig.sh` installs it and logs the server in. This is the simplest route: nothing is open on the internet and the address stays the same when the server moves.

**Cloudflare Tunnel** (`cloudflared`) is a small program on the server that connects *out* to Cloudflare. For panel SSH you add a public hostname in Cloudflare Zero Trust: `ssh-<host>.<domain>` to `ssh://localhost:822`. The `cloudflared` step of server-prep installs the connector with your tunnel token.

**Public** opens the SSH port to the panel's IP only. To find that IP, run this on the panel's server:

```bash
curl -4 ifconfig.me
```

It prints one IPv4 address, for example `198.51.100.7`. Put it in `PANEL_IP`.

To check the root rule on the prepared server, ask sshd what it would do for an address on the internet:

```bash
sudo sshd -T -C user=root,host=x,addr=198.51.100.7 | grep permitrootlogin
```

Expect `permitrootlogin no` (unless `198.51.100.7` is your `PANEL_IP`). For an allowed source, the answer is `permitrootlogin prohibit-password`, which means "keys only".

## Coolify

What server-prep does for Coolify today (`PANEL=coolify`):

- creates `/data/coolify` if it is missing;
- tells AIDE (the file-integrity scan) to skip `/data/coolify`, so app data doesn't flood the report;
- shows where to find the key: **Keys & Tokens → Private Keys → the key → Public Key**;
- the report says to add the server in **Servers → + Add**;
- moves the CrowdSec API from port 8080 to `8091` (`CROWDSEC_LAPI_PORT`), because Coolify's Traefik proxy uses 8080 for its dashboard;
- the audit shows `/data/coolify` and a running `coolify-proxy` container as INFO lines in the "Panel readiness" section.

After you add the server, click **Validate** in Coolify. It checks Docker and starts its reverse proxy on 80/443.

### The Cloudflare Tunnel warning

Coolify has a **Cloudflare Tunnel** option in each **Server**'s settings. That option moves Coolify's own **SSH connection** to the tunnel hostname. If SSH is not set up for that, Coolify loses the server right away.

- If you use `PANEL_ACCESS=tailscale`: keep the server's IP in Coolify set to its **Tailscale IP**, and keep that option **off**.
- To publish **apps** through a tunnel, run cloudflared as a Coolify **Service** (the Cloudflared one-click template), not with the server option. The guide [docs/cloudflare-tunnel.md](https://github.com/exceev-consulting/server-prep/blob/main/docs/cloudflare-tunnel.md) shows every step.
- Use the server option only if you chose `PANEL_ACCESS=cloudflared` and added the `ssh-<host>.<domain>` hostname for SSH.

If Coolify already lost the server: turn the option off and set the server's IP back to its Tailscale IP.

## Dokploy

Dokploy also adds remote servers over SSH with a key. Use the same values: user `root`, port `822`, the panel's private key, and the address for your access route.

What server-prep does for Dokploy today (`PANEL=dokploy`):

- uses "Dokploy" in the questions and the report;
- tells AIDE to skip `/etc/dokploy`;
- moves the CrowdSec API to `8091`, because Dokploy's Traefik uses 8080 too;
- the audit shows `/etc/dokploy` and a running `dokploy-traefik` container as INFO lines.

There is no Dokploy guide yet. If you run it, please share your result (see [Providers and hardware](Providers-and-hardware)).

## Openship

What server-prep does for Openship today (`PANEL=openship`):

- uses "Openship" in the messages and the report;
- tells AIDE to skip what Openship and certbot rewrite on every deploy and renewal: `/var/lib/openship` (except its SSH key folders), `/etc/openship/modules`, the OpenResty configs (`/etc/openresty`, `/usr/local/openresty/nginx/conf`) and certbot's `live`, `archive`, `csr` and `keys` folders under `/etc/letsencrypt`. Openship's SSH key folders, certbot's renewal settings (`/etc/letsencrypt/renewal`, which can name hooks), `renewal-hooks` and `cli.ini` stay checked, and so does the `/etc/letsencrypt` folder itself, without its timestamps (certbot's lock file changes them on every run);
- adds an auditd watch (key `panel`, see it with `sudo ausearch -k panel`) on each of Openship's SSH key folders that exists: `/etc/openship/ssh-keys`, `/var/lib/openship/ssh-keys` and `/var/lib/openship/host-ssh`. The Openship API keeps the private keys it uses to log in to servers there, so these folders exist only on the server that runs the Openship API. A server it manages has none: the run's notes say so, and there is nothing to do.

The trade-off: on an Openship server, AIDE no longer checks the certificates and their private keys and the OpenResty configs, because they change on every deploy and renewal. Certbot's renewal settings stay checked, so after a renewal AIDE's next check lists that domain's file in `/etc/letsencrypt/renewal` as changed: a small cost for seeing a hook planted there.

On a server prepared earlier, set `PANEL=openship` in `/etc/server-prep/server-prep.conf`, then re-run both steps with the saved answers:

```bash
sudo ./server-prep.sh --config /etc/server-prep/server-prep.conf --only aide,auditd --yes
```

On the server that runs the Openship API, run the `auditd` step again once Openship has created a key folder. If AIDE already had a baseline, its next check may list the files under the new excludes as removed. Review that check, then rebuild the baseline with `sudo aideinit -y -f` (the run's to-do list says so too).

The audit shows both as INFO: `mon.auditd_panel` (are the key folders watched?) and `mon.aide_panel` (are the deploy files left out of AIDE?).

The `openship-paths` end-to-end scenario checks these AIDE and auditd paths on every supported system, without a real Openship. The SSH, firewall and Docker setup is the same as for any panel, and has not been tested with Openship end to end yet.

**Planned**, in [epic #10](https://github.com/exceev-consulting/server-prep/issues/10): Openship support at the same level as Coolify. Openship changes the host in ways the hardening must know about, so these sub-issues are open:

| Issue | What it adds or fixes |
|---|---|
| [#46](https://github.com/exceev-consulting/server-prep/issues/46) | panel profiles, instead of panel checks spread across the scripts |
| [#47](https://github.com/exceev-consulting/server-prep/issues/47) | an `/add-panel` checklist for Claude Code |
| [#48](https://github.com/exceev-consulting/server-prep/issues/48) | an Openship profile: questions, hints and report |
| [#49](https://github.com/exceev-consulting/server-prep/issues/49) | bug: when the Openship control plane runs on the same server, it can't SSH to its own host, because the firewall blocks the Docker bridge |
| [#50](https://github.com/exceev-consulting/server-prep/issues/50) | bug: Openship may install the distro `docker.io` package when Docker CE is missing |
| [#51](https://github.com/exceev-consulting/server-prep/issues/51) | explain 80/443: Openship runs OpenResty and certbot on the host network, and certbot needs port 80 open unless you use a tunnel |
| [#52](https://github.com/exceev-consulting/server-prep/issues/52) | an opt-in WireGuard rule for Openship's private networking |
| [#53](https://github.com/exceev-consulting/server-prep/issues/53) | audit checks for Openship |
| [#55](https://github.com/exceev-consulting/server-prep/issues/55) | a guide, `docs/openship.md` |
| [#56](https://github.com/exceev-consulting/server-prep/issues/56) | Openship answers in `/new-server`, the examples and the README |
| [#57](https://github.com/exceev-consulting/server-prep/issues/57) | an end-to-end test on an Ubuntu 24.04 VPS and a Debian 13 dedicated server |
| [#58](https://github.com/exceev-consulting/server-prep/issues/58) | an optional CrowdSec bouncer for OpenResty |

Until these land, if you try Openship:

- keep `INSTALL_DOCKER=yes`, so server-prep installs Docker CE before Openship can install `docker.io` (#50);
- run the Openship control plane on **another** server, not on the one you prepare (#49);
- run the audit after Openship set up the server, and check the "Docker vs firewall" line.

## Other panels

Any panel that logs in over SSH as root with a key should work: set `PANEL` to its name and follow the steps above. Code for one panel only is guarded by `[[ ${PANEL,,} == <name> ]]` in the scripts, so a new panel never changes what the others get. To add real support for a panel, read [CONTRIBUTING.md](https://github.com/exceev-consulting/server-prep/blob/main/CONTRIBUTING.md) and open an issue first. Questions about a panel go to [Discussions](https://github.com/exceev-consulting/server-prep/discussions).

You can also see what each panel and access route opens, step by step, in the [setup console](https://server-prep.exceev.com/).
