@AGENTS.md

## Claude Code only

- `CLAUDE.local.md` (site-specific context, see AGENTS.md) is loaded automatically.
- Call the skills with `/name`: `/new-server`, `/audit-review`, `/monitoring`, `/add-step`.
- `.claude/settings.json` holds the permissions: the read-only commands allowed without asking, the files the Read tool may not open (filled `*.conf` files at the root, Telegraf secrets; shell commands can still read them, so the Safety rule in AGENTS.md applies) and no `git push --force`. Personal overrides go in the gitignored `.claude/settings.local.json`.
