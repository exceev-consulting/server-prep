---
name: add-step
description: Checklist for adding or changing a step in server-prep.sh (new package, service, security setting) so the question, config, summary, report, README and audit all stay in sync. Use whenever editing server-prep.sh or server-audit.sh.
---

# Add or change a server-prep step

Use the Telegraf step as the reference implementation: `grep -n -i telegraf server-prep.sh server-audit.sh`. For a third-party apt repository, follow `cloudflared_repo` instead (`grep -n -i cloudflared server-prep.sh server-audit.sh`): Telegraf does not call `drop_other_sources`.

## Checklist (all of them, in this order)
1. **`ALL_STEPS`** near line 31: insert the name in run order.
2. **Default setting** in the settings block: `INSTALL_X="${INSTALL_X:-yes}"`, with a short comment.
3. **Question** in `questions()`, in the right section:
   - an `explain "..."` line saying what it is, why it matters and the trade-off;
   - then `ask_yn` / `ask` / `ask_secret`.
4. **Summary line** in `summary_and_confirm()`.
5. **`save_answers()`**: add the variable, unless it is a secret. Secrets are never saved.
6. **`step_x()`**:
   - starts with `yes_ "$INSTALL_X" || return $SKIP_RC`;
   - changes things only through `run`, `write_file`, `set_kv` and `pkg_install` (so dry-run works);
   - a command that takes a token or key uses `run_secret SECRET CMD...` instead of `run`, so the secret shows as `***` in the log and the dry-run output;
   - is idempotent: a second run changes nothing and never overwrites the user's own config of an existing install;
   - records results with `note` (report), `changed`, and `todo` (manual follow-up for the user).
7. **`run_step x "Label" step_x`** in the main sequence.
8. **`server-prep.conf.example`**: add the variable with a comment.
9. **README** step table: one row.
10. **`server-audit.sh`** check:
    - `result <id> PASS|WARN|FAIL|INFO "Name" "detail" "fix hint"`;
    - optional features are INFO only, so they never lower the score;
    - list the id in `docs/json-output.md`, in its category's table (`tests/audit-json.sh` fails otherwise).
11. **`AGENTS.md`**: if you hit a non-obvious problem, add it to *Hard-won gotchas*.
12. **Site data**: run `scripts/gen-data.sh` and commit `site/data.json` and `site/data.js`. CI runs `scripts/gen-data.sh --check`, so a new step, setting or audit check fails the build until the data is regenerated.

## Rules
- **Third-party apt repo:**
  - add the key with `apt_repo_key NAME URL FPR /etc/apt/keyrings/<name>.gpg`: it keeps only one key with the published fingerprint (a bundle or a secret key is refused) and checks a key in place on every run;
  - then call `drop_other_sources <repo URL without scheme> <your source file name>` before writing your source, so apt never sees the repository with two keys (never before `apt_repo_key`: a failed key check must leave the old source in place);
  - add the tool to `REPO_SPECS` in `server-audit.sh` (check `upd.repo_keys`);
  - add a `signed-by` source;
  - add an `/etc/apt/preferences.d/<name>` pin at priority 900 (beats Ubuntu Pro ESM's 510).
- **Services that need configuration first** (agents, tunnels): install, then `systemctl disable --now` and add a `todo`. Never leave a service crash-looping.
- **Anything that could lock out SSH or the firewall** must keep the rollback and confirmation flow.

## Verify
```bash
./scripts/check.sh   # bash -n, ShellCheck -S warning (CI fails on any warning), --help, site data, tests
sudo ./server-prep.sh --config <test.conf> --dry-run --only x   # user runs it
```
Commit with a message that says *why*, for example "Pin X to its repo (ESM ships an old version)".
