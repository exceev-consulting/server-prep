---
name: add-step
description: Checklist for adding or changing a step in server-prep.sh (new package, service, security setting) so the question, config, summary, report, README and audit all stay in sync. Use whenever editing server-prep.sh or server-audit.sh.
---

# Add or change a server-prep step

Use the Telegraf step as the reference implementation: `grep -n -i telegraf server-prep.sh server-audit.sh`.

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
   - is idempotent: a second run changes nothing and never overwrites the user's own config of an existing install;
   - records results with `note` (report), `changed`, and `todo` (manual follow-up for the user).
7. **`run_step x "Label" step_x`** in the main sequence.
8. **`server-prep.conf.example`**: add the variable with a comment.
9. **README** step table: one row.
10. **`server-audit.sh`** check:
    - `result <id> PASS|WARN|FAIL|INFO "Name" "detail" "fix hint"`;
    - optional features are INFO only, so they never lower the score.
11. **`CLAUDE.md`**: if you hit a non-obvious problem, add it to *Hard-won gotchas*.
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
bash -n server-prep.sh server-audit.sh
shellcheck -S warning server-prep.sh server-audit.sh   # CI fails on any warning
sudo ./server-prep.sh --config <test.conf> --dry-run --only x   # user runs it
```
Commit with a message that says *why*, for example "Pin X to its repo (ESM ships an old version)".
