@AGENTS.md

## Claude Code only

- `CLAUDE.local.md` (site-specific context, see AGENTS.md) is loaded automatically.
- Call the skills with `/name`: `/new-server`, `/audit-review`, `/monitoring`, `/add-step`.
- `.claude/settings.json` holds the permissions: the read-only commands allowed without asking, the denied reads (filled `*.conf` files at the root, Telegraf secrets) and no `git push --force`. Personal overrides go in the gitignored `.claude/settings.local.json`.
