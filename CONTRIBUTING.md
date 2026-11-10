# Contributing to server-prep

Thanks for helping. All kinds of help are welcome:

- **Test it** on your OS, VPS provider or hardware, and tell us what worked or broke.
- **Report bugs** or **suggest ideas** in [Issues](https://github.com/exceev-consulting/server-prep/issues).
- **Ask questions** in [Discussions](https://github.com/exceev-consulting/server-prep/discussions).
- **Send a pull request**: bug fixes, support for another panel, new checks, clearer docs.

Issues labelled [`good first issue`](https://github.com/exceev-consulting/server-prep/labels/good%20first%20issue) are a good place to start.
For a big change, open an issue first so we can agree on the approach.
[GOVERNANCE.md](GOVERNANCE.md#how-decisions-are-made) says which changes need one.

Security problems: **don't open a public issue**. See [SECURITY.md](SECURITY.md).

## Set up

There is nothing to build. You need bash 5 (macOS: `brew install bash`) and curl. `scripts/check.sh` downloads the
pinned [ShellCheck](https://github.com/koalaman/shellcheck) the first time. Some checks also need jq, ssh-keygen, unzip
and python3.

```bash
git clone https://github.com/exceev-consulting/server-prep.git && cd server-prep
```

**Never test on a server you care about.** Use a throwaway VM or a cheap VPS:
`multipass launch 24.04`, an LXD/Incus VM, or a cloud VPS you delete afterwards.

The easiest throwaway VM is the one the end-to-end tests make. On Linux with QEMU, `tests/e2e/run.sh --os debian-13`
boots the official cloud image, runs the three scripts like an operator, reboots and checks the result, without
root. See [docs/e2e-tests.md](docs/e2e-tests.md).

## Before you open a pull request

1. **Syntax, lint and regression checks**: run `./scripts/check.sh`. It runs the checks of
   `.github/workflows/lint.yml`, without root and without changing the system. Its ShellCheck is pinned to 0.11.0, while
   CI uses the ShellCheck of its runner until `lint.yml` runs this script: the two can disagree on a warning that only
   one version reports.
   ```bash
   ./scripts/check.sh                # every check
   ./scripts/check.sh --list         # the sections
   ./scripts/check.sh --only lint    # one section
   scripts/check-files.sh            # after git add, before git commit (it reads only tracked and staged
                                     # files): no report, filled config, key or CLAUDE.local.md is tracked,
                                     # and every IPv4 address is an example
   gitleaks git --redact --config .gitleaks.toml   # optional, if gitleaks is installed: no secret in the history
                                                   # (no CI job runs it yet: the security workflow of #40 is to come)
   ```
   It prints one line per section (OK, FAIL or SKIP) and a summary, and exits with 1 when a section fails. The
   output of a failed section shows under its FAIL line. The sections:
   - `syntax`: `bash -n` on every script, one file per call
   - `lint`: ShellCheck `-S warning` on the same files
   - `help`: `--help` of the three scripts
   - `data`: `scripts/gen-data.sh --check`, the setup console's data matches the scripts
   - `tokens`: `scripts/check-tokens.sh`, the design token copies match `site/tokens.css`
   - `exit-status`, `swap`, `e2e-report`, `e2e-pages`: the quick tests in `tests/`, with fake commands
   - `consistency`: `scripts/check-consistency.sh`, once that file exists

   `tests/exit-status.sh` also runs the other quick tests in `tests/`: the audit tests (`audit-*.sh`; `audit-json.sh`
   checks the audit's JSON keys and schema, and every check id in its category's table in `docs/json-output.md`),
   `preconfig-json.sh`, `validate-config.sh`, `upgrade.sh`, `skills-sync.sh`, `report-json.sh` and `check-files.sh`
   (the committed-file guard on this repository, then on temp repos).
   The `lint` section uses ShellCheck 0.11.0: `scripts/check.sh` downloads it once to
   `${XDG_CACHE_HOME:-~/.cache}/server-prep/`, checks its SHA-256 on every run, and stops when the checksum does not
   match. When a tool is missing, the sections that need it show SKIP on your machine: `data` and `e2e-report` need
   jq, `exit-status` needs jq and ssh-keygen, `e2e-pages` needs jq, unzip and python3. CI has those tools.
2. **Dry run** on a test server, then a real run if your change modifies the system:
   ```bash
   sudo ./server-prep.sh --dry-run --only <step>
   sudo ./server-audit.sh
   ```
3. **End-to-end tests:** a PR that changes a script or the tests runs them on every supported system in CI, then
   a comment gives the link to the HTML report. You can run one system locally first:
   `tests/e2e/run.sh --os ubuntu-24.04` ([docs/e2e-tests.md](docs/e2e-tests.md)).
4. Say in the PR **what you tested**: OS and version, VPS or dedicated server, panel, dry run or real run.

## Rules for the scripts

- **Everything that changes the system goes through the helpers:** `run` (respects `--dry-run`),
  `run_secret SECRET CMD...` (like `run`, but shows a token or key as `***` in the log and on screen), `write_file`,
  `set_kv`, `backup_file`, `pkg_install` (installs only what is missing), `svc_disable`.
- **A step can run twice safely.** Check the current state first and only change what is missing.
- **apt:** always pass `"${APT_OPTS[@]}"`. A fresh server often runs apt in the background at boot.
- **Third-party apt repos:** download the key, **check its fingerprint**, store it in `/etc/apt/keyrings/`,
  use `signed-by`, and pin the repo at priority 900.
- **Downloads** (like ufw-docker): pin a version and check a SHA-256.
- **Works with any panel:** use `PANEL`, `PANEL_PUBKEY`, `PANEL_ACCESS`, `PANEL_IP` and `${PANEL_LABEL}` in messages.
  Code for one panel only goes behind `[[ ${PANEL,,} == <name> ]]`.
- **A new or changed step** also updates `server-prep.conf.example`, the step table in `README.md`,
  and adds a check to `server-audit.sh` (INFO when optional). List the new check's id in
  `docs/json-output.md`, in its category's table (`tests/audit-json.sh` fails otherwise). Then run
  `scripts/gen-data.sh` so the setup console (`site/`) shows it.
- **A new setting** also goes into `KNOWN_SETTINGS` in `server-prep.sh`, so `--validate` knows it, and into
  `validate_values` when it has a format to check (a yes/no setting not named `INSTALL_*`, a port, a list...).
  `tests/validate-config.sh` fails when a setting is missing from `KNOWN_SETTINGS` or a yes/no setting is not checked.
- **No secrets and no real infrastructure** in the repo: tokens, keys, real IPs or hostnames.
  Use examples like `web-01` and `192.168.1.50`. `scripts/check-files.sh` flags a tracked report, filled config
  or key, and any IPv4 address that is not an example. CI runs it through `tests/exit-status.sh`.
- **Simple words** in messages and docs. Many users are not security experts.
- Style: 4 spaces, `[[ ]]`, quote variables. `.editorconfig` has the basics.

[AGENTS.md](AGENTS.md) has the full list of conventions and the bugs already fixed (don't bring them back).
If you use [Claude Code](https://claude.com/claude-code) or Codex, the `add-step` skill (`/add-step` or `$add-step`) walks through the checklist.

## The setup console (site/)

The [setup console](https://exceev-consulting.github.io/server-prep/) is `site/index.html`, a static page published
with GitHub Pages by `.github/workflows/pages.yml`. Its data (`site/data.json`, `site/data.js`) is generated from the
scripts, the README tables and `server-prep.conf.example` by `scripts/gen-data.sh`. CI fails when the data is out of date,
so after changing a step, a setting or an audit check, run `scripts/gen-data.sh` (needs `jq`) and commit the result.

Colours, type, radii and spacing are the tokens in `site/tokens.css`, shared with the
[brand guidelines](https://exceev-consulting.github.io/server-prep/brand/) (`site/brand/`). Use a token instead of a new
colour. A page that must also work offline, like the e2e report, keeps its own copy of the tokens, and
`scripts/check-tokens.sh` fails CI when a copy, or a colour ramp on the brand page (sections 2.2 and 2.4), differs
from `site/tokens.css`. The PNG files in `site/` (link preview, home-screen icon, favicon) are
renders of the logo: section 6.2 of the brand guidelines gives their sizes.

To view the console and the brand page locally:

```bash
python3 -m http.server --bind 127.0.0.1 -d site 8000
```

## The wiki (wiki/)

The [wiki](https://github.com/exceev-consulting/server-prep/wiki) is published from the `wiki/` folder by
`.github/workflows/wiki.yml` on every push to `main`. Edit the pages there, through a pull request: changes made in the
wiki's web editor are overwritten by the next sync. Wiki links use the page name: `[Start here](Start-here)`.

## Commits and pull requests

- One topic per pull request. Small is easier to review.
- PR title: `<script or area>: <what changes>`, for example `server-audit.sh: detect Openship`.
  The title becomes the release note line, so make it clear.
- Pull requests are **squash-merged**. You don't need to sign your commits: the merge commit on `main`
  is signed by GitHub.

## Changelog

If your change matters to users, add a line under `## [Unreleased]` in `CHANGELOG.md`, in simple words.
Every merged pull request is also listed in the release notes, grouped by its label
(`security`, `enhancement`, `bug`, `documentation`; `skip-changelog` leaves it out).

## Releases (maintainers)

One button: **Actions → release → Run workflow**, then choose `patch` (fixes), `minor` (new features)
or `major` (breaking changes). From a terminal: `gh workflow run release -f bump=patch`.

The workflow:
1. bumps `PREP_VERSION` in `server-prep.sh` and moves the `[Unreleased]` notes under the new version
   in `CHANGELOG.md`, lints them, and puts that `release: vX.Y.Z` commit straight on `main`;
2. tags that commit and publishes the GitHub release: the changelog notes, the merged pull requests,
   the scripts, the Telegraf template (`telegraf.conf.example`) and a `SHA256SUMS` file.

`main` only takes approved pull requests. The one exception is the release GitHub App, which only this
workflow uses: it is on `main`'s bypass list, and its client ID (`RELEASE_APP_CLIENT_ID`) and private key
(`RELEASE_APP_PRIVATE_KEY`) live in the `release` environment, which only `main` can use. The app has
**Contents: read and write** on this repository and nothing else.

GitHub signs the commit and the tag. Bump `AUDIT_VERSION` in `server-audit.sh` by hand,
in a normal pull request, when the audit changes a lot.

The audit's JSON report has its own format version, `schema_version` ([docs/json-output.md](docs/json-output.md)).
Adding a field or a check does not change it: describe a new field in the schema's `properties`, not in `required`,
so files written by older releases still pass. Removing or renaming a field or a check id, and adding, removing or
renaming a status, break the programs that read the file: then bump `schema_version` in the JSON writer of
`server-audit.sh` and in the `const` of `docs/schemas/server-audit.schema.json`, update the doc and add a CHANGELOG
line, in the same pull request.
`AUDIT_VERSION` and `schema_version` change separately.

## Repository settings (maintainers)

These settings live in GitHub, not in a file, so no check sees them. Review them when a workflow
or the repository's owner changes.

- **Secret scanning** with **push protection** on (Settings → Code security), plus **Dependabot alerts**,
  **Dependabot security updates** and **private vulnerability reporting** ([SECURITY.md](SECURITY.md) sends
  reporters there).
- **A ruleset on `main`:** a pull request with an approving review, the required status check `lint`, no force
  push, no deletion, and the release GitHub App as the only bypass. `lint` already covers the committed-file
  guard. Once the security workflow of #40 exists, make its `security` check required only when `release.yml`
  also posts it on the release commit, or releases stop.
- **Actions:** default workflow permissions read-only, Actions may not create or approve pull requests, and
  workflows from first-time contributors need an approval.
- **The `release` environment** can only be used from `main`.
- **Code scanning** on, so the OpenSSF Scorecard results show in the Security tab once the security workflow
  exists.

## License

By contributing, you agree that your work is released under the [MIT License](LICENSE).
Everyone taking part follows the [Code of Conduct](CODE_OF_CONDUCT.md).
