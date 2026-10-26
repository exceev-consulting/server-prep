server-prep runs the same way on a cloud VPS, a dedicated server and a laptop or desktop used as a server. Four details change.

## At a glance

| | VPS | Dedicated or on-premise | Laptop or desktop |
|---|---|---|---|
| **Network** | Keep the provider's config. Answer `keep` in `server-preconfig.sh`. | Save the address so it survives reboots: `--static-ip current` on Debian, or a DHCP reservation on the router. | Same as dedicated. On Ubuntu, set a DHCP reservation: netplan is left as it is. |
| **Console if SSH breaks** | The provider's web console or rescue mode. | IPMI, iDRAC, iLO, KVM, rescue mode, or a screen and keyboard. | The screen and keyboard. |
| **Power** | Handled by the provider. | In the BIOS, set *Restore on AC Power Loss* to **Power On**. | Same as dedicated. `server-prep.sh` also ignores the lid and turns off sleep. |
| **Reaching it** | A public IP: open 80/443 (`EXPOSE_WEB=yes`) or use a tunnel. | Often behind NAT: Tailscale for SSH and the panel, a Cloudflare Tunnel for apps. | Same as dedicated. |

## VPS

- Do not change the network: the provider manages it with cloud-init or netplan.
- Most providers give you `root` with a password or a key at first. `server-preconfig.sh` creates your admin user with sudo.
- With `EXPOSE_WEB=yes`, ports 80 and 443 are open to everyone, and the panel's proxy answers on them.

## Dedicated or on-premise server

- Check the console **before** you start. It is your only way back if SSH locks you out.
- A fixed address matters here. Prefer a DHCP reservation on the router. Use `--static-ip current` only on Debian (ifupdown), and only from the console: a mistake cuts SSH and Tailscale together.
- Set the BIOS to power on after a power cut, so the server comes back without help.
- Run the reboot test from [Start here](Start-here#5-reboot-test) before you deploy anything.

## Laptop or desktop used as a server

- The `laptop` step ignores the lid, masks sleep and suspend, and can boot without the desktop (`HEADLESS=yes`).
- Expect a few extra WARN lines in the audit: a desktop runs more services than a server.
- Self-hosted GitHub runners on the same machine? Cap their memory with [`extras/github-runners/limit-runners-memory.sh`](https://github.com/exceev-consulting/server-prep/blob/main/extras/github-runners/limit-runners-memory.sh).

See the [setup console](https://exceev-consulting.github.io/server-prep/) to compare the commands for each machine type.
