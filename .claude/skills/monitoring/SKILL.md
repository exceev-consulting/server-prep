---
name: monitoring
description: Connect a server's Telegraf to InfluxDB v2 and show it in the shared Grafana dashboard (bucket/host variables, portable Flux queries). Use for Telegraf, InfluxDB, Grafana or "metrics not showing" questions.
---

# Telegraf → InfluxDB → Grafana

server-prep installs Telegraf **stopped**. This skill connects it. The user-facing guide is `docs/monitoring.md` (InfluxDB 2.8 on Coolify, Cloudflare Access service token, Docker metrics): follow it and keep both in sync.

## 1. Output config (token kept out of the main config)
The user needs:
- an InfluxDB bucket for this server (convention: **one bucket per server, named after it**);
- a write token for that bucket.

```bash
sudo cp /etc/telegraf/telegraf.conf /etc/telegraf/telegraf.conf.orig
sudo cp extras/telegraf/telegraf.conf.example /etc/telegraf/telegraf.conf
sudo nano /etc/telegraf/telegraf.conf                     # urls, organization, bucket, optional hostname
sudo nano /etc/default/telegraf                           # INFLUX_TOKEN=... (the user types it; never ask for it)
sudo chown root:telegraf /etc/default/telegraf && sudo chmod 640 /etc/default/telegraf
sudo rm -f /etc/telegraf/telegraf.d/influxdb.conf         # old split setup: otherwise metrics are sent twice
```

Through Cloudflare Access, `/etc/default/telegraf` also holds `CF_ACCESS_CLIENT_ID` and `CF_ACCESS_CLIENT_SECRET`, and the output keeps its `http_headers` line. Through Tailscale, remove that line.

Docker (required, the template has a Docker input):
- `sudo usermod -aG docker telegraf` (root-equivalent access), then a restart. Check with `sudo -u telegraf curl -s --unix-socket /var/run/docker.sock http://localhost/_ping`.
- Without it Telegraf doesn't start at all (`E! [agent] Starting input inputs.docker`): no metrics, not even the system ones. On a server without Docker, delete the `[[inputs.docker]]` block.
- Never let `docker_label_include` be empty: Coolify/Dokploy labels would all become tags.

Optional: to show the bucket name instead of the OS host name, set `hostname = "<name>"` under `[agent]`.

## 2. Test: send one real batch
Through Cloudflare Access, check the service token first (same commands as `docs/monitoring.md` step 6). Don't go on until the second one gives `204`:
```bash
curl -s -o /dev/null -w '%{http_code}\n' https://<influxdb-host>/ping     # 302: Access blocks requests without the token
sudo bash -c 'set -a; . /etc/default/telegraf; curl -s -o /dev/null -w "%{http_code}\n" \
  -H "CF-Access-Client-Id: $CF_ACCESS_CLIENT_ID" -H "CF-Access-Client-Secret: $CF_ACCESS_CLIENT_SECRET" \
  https://<influxdb-host>/ping'                                            # 204
```
- **302 with the token:** the token isn't in the app's Service Auth policy, or the headers are wrong.
- **403:** the token expired or was revoked.

Then one real batch:
```bash
sudo -u telegraf bash -c 'set -a; . /etc/default/telegraf; telegraf --config /etc/telegraf/telegraf.conf \
  --config-directory /etc/telegraf/telegraf.d --once --debug' 2>&1 | grep -E 'Wrote batch|E!'
```

How to read the output:
- **OK:** `Wrote batch of N metrics`. This only means the server answered OK. If Access refused the token, Telegraf followed the redirect to the login page and still logs it, so the metrics were lost. Telegraf never shows a 302: rely on the `204` test above, and check the data in InfluxDB's **Data Explorer** (bucket, `cpu`, last minutes).
- **401:** bad InfluxDB token.
- **404:** wrong bucket or org.
- **refused / timeout:** wrong URL, or the server can't reach InfluxDB over Tailscale.
- **Noise:** `permission denied` on docker, gvfs or netns mounts, `utmp` missing, docker `parsing size`.

`--test` never sends data, so use `--once`.

## 3. Start
```bash
sudo systemctl enable --now telegraf && journalctl -u telegraf -f    # no E! lines
```

## 4. Grafana dashboard (shared by all servers)
**Variables**, in this order:
1. `bucket`: query `buckets()`.
2. `host`:
   - query:
     ```flux
     import "influxdata/influxdb/schema"
     schema.tagValues(bucket: "${bucket}", tag: "host", start: -1h)
     ```
   - single value, no "All", optionally hidden. It then follows the selected bucket automatically.

**Query rules** that make panels work on every OS:
- Always filter with `r.host == "${host}"`. Never assume host = bucket.
- **Disk:** filter on `r.path == "/"`, not on the device. The device is `vda1` on the VPS but `nvme0n1pX` on the laptop.
- **Network:** filter with `r.interface !~ /^(lo|docker|veth|br-|tailscale)/` rather than naming `eth0` / `enp*`.
- **CPU:** `r.cpu == "cpu-total"`, and use `100 - usage_idle`.

Example (disk usage of `/`):
```flux
from(bucket: "${bucket}")
  |> range(start: v.timeRangeStart, stop: v.timeRangeStop)
  |> filter(fn: (r) => r._measurement == "disk" and r._field == "used_percent")
  |> filter(fn: (r) => r.host == "${host}" and r.path == "/")
  |> aggregateWindow(every: v.windowPeriod, fn: last, createEmpty: false)
```

To change every panel at once, edit the dashboard JSON Model (Settings → JSON Model) and use find/replace.
