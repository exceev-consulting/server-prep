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
- CI must pass: `bash -n`, ShellCheck at warning level, `--help` for each script, `scripts/gen-data.sh --check` and the quick tests in `tests/`.
- The `e2e` workflow runs the scripts in a VM per system when a PR changes a script or the tests. It is not a required check yet: read its report (linked in a PR comment) before merging. A red system shows the failed assertion first.
- A changed step, setting or audit check also updates `server-prep.conf.example`, the README step table and an audit check. Then run `scripts/gen-data.sh` so the setup console shows it.
- Pull requests are squash-merged. GitHub signs the merge commit.

## Releases

One button: **Actions → release → Run workflow**, then choose `patch`, `minor` or `major`. From a terminal:

```bash
gh workflow run release -f bump=patch
```

The workflow bumps `PREP_VERSION`, moves the `[Unreleased]` notes under the new version, regenerates the setup console data and puts that commit straight on `main`, then tags and publishes the release with the scripts, the Telegraf template and `SHA256SUMS`. Everything else reaches `main` through an approved pull request: the release GitHub App, used only by this workflow, is the one exception.

To rotate the release app's private key (for example when it may have leaked, or when a maintainer leaves):

1. On the app's settings page (GitHub Apps → the release app → General → Private keys), generate a new private key. GitHub downloads a `.pem` file.
2. Put it in the `release` environment, then delete the `.pem` file from your computer:

   ```bash
   gh secret set RELEASE_APP_PRIVATE_KEY -R exceev-consulting/server-prep --env release < new-key.pem
   ```

3. Back on the app's settings page, delete the old key. The next release uses the new one.

## Hotfixes

A hotfix is a fix that cannot wait for the next patch release. The full decision is
[ADR 0003](https://github.com/exceev-consulting/server-prep/blob/main/docs/decisions/0003-hotfix-lane.md).

- **S1, blocking:** a step fails with the default answers on a supported system, a release is unusable, the audit passes
  a broken security setting, or `main` fails its checks. It is a public issue with `priority: critical`.
- **S0, security:** an exploitable defect. It stays a private advisory: see [Security reports](#security-reports).

When you are told about a critical issue:

1. Read it and confirm it. If it is not blocking, lower its priority.
2. Add `agent-ready` when the issue says what to change and how to check it. The Claude routines develop it first,
   before every milestone, on a `claude/hotfix-<n>-...` branch. Without the label nothing is developed: the label is
   your go-ahead. You can also fix it yourself on a `hotfix/<topic>` branch.
3. Review the pull request. It goes first in the review, fix and conflict routines.
4. Merge it, then release:

   ```bash
   gh workflow run release -f bump=patch
   ```

5. For a security fix, start the CHANGELOG line with `**Security fix:**` and say which step to re-run. The audit check
   `upd.server_prep` then shows WARN on servers that still use an older version.

### When a release is bad

A release that breaks servers or opens a hole, found after it was published:

1. **Stop the spread.** Edit the release on GitHub: add a first line "Do not use: see #<issue>" and untick
   *Set as the latest release*, so the badge and the download link point to the previous release. Never delete a
   release or a tag: people check their download against its `SHA256SUMS`.
2. **Tell users.** Pin the issue, and post in [Announcements](https://github.com/exceev-consulting/server-prep/discussions/categories/announcements)
   what breaks, who is affected (OS, panel, settings) and the workaround: the previous release, or the steps to skip
   with `--skip <step>`.
3. **Fix forward.** Fix on `main` through the lane above and release a new patch. Never move or reuse a tag.
4. **Close.** Set the new release as the latest, unpin the issue, and say in the CHANGELOG line which version was bad.

## Website and wiki

- The [setup console](https://exceev-consulting.github.io/server-prep/) deploys from `site/` on every push to `main` that touches it, the scripts or the README.
- The wiki is published from the `wiki/` folder by `.github/workflows/wiki.yml`. Edit pages through pull requests, not in the web editor.
- The [brand guidelines](https://exceev-consulting.github.io/server-prep/brand/) (`site/brand/`) cover the logo, colours, type and voice. When `site/social-preview.png` changes, upload it again in **Settings → General → Social preview**: GitHub has no API for the repository's preview image.

## Security reports

Security problems arrive through private advisories ([SECURITY.md](https://github.com/exceev-consulting/server-prep/blob/main/SECURITY.md)): from reporters, and as drafts from the Claude routines. You are told about each new one. Acknowledge it quickly, then decide, one advisory at a time:

- **Public fix:** most lockouts and local exposures. Fix them through the hotfix lane, in a pull request with a neutral title that does not explain how to exploit the problem.
- **Private fix:** a problem someone could exploit from outside. Fix it in the advisory's temporary private fork (*Start a temporary private fork* on the advisory page), then merge it from there.

Publish the advisory with the release that fixes it, and credit the reporter unless they prefer not.
