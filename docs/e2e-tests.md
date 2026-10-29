# End-to-end tests

The end-to-end tests run the three scripts for real, on a fresh server, the way an operator would. Each
supported system gets its own virtual machine, booted from the official cloud image that VPS providers use.
The tests log in over SSH, answer the questions, change the SSH port, reboot, and check the result from
outside, like a person would. Then they write an HTML report.

Why VMs and not containers: [docs/decisions/0001-e2e-test-platform.md](decisions/0001-e2e-test-platform.md).

## Where to see the results

| Report | Address |
|---|---|
| Last run on `main` | <https://exceev-consulting.github.io/server-prep/e2e/main/> |
| A pull request | `https://exceev-consulting.github.io/server-prep/e2e/pr-<number>/` |
| All reports | <https://exceev-consulting.github.io/server-prep/e2e/> |

- Every pull request that changes a script or the tests runs them. A comment on the pull request gives the link
  and the result.
- When the pull request is merged or closed, its report is deleted. A merge starts a new run on `main`, and that
  run replaces the `main` report.
- The tests also run every Monday, which catches changes in the distributions themselves.
- The `e2e` workflow keeps each run's results and report as artifacts for 30 days.

## What runs

Each system (Debian 12 and 13, Ubuntu 22.04, 24.04 and 26.04) goes through these scenarios, in order:

| Scenario | What it checks |
|---|---|
| `boot` | The cloud image matches its published checksum, boots, and the provider-style user logs in over SSH. |
| `audit-fresh` | The audit exits 1 on a fresh server and FAILs the firewall, intrusion prevention, password policy, kernel settings and password login. |
| `preconfig` | `server-preconfig.sh --check`, a run without Tailscale, then `--check` again, with no FAIL. |
| `prep-dry-run` | `server-prep.sh --dry-run` with [tests/e2e/ci.cfg](../tests/e2e/ci.cfg) changes no file in `/etc`, no package and no unit. |
| `prep-interactive` | The same dry run, answering every question at a terminal like a person. |
| `prep-run` | The real run exits 0, no step FAILs, and the panel's key logs in as root on port 822. |
| `ssh-access` | The admin logs in with a key and can use sudo, the provider user and root with the admin key are refused, password login is off, root is refused from an address that is not the panel's, and port 22 gives no login. |
| `docker-firewall` | A container published with `-p` answers inside the server but not from outside. With a `ufw route allow` rule it does answer, which proves the test goes through the firewall. |
| `audit-prepared` | The audit exits 0 with 0 FAIL, the checks a prepared server must pass are PASS, and the "hard-won gotchas" of `CLAUDE.md` hold. |
| `prep-rerun` | A second run reports every step as `OK (already)` or `SKIPPED`. Then a `--only firewall` run (what the to-do says when a panel installs Docker later) keeps container traffic going through UFW and CrowdSec. |
| `reboot` | The server comes back, root and the admin log in on 822, no unit failed, port 22 still gives no login. |
| `audit-rebooted` | Still 0 FAIL after the reboot, and the gotchas still hold (`log_martians`, `suid_dumpable`...). |
| `preconfig-after` | `server-preconfig.sh --check` has no FAIL on the finished server. |

A scenario that needs a step that failed is skipped, with the reason in the report.

The VM's network uses the documentation range `198.51.100.0/24`. The machine that runs the tests reaches it from
`198.51.100.2`, which plays both the admin's workstation (`ADMIN_IPS`) and the panel server (`PANEL_IP`).
For UFW and ufw-docker it is a public address.

Not tested: Tailscale, CrowdSec enrolment, Telegram, Cloudflare Tunnel and InfluxDB (they need accounts or
secrets), adding the server to a real panel, laptops and desktops.

## Run it on your machine

You need Linux with QEMU and, for speed, access to `/dev/kvm`. No root is needed.

```bash
sudo apt install qemu-system-x86 qemu-utils xorriso    # once
tests/e2e/run.sh --list-os
tests/e2e/run.sh --os debian-13                        # 20 to 30 minutes
tests/e2e/run.sh --os ubuntu-24.04 --only docker-firewall   # one scenario (plus what it needs)
tests/e2e/preview.sh                                   # the Pages site as it will look, from your results
python3 -m http.server --bind 127.0.0.1 --directory tests/e2e/out/site 8765
```

Then open <http://localhost:8765/>: the setup console, its **Test reports** button, the list at `/e2e/` and your
run as the `main` report. `tests/e2e/build-report.sh --out DIR RESULT_DIR...` builds a single report.

- Images are cached in `~/.cache/server-prep-e2e/images` (`E2E_CACHE` changes the folder).
- Results go in `tests/e2e/out/<os>/` (ignored by git): `results.json`, one log per scenario, the server-prep
  reports, the audits and the serial console.
- `--keep` keeps the VM disk and the throwaway keys, to look around after a failure.
- Without `/dev/kvm` the VM is emulated (`E2E_ACCEL=tcg`). It works, but it is several times slower.

Run it by hand on GitHub: **Actions → e2e → Run workflow**, or `gh workflow run e2e -f os=debian-13`.

## Add a scenario

1. Add a line to `SCENARIO_TABLE` in [tests/e2e/scenarios.sh](../tests/e2e/scenarios.sh): id, group, title.
   The order of the table is the run order.
2. Write `sc_<id>()` (dashes become underscores): `begin <id>`, one `check "what must be true" $?` per
   assertion, then `finish`. Run commands in the VM with `as_root '...'` (sudo before the real run, root with the
   panel key after it) or `ssh_as USER KEY PORT '...'`.
3. If it needs a prepared server, `needs()` already covers it: every scenario after `prep-run` is skipped when the
   real run did not finish.
4. Add a row to the table above.

Write assertion names as what must be true, in plain words: they are the lines of the report.
