---
name: audit-review
description: Analyse server-audit.sh output pasted by the user (or a report file) and turn every WARN/FAIL into a concrete fix command. Use when the user says "analyse", pastes audit output, or asks where the server setup stands.
---

# Analyse an audit

1. **Get the output.** Use what the user pasted, or read `server-audit-*.txt` / `/root/server-prep-reports/*.md`. If none exists, ask them to run `sudo ./server-audit.sh`. As non-root, several checks are approximate.
2. **Answer in this order, and briefly:**
   - **Score:** PASS / WARN / FAIL counts, compared with the last run if known.
   - **FAIL:** each with its cause and the exact fix command.
   - **WARN:** sort them into *expected* (see below) and *to fix*.
   - **Next action:** one command if possible.
3. **Prefer server-prep re-runs** over manual edits, so that the saved config stays the source of truth:
   `sudo ./server-prep.sh --config /etc/server-prep/server-prep.conf --only <steps> --yes`
   Leave out `--yes` when the steps include `ssh`: it skips the second-terminal login test and stops the 10-minute rollback (#65).
4. **Before suggesting a fix,** check `AGENTS.md` → *Hard-won gotchas*. Several "regressions" after a reboot are already known (log_martians, suid_dumpable, sudo-rs).

## Expected WARNs on this fleet
- **Desktop service count** (GNOME, about 40 services) on the laptop server.
- **Regular, non-security updates pending:** suggest `sudo apt upgrade`. Unattended-upgrades only handles security updates.
- **Reboot required after a kernel update:** suggest `sudo reboot` in a quiet moment (GitHub runners idle).
- **Telegraf INFO "installed, not configured"** until `/monitoring` is done.

## Investigating memory or OOM events
```bash
journalctl -k --since -2d | grep -i -E "oom|killed process"
systemd-cgtop -m --depth=2
```
On the laptop, GitHub runner jobs were the cause. Check that `actions-runners.slice` still exists with `systemctl show -p MemoryMax actions-runners.slice`.
