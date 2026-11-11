---
name: add-step
description: Checklist for adding or changing a step in server-prep.sh (new package, service, security setting) so the question, config, summary, report, README and audit all stay in sync. Use whenever editing server-prep.sh or server-audit.sh.
---

# Add or change a server-prep step

Use the Telegraf step as the reference implementation: `grep -n -i telegraf server-prep.sh server-audit.sh`.

## Checklist (all of them, in this order)
1. **`ALL_STEPS`** at the top of `server-prep.sh`: insert the name in run order.
2. **Default setting** in the settings block: `INSTALL_X="${INSTALL_X:-yes}"`, with a short comment.
3. **Question** in `questions()`, in the right section:
   - an `explain "..."` line saying what it is, why it matters and the trade-off;
   - then `ask_yn` / `ask` / `ask_secret`.
4. **Summary line** in `summary_and_confirm()`.
5. **`save_answers()`**: add the variable to the `for v in` list. Secrets are never saved:
   - a secret (a token or key) goes in the `# secrets (...) are not saved here` comment of `save_answers()` instead, and in the secret list of `validate_values()` (the `for k in` line under `# Secrets:`), and is asked with `ask_secret`. That comment is what makes it a secret for `scripts/check-consistency.sh` and `scripts/gen-data.sh`;
   - a setting that must never be saved for another reason goes in `NOT_SAVED` in `scripts/check-consistency.sh`, with a reason. Never put a secret there;
   - a setting whose name looks like a secret (`*_TOKEN`, `*_KEY`...) but is not one goes in `NOT_SECRET` in that script, with a reason.
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
    - list the id in `docs/json-output.md`, in its category's table (`tests/audit-json.sh` fails otherwise);
    - a `# step: x` comment on the line above the check (its `if` block or its `result` call), so `scripts/check-consistency.sh` maps the step to it; a step with no check on purpose goes in `NO_AUDIT_CHECK` in that script, with a reason.
11. **`AGENTS.md`**: if you hit a non-obvious problem, add it to *Hard-won gotchas*.
12. **Site data**: run `scripts/gen-data.sh` and commit `site/data.json` and `site/data.js`. CI runs `scripts/gen-data.sh --check`, so a new step, setting or audit check fails the build until the data is regenerated.

## Rules
- **Third-party apt repo:**
  - verify the key fingerprint (`gpg --with-colons --show-keys`, then match `^fpr:+<FPR>:$`);
  - add a `signed-by` source;
  - add an `/etc/apt/preferences.d/<name>` pin at priority 900 (beats Ubuntu Pro ESM's 510).
- **Services that need configuration first** (agents, tunnels): install, then `systemctl disable --now` and add a `todo`. Never leave a service crash-looping.
- **Anything that could lock out SSH or the firewall** must keep the rollback and confirmation flow.

## Verify
```bash
./scripts/check.sh   # bash -n, ShellCheck -S warning (CI fails on any warning), --help, site data, tests
scripts/check-consistency.sh   # ALL_STEPS, main(), step_x(), README row, config example, save_answers, summary, ask_secret and audit check agree (check.sh runs it too)
sudo ./server-prep.sh --config <test.conf> --dry-run --only x   # user runs it
```
Commit with a message that says *why*, for example "Pin X to its repo (ESM ships an old version)".
