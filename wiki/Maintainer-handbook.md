How the project is run: triage, labels, pull requests and releases. Contributors can read it to know what to expect.

## Triage

Every new issue gets, within a few days:

- an **issue type**: Bug, Feature or Task;
- one or more **area** labels: `area: prep`, `area: audit`, `area: preconfig`, `area: docs`, `area: ci`, `area: agents`, `area: community`, `area: site`, `area: extras`;
- a **priority** (`priority: critical` to `priority: low`) and a **size** (`size: S` under a day, `M` one to three days, `L` more);
- a **panel** label when it is panel-specific: `panel: coolify`, `panel: dokploy`, `panel: openship`;
- a **milestone** (the phase it belongs to, or *Next patch release* for fixes);
- a parent epic when it is part of one, as a sub-issue.

Use `status: needs-repro` when the report lacks the steps or the output, and `status: blocked` when it waits on something else. Add `agent-ready` only when the issue has acceptance criteria and verification commands. `good first issue` marks small, well-scoped tasks.

The release notes group merged pull requests by the `security`, `enhancement`, `bug` and `documentation` labels. `skip-changelog` leaves a pull request out.

## Pull requests

- One topic per pull request, from a branch: `fix/…`, `feat/…` or `docs/…`. Nobody pushes to `main`.
- Title: `<script or area>: <what changes>`. It becomes the release-note line.
- Add a release-notes label and, for a user-visible change, a line under `## [Unreleased]` in `CHANGELOG.md`.
- CI must pass: `bash -n`, ShellCheck at warning level, `--help` for each script, and `scripts/gen-data.sh --check`.
- A changed step, setting or audit check also updates `server-prep.conf.example`, the README step table and an audit check. Then run `scripts/gen-data.sh` so the setup console shows it.
- Pull requests are squash-merged. GitHub signs the merge commit.

## Releases

One button: **Actions → release → Run workflow**, then choose `patch`, `minor` or `major`. From a terminal:

```bash
gh workflow run release -f bump=patch
```

The workflow bumps `PREP_VERSION`, moves the `[Unreleased]` notes under the new version, regenerates the setup console data, merges that through its own pull request, then tags and publishes the release with the scripts, the Telegraf template and `SHA256SUMS`.

## Website and wiki

- The [setup console](https://exceev-consulting.github.io/server-prep/) deploys from `site/` on every push to `main` that touches it, the scripts or the README.
- The wiki is published from the `wiki/` folder by `.github/workflows/wiki.yml`. Edit pages through pull requests, not in the web editor.
- The [brand guidelines](https://exceev-consulting.github.io/server-prep/brand/) (`site/brand/`) cover the logo, colours, type and voice. When `site/social-preview.png` changes, upload it again in **Settings → General → Social preview**: GitHub has no API for the repository's preview image.

## Security reports

Security problems arrive through private advisories ([SECURITY.md](https://github.com/exceev-consulting/server-prep/blob/main/SECURITY.md)). Acknowledge them quickly, fix them in a private fork when possible, and publish the advisory with the release that fixes it.
