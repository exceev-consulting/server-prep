# Server and Docker metrics: Telegraf → InfluxDB 2.8 → Grafana

Every server runs **Telegraf**, which sends its system and Docker metrics to one **InfluxDB 2.8**
(run by Coolify). **Grafana** reads them and shows one dashboard for all servers.

```mermaid
flowchart LR
    subgraph S1["web-01"]
        T1["Telegraf<br/>system + Docker"]
    end
    subgraph S2["web-02"]
        T2["Telegraf<br/>system + Docker"]
    end
    T1 -- "HTTPS + service token" --> CF["Cloudflare Access"]
    T2 -- "HTTPS + service token" --> CF
    CF -- "tunnel" --> I["InfluxDB 2.8<br/>(Coolify service)<br/>one bucket per server"]
    I --> G["Grafana"]
```

All of it comes from one file, [extras/telegraf/telegraf.conf.example](../extras/telegraf/telegraf.conf.example):

| Metrics | Telegraf inputs |
|---|---|
| CPU, memory, swap, disk, disk I/O, load, processes, uptime | `cpu`, `mem`, `swap`, `disk`, `diskio`, `system`, `processes`, `kernel` |
| Network traffic and TCP connections | `net` (real interfaces only), `netstat` |
| Containers: CPU, memory, network, block I/O, status, health | `docker` |
| Interrupts, open files | `interrupts`, `linux_sysctl_fs` |

**Example values used below:** InfluxDB at `https://influxdb.example.com`, organization `example`,
servers `web-01` and `web-02`. Replace them with yours.

**Two ways for Telegraf to reach InfluxDB:**
- **Through Cloudflare** (this guide): InfluxDB is published with the Cloudflare Tunnel
  ([cloudflare-tunnel.md](cloudflare-tunnel.md)) and protected by Cloudflare Access. It works from anywhere.
- **Through Tailscale**: InfluxDB's port 8086 is published on the host and allowed only from the tailnet in
  UFW. Telegraf uses `http://<tailscale-ip>:8086` and needs no Cloudflare headers.

## 1. Run InfluxDB 2.8 on Coolify

1. In Coolify, click **+ New** in your project, search **InfluxDB** (Services), and choose the server.
2. The template ships `influxdb:2.7-alpine`. Click **Edit Compose File** and change the image:
   ```yaml
   image: influxdb:2.8-alpine     # any 2.x from 2.8 works (2.9 is out too)
   ```
3. Set the domain **with the container port**: `https://influxdb.example.com:8086`. If you see
   **Redirect HTTP to HTTPS**, set it to **Disabled**.
   The tunnel's `*` route already covers it. If you only have named routes, add `influxdb`.
4. **Save**, then **Deploy**. Wait until the container shows **healthy**.
5. Open `https://influxdb.example.com` **right away**:
   - a login page: use the user and password that Coolify generated (service → **Environment Variables**:
     `SERVICE_USER_INFLUXDB`, `SERVICE_PASSWORD_INFLUXDB`);
   - a **Get Started** page: finish it **now** (user, password, organization `example`, first bucket).
     Until you do, the first person who opens the URL becomes the admin.

**Upgrading an existing 2.7 to 2.8:** change the image and redeploy. The data stays in the service's
volumes. 2.8 adds optional [token hashing](https://docs.influxdata.com/influxdb/v2/reference/config-options/):
turn it on only **after** a first successful start on 2.8, and keep a copy of your tokens first,
because hashed tokens can't be shown again.

## 2. Buckets and tokens

In InfluxDB (**Load Data**):

| Create | Settings | Used by |
|---|---|---|
| a **bucket per server**: `web-01`, `web-02`... | retention, for example 30 days | Telegraf on that server |
| a **write token per server** | **API Tokens → Generate API Token → Custom API Token**, *Write* on that server's bucket only | Telegraf on that server |
| one **read token** | *Read* on all buckets | Grafana |

One token per server means a leaked token can only write to one bucket, and you can revoke it alone.

## 3. Install Telegraf on each server

server-prep installs it (step `telegraf`, from the official InfluxData repository) and leaves it **stopped**
until it has an output. If you skipped it:
```bash
sudo ./server-prep.sh --config /etc/server-prep/server-prep.conf --only telegraf --yes
```

## 4. Protect InfluxDB with Cloudflare Access

Without it, anyone who finds the URL can try to log in or call the API.
[cloudflare-tunnel.md, step 8](cloudflare-tunnel.md#8-secure-your-public-urls-with-zero-trust) explains
Zero Trust. For InfluxDB:

1. **Service token** for the agents: **Access controls → Service credentials → Service Tokens → Create
   Service Token**, name `telegraf`. Copy the **Client ID** and the **Client Secret** (shown once).
2. **Application:** **Access controls → Applications → Add an application → Self-hosted**, hostname
   `influxdb.example.com`, with two policies:

   | Policy | Action | Include |
   |---|---|---|
   | `team` | Allow | your team's emails (people log in with an email code) |
   | `telegraf` | **Service Auth** | Service Token `telegraf` |

## 5. Configure Telegraf (on each server)

**a. Secrets**, kept out of the config files:
```bash
sudo nano /etc/default/telegraf
```
```bash
INFLUX_TOKEN=<the write token of this server>
CF_ACCESS_CLIENT_ID=<client id>.access
CF_ACCESS_CLIENT_SECRET=<client secret>
```
```bash
sudo chown root:telegraf /etc/default/telegraf && sudo chmod 640 /etc/default/telegraf
```

**b. The config:** one file with the output, the system inputs and Docker. It replaces the package's file.
```bash
sudo cp /etc/telegraf/telegraf.conf /etc/telegraf/telegraf.conf.orig        # keep the original
sudo cp extras/telegraf/telegraf.conf.example /etc/telegraf/telegraf.conf
sudo nano /etc/telegraf/telegraf.conf
```
Change only:

| Setting | Value |
|---|---|
| `urls` | `["https://influxdb.example.com"]` (through Tailscale: `http://<tailscale-ip>:8086`, and remove `http_headers`) |
| `organization` | `example` |
| `bucket` | this server's bucket, `web-01` |
| `hostname` (optional) | the name shown in Grafana; empty = the OS host name |

Leave `token` and `http_headers` as they are: the `${...}` values come from `/etc/default/telegraf`.

If an older setup left an output in `telegraf.d`, remove it, otherwise every metric is sent twice:
```bash
ls /etc/telegraf/telegraf.d/
sudo rm -f /etc/telegraf/telegraf.d/influxdb.conf
```

**c. Let Telegraf read Docker:** the Docker input talks to `/var/run/docker.sock`, which only root and the
`docker` group can open.
```bash
sudo usermod -aG docker telegraf
id telegraf                     # the groups must include "docker"
sudo -u telegraf curl -s --unix-socket /var/run/docker.sock http://localhost/_ping; echo     # OK
```
The service only picks up the new group after a restart (step 6).

> [!WARNING]
> Membership of the `docker` group gives the same power as root. It's the usual way to read Docker metrics,
> but only do it on servers where Telegraf comes from the official repository (server-prep checks the key).

## 6. Test, then start

```bash
# Access blocks requests without the token: expect 302
curl -s -o /dev/null -w '%{http_code}\n' https://influxdb.example.com/ping

# With the token, read from the file so nothing shows on screen: expect 204
sudo bash -c 'set -a; . /etc/default/telegraf; curl -s -o /dev/null -w "%{http_code}\n" \
  -H "CF-Access-Client-Id: $CF_ACCESS_CLIENT_ID" -H "CF-Access-Client-Secret: $CF_ACCESS_CLIENT_SECRET" \
  https://influxdb.example.com/ping'

# One real batch, as the telegraf user (also checks the docker group): expect "Wrote batch of N metrics"
sudo -u telegraf bash -c 'set -a; . /etc/default/telegraf; telegraf --config /etc/telegraf/telegraf.conf \
  --config-directory /etc/telegraf/telegraf.d --once' 2>&1 | tail -5

# Docker metrics only: expect "Wrote batch" and no "permission denied"
sudo -u telegraf bash -c 'set -a; . /etc/default/telegraf; telegraf --config /etc/telegraf/telegraf.conf \
  --input-filter docker --once' 2>&1 | tail -3

sudo systemctl enable --now telegraf
sudo systemctl restart telegraf          # picks up the docker group
sleep 20 && sudo journalctl -u telegraf -n 10 --no-pager    # no "E!" lines
```
`telegraf --test` only prints metrics and never sends them. Use `--once` to check the output.

## 7. Grafana

**Data source:** **Connections → Data sources → Add → InfluxDB**:

| Field | Value |
|---|---|
| Query language | **Flux** |
| URL | same server as InfluxDB: `http://<influxdb-container-name>:8086` (no Cloudflare). Elsewhere: `https://influxdb.example.com` |
| Custom HTTP Headers | only when the URL goes through Cloudflare: `CF-Access-Client-Id` and `CF-Access-Client-Secret` (a service token for Grafana, allowed in the app's Service Auth policy) |
| Organization | `example` |
| Token | the **read** token |

**Dashboard variables** (one dashboard for all servers):
1. `bucket`: query `buckets()`.
2. `host`:
   ```flux
   import "influxdata/influxdb/schema"
   schema.tagValues(bucket: "${bucket}", tag: "host", start: -1h)
   ```

**Queries that work on every server:**
- always filter `r.host == "${host}"`;
- disk: `r.path == "/"` (device names differ between servers);
- network: `r.interface !~ /^(lo|docker|veth|br-|tailscale)/`;
- CPU: `r.cpu == "cpu-total"`, and show `100 - usage_idle`.

**Container panels:**
```flux
// Memory used by each container (%)
from(bucket: "${bucket}")
  |> range(start: v.timeRangeStart, stop: v.timeRangeStop)
  |> filter(fn: (r) => r._measurement == "docker_container_mem" and r._field == "usage_percent")
  |> filter(fn: (r) => r.host == "${host}")
  |> group(columns: ["container_name"])
  |> aggregateWindow(every: v.windowPeriod, fn: mean, createEmpty: false)
```
```flux
// CPU used by each container (%)
from(bucket: "${bucket}")
  |> range(start: v.timeRangeStart, stop: v.timeRangeStop)
  |> filter(fn: (r) => r._measurement == "docker_container_cpu" and r._field == "usage_percent")
  |> filter(fn: (r) => r.host == "${host}" and r.cpu == "cpu-total")
  |> group(columns: ["container_name"])
  |> aggregateWindow(every: v.windowPeriod, fn: mean, createEmpty: false)
```
```flux
// Containers that are not healthy (table)
from(bucket: "${bucket}")
  |> range(start: -5m)
  |> filter(fn: (r) => r._measurement == "docker_container_health" and r._field == "health_status")
  |> filter(fn: (r) => r.host == "${host}")
  |> last()
  |> filter(fn: (r) => r._value != "healthy")
  |> keep(columns: ["container_name", "_value"])
```

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `302` with the token | the token isn't allowed, or the headers aren't sent | the app needs a **Service Auth** policy with this token; check the two names in `http_headers` |
| `403 Forbidden` from Cloudflare | the token is expired or was revoked | create a new one and update `/etc/default/telegraf` |
| `401 Unauthorized` from InfluxDB | wrong InfluxDB token | use this server's write token |
| `404` / `bucket not found` | wrong bucket or organization | check `bucket` and `organization` (case matters) |
| `permission denied ... docker.sock` | telegraf isn't in the `docker` group, or the service wasn't restarted | `sudo usermod -aG docker telegraf && sudo systemctl restart telegraf` |
| Every metric twice in Grafana | two outputs: the full config **and** an old `telegraf.d/influxdb.conf` | delete the one in `telegraf.d` and restart |
| InfluxDB grows very fast | Docker labels turned into tags | keep `docker_label_include` limited to the compose labels, as in the template |
| Cloudflare "Host Error" (502) | the InfluxDB domain has no `:8086` in Coolify | `https://influxdb.example.com:8086`, then redeploy |
| `permission denied` on disk mounts (`/run/user/...`, `netns`) | normal for some mounts | harmless; optionally extend `ignore_fs` in `[[inputs.disk]]` |

## Official docs

- InfluxDB: [install (Docker)](https://docs.influxdata.com/influxdb/v2/install/),
  [create a token](https://docs.influxdata.com/influxdb/v2/admin/tokens/create-token/),
  [config options (token hashing)](https://docs.influxdata.com/influxdb/v2/reference/config-options/),
  [Coolify InfluxDB service](https://coolify.io/docs/services/influxdb)
- Telegraf: [InfluxDB v2 output](https://github.com/influxdata/telegraf/tree/master/plugins/outputs/influxdb_v2),
  [Docker input](https://github.com/influxdata/telegraf/tree/master/plugins/inputs/docker),
  [network input](https://github.com/influxdata/telegraf/tree/master/plugins/inputs/net)
- Cloudflare: [service tokens](https://developers.cloudflare.com/cloudflare-one/access-controls/service-credentials/service-tokens/),
  [self-hosted Access application](https://developers.cloudflare.com/cloudflare-one/access-controls/applications/http-apps/self-hosted-public-app/)
- Grafana: [InfluxDB data source](https://grafana.com/docs/grafana/latest/datasources/influxdb/)
