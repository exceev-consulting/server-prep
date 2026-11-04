## What and why

<!-- What does this change, and which problem does it fix? Link the issue: Fixes #123 -->

## How I tested it

- OS and version:
- Server type: VPS / dedicated / own server / VM
- Panel:
- Built with: Claude Code / Codex / by hand
- [ ] dry run (`--dry-run`)
- [ ] real run on a test server
- [ ] `server-audit.sh` after the run

## Verification output

<!-- Paste the end of the `./scripts/check.sh` output (planned in #34). Until that script exists, paste the output of the `bash -n` loop and of `shellcheck -S warning` from CONTRIBUTING.md, step 1. They print nothing when they pass: then write "bash -n: ok" and "shellcheck: ok". -->

```text

```

## Checklist

- [ ] `bash -n` and `shellcheck -S warning` pass
- [ ] System changes go through `run` / `write_file` / `set_kv` / `backup_file` / `pkg_install`
- [ ] A new or changed step also updates `server-prep.conf.example`, the README step table and an audit check
- [ ] User-visible change: a line under `## [Unreleased]` in `CHANGELOG.md`
- [ ] No secrets and no real IPs or hostnames
- [ ] Messages and docs use simple words
