How server-prep is built: three bash scripts, a step model with safe helpers, a read-only audit, and a setup console generated from the scripts.

## The three scripts

server-prep is plain bash. There is nothing to build or install. Each script is a single file, so it still works when you download it alone from a [release](https://github.com/exceev-consulting/server-prep/releases/latest).

| Script | When you run it | What it does |
|---|---|---|
| [`server-preconfig.sh`](https://github.com/exceev-consulting/server-prep/blob/main/server-preconfig.sh) | First, on a fresh server | SSH and sudo for your admin user, the hostname, a network config that survives reboots, no sleep, and Tailscale. It ends with a reboot-readiness check (`--check`). |
| [`server-prep.sh`](https://github.com/exceev-consulting/server-prep/blob/main/server-prep.sh) | Second | Secures the server and prepares it for your panel, step by step. It asks questions, or reads a config file. |
| [`server-audit.sh`](https://github.com/exceev-consulting/server-prep/blob/main/server-audit.sh) | Before and after, and any time | Read-only security and panel-readiness audit. It changes nothing. |

The order is always the same: preconfig, audit, prep in dry run, prep, audit again. [Start here](Start-here) walks through it.

`server-prep.sh` calls the audit itself, before and after its steps. It looks for `server-audit.sh` next to itself, then at `/usr/local/sbin/server-audit`. The report then shows a before/after table for every check.

## The step model

Every change in `server-prep.sh` happens inside a **step**. A step is one bash function named `step_<name>()`, for example `step_firewall()`. Today there are 20 steps, in this order:

`update users docker firewall ssh ips unattended sysctl auth services laptop logging auditd rkhunter aide endlessh telegraf telegram cloudflared suid`

The README has [one line per step](https://github.com/exceev-consulting/server-prep/blob/main/README.md#what-server-prep-does). You can print the names yourself.

```bash
./server-prep.sh --list-steps
```

You see the 20 step names on one line, in run order.

A step is listed in two places in the script:

- the `ALL_STEPS` variable near the top, which sets the names and their order;
- the `run_step <name> "<Title>" step_<name>` list in `main()`, which runs them.

`run_step` decides the result of each step from its return code:

| The step... | Result in the report |
|---|---|
| returns 0 and changed something | `CHANGED` (or `WOULD CHANGE` in a dry run) |
| returns 0 and changed nothing | `OK (already)` |
| returns `$SKIP_RC` (20), because you turned it off | `SKIPPED` |
| returns anything else | `FAILED` |

Inside a step, three small helpers record what happened:

- `note "..."`: a line in the step's *Details* column in the report.
- `changed`: marks the step as `CHANGED`.
- `todo "..."`: a manual follow-up, printed at the end under *To do by hand*.

You choose which steps run with `--only ssh,firewall` or `--skip aide,endlessh`.

## The helpers every change goes through

A step never writes to the system directly. It uses a small set of helpers. This is what makes dry runs, backups and re-runs safe.

| Helper | What it does |
|---|---|
| `run CMD...` | Runs a command and sends its output to the log. In a dry run, it only prints the command. |
| `run_secret SECRET CMD...` | Like `run`, for a command that takes a token or key: the log and the dry-run output show `SECRET` as `***`. |
| `write_file PATH MODE` | Writes a file from stdin, **only when the content is different**. It backs up the old file first. |
| `set_kv FILE KEY VALUE` | Sets one `key = value` line in a config file, replacing a commented or old line. It uses `write_file`. |
| `backup_file PATH` | Copies a file into the backup folder, once per run. |
| `pkg_install PKG...` | Installs only the packages that are missing, with `"${APT_OPTS[@]}"` (it waits up to 10 minutes for the apt lock). |
| `svc_disable UNIT...` | Disables and stops a service, only when it is enabled or running. |

### Idempotency

*Idempotent* means you can run the same thing twice and the second run changes nothing. Each step checks the current state first and only changes what is missing. `write_file` skips identical content and `pkg_install` skips installed packages. So you can re-run server-prep after an OS upgrade, or to change one setting. See the [Glossary](Glossary) for this word and others.

### Dry run

`--dry-run` previews every change and changes nothing. `run` prints `[dry-run] <command>` and `write_file` prints `would write <path>`. You can even dry-run without root, with partial detection. The report then goes to the current folder with a `-dryrun` suffix.

```bash
sudo ./server-prep.sh --dry-run
```

You see the questions, the plan, then each step marked `WOULD CHANGE` or `OK (already)`.

### Safety nets

- The plan is shown before anything changes, and you confirm it.
- The SSH step starts a **10-minute auto-rollback**. If you do not confirm that a new login works, the old SSH config comes back.
- Every run writes a `rollback.sh` that restores the changed files and removes the new ones. It does not remove installed packages or re-enable services. Read it before you run it.

## Where things go

All outputs are readable by root only.

| What | Where |
|---|---|
| Report (Markdown) | `/root/server-prep-reports/server-prep-report-<host>-<date>.md`, plus a copy in the home of the user who ran `sudo` |
| Log | `/var/log/server-prep/run-<date>.log` |
| Backups and `rollback.sh` | `/var/lib/server-prep/backups/<date>/` |
| Audit results before and after | `/var/lib/server-prep/audit-<date>-before.*` and `...-after.*` |
| Saved answers (no secrets) | `/etc/server-prep/server-prep.conf` |

The saved answers let you re-run one step later with the same settings.

```bash
sudo ./server-prep.sh --config /etc/server-prep/server-prep.conf --only firewall --yes
```

You see only the firewall step run, then a short summary with its result.

Secrets (the Cloudflare tunnel token, the Telegram bot token, the CrowdSec enroll key) are never saved in that file.

## The audit

`server-audit.sh` is a rework of [vps-audit](https://github.com/nuver-labs/vps-audit). It reads the real state of the server, for example sshd's effective config with `sshd -T`, and the firewall together with each port's bind address.

Each check calls `result <id> <status> "<title>" "<detail>" "<fix hint>"`. The status is one of:

- **PASS**: good.
- **WARN**: worth a look, sometimes expected.
- **FAIL**: a real problem. The script exits with code `1` when at least one check fails.
- **INFO**: for optional features. INFO never lowers the score.

There are 56 checks in 11 sections: System, Updates, SSH, Firewall & network exposure, Intrusion prevention, Accounts & authentication, Kernel & system settings, Logging & monitoring, Services, Resources, and Panel readiness. Check ids start with their section, for example `ssh.*` or `acc.password_dict`.

The audit writes a text report by default, and can also write Markdown (`--md`), JSON (`--json`) and TSV (`--tsv`). `server-prep.sh` reads the TSV for its before/after table, so those columns must stay stable.

```bash
sudo ./server-audit.sh --md audit.md --json audit.json
```

You see the checks scroll by in color, then a PASS / WARN / FAIL summary, and the two report files appear in the current folder.

## Setup console: from scripts to GitHub Pages

The [setup console](https://exceev-consulting.github.io/server-prep/) shows what server-prep does for your setup: VPS or dedicated, your panel, your access route. Its facts are not written by hand. They come from the scripts.

1. [`scripts/gen-data.sh`](https://github.com/exceev-consulting/server-prep/blob/main/scripts/gen-data.sh) reads `server-prep.sh`, `server-audit.sh`, `server-preconfig.sh`, the README tables and `server-prep.conf.example`.
2. It writes `site/data.json` and `site/data.js` (the same data, loaded by the page so it also works offline). The output has no timestamps, so CI can compare it.
3. `site/index.html` is one static page that reads that data. Its colours and type come from `site/tokens.css`, which the brand guidelines page (`site/brand/`) shares. No build step, no CDN, no tracking.
4. The `pages` workflow publishes `site/` to GitHub Pages.

After you change a step, a setting or an audit check, regenerate the data and commit it.

```bash
scripts/gen-data.sh
```

It prints `wrote site/data.json and site/data.js (20 steps, ... settings, 56 audit checks)` and updates both files. It needs `jq`. In CI, `scripts/gen-data.sh --check` prints nothing and exits 0 when the data is up to date, or prints `site/data.json is out of date` with a diff.

To preview the page on your machine:

```bash
python3 -m http.server --bind 127.0.0.1 -d site 8000
```

Then open http://localhost:8000 in your browser.

## CI workflows

Three workflows live in [`.github/workflows/`](https://github.com/exceev-consulting/server-prep/tree/main/.github/workflows).

| Workflow | When | What it does |
|---|---|---|
| `lint` | Every push to `main` and every PR | `bash -n` on every script, ShellCheck at `-S warning`, each script's `--help`, and `scripts/gen-data.sh --check` (fails when the site data is out of date) |
| `pages` | Push to `main` that touches the site, the scripts, the README or the config example; or by hand | Checks the site data again, then deploys `site/` to GitHub Pages |
| `release` | By hand only (the release button) | Bumps the version, updates the changelog and the site data in one commit put on `main` by the release app (the one exception to `main`'s required approval), tags, and publishes the release with `SHA256SUMS`. See [Maintainer handbook](Maintainer-handbook). |

More checks are planned: a consistency check that keeps steps, README, config example and audit in sync ([#35](https://github.com/exceev-consulting/server-prep/issues/35)), one local script that runs everything CI runs ([#34](https://github.com/exceev-consulting/server-prep/issues/34)), unit tests ([#37](https://github.com/exceev-consulting/server-prep/issues/37)), an Ubuntu and Debian integration matrix with an idempotency check ([#38](https://github.com/exceev-consulting/server-prep/issues/38)), and secret scanning ([#40](https://github.com/exceev-consulting/server-prep/issues/40)). Architecture decision records (ADRs) in `docs/decisions/` are planned in [#30](https://github.com/exceev-consulting/server-prep/issues/30).
