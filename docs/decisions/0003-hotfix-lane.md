# 0003. A hotfix lane for blocking bugs and security problems

## Status

proposed

## Date

2026-11-03

## Context

server-prep runs as root and changes SSH and the firewall. One bad release can lock admins out of their servers
or leave a port open on every server that runs it.

Until now a blocking bug took the same path as any other bug:

- The `priority: critical` label existed ("breaks servers or security now: fix first"), but nothing acted on it.
  The routines that develop issues pick by milestone first, and stop when 5 of their pull requests are open.
- A pull request goes through review, fixes and a second review, at the routines' usual times: one to four runs a day.
- Nobody was told when a critical issue, a "do not merge" review or a security advisory appeared.
  Draft advisories piled up without anyone reading them.
- A user who ran an old release never heard of the fix: the scripts do not check for updates.

`main` is always releasable, and one release workflow tags and publishes a patch release
([CONTRIBUTING.md](../../CONTRIBUTING.md#releases-maintainers)). What is missing is everything before the merge and after
the release.

## Decision

We will run a hotfix lane with two classes:

- **S0: security.** An exploitable defect in the scripts: a lockout with the example config, a port left open, root
  login allowed, a secret readable by other users, command injection. It is reported and tracked as a private
  [security advisory](../../SECURITY.md), never as a public issue.
- **S1: blocking.** A step fails with the default answers on a supported system, a release is unusable, the audit
  passes a broken security setting, or `main` fails its checks. It is a public issue with `priority: critical`.

No new label: `priority: critical` is the trigger.

The lane, from detection to the user:

1. **Detection.** A maintainer, the issue triage, a bug report, a review or the maintainers' automation sets
   `priority: critical`, or drafts an advisory. A failed check on `main` counts too.
2. **Notification.** The maintainers are told within 30 minutes, once per event: a new critical issue, a new draft
   advisory, a "do not merge" review, a failed check on `main`, a merged critical fix that waits for its release.
3. **Two keys before code.** A critical issue reported by anyone, person or automation, is developed only after a
   maintainer adds `agent-ready` (or `ready`). This keeps an unverified report, or text written to steer an AI agent,
   from turning into a change that runs as root.
4. **Fast lane.** Once a maintainer adds the label, a critical issue goes first: before every milestone, and even
   when the usual limit of open pull requests is reached. Its branch is `claude/hotfix-<n>-...` (or `hotfix/...` for a
   person). The review, fix and conflict routines take critical pull requests first, and the next run starts at once
   instead of at its usual time.
5. **S0 decision.** For an advisory, a maintainer decides one at a time: fix it in a public pull request under a
   neutral title (most lockouts and local exposures), or keep it private and fix it in the advisory's temporary
   private fork (a remote exploit). The advisory is published with the release that fixes it.
6. **Release.** A maintainer merges and runs the release workflow with `patch`. Releases stay a human decision.
7. **Reaching users.** The audit check `upd.server_prep` compares the version on the server with the latest release.
   It is INFO, and WARN when a newer release fixes a security problem. The release notes mark these fixes with a
   "**Security fix:**" line (CHANGELOG). The "Security" group of the generated notes does not count: the `security`
   label also marks new hardening, not only fixes.
8. **Bad release.** The [maintainer handbook](https://github.com/exceev-consulting/server-prep/wiki/Maintainer-handbook)
   has a runbook: mark the release, tell users, publish the fix.

## Consequences

- A blocking bug can go from report to release in hours instead of days, with a maintainer deciding at two points:
  the label before code, and the merge.
- The audit makes one request to GitHub's API (no token, `--no-network` skips it). Without network or with GitHub's
  rate limit reached, it reports INFO and moves on.
- The maintainers receive notifications. Only events that need them are sent, once each.
- Follow-up: let the automation work inside an advisory's private fork, so S0 fixes that must stay private can use the
  same lane.

## Alternatives considered

- **A `hotfix` label.** A second label for the same meaning as `priority: critical`. Not chosen: two labels drift apart.
- **Develop critical issues without a maintainer's label.** Faster, but a report written to steer an agent could reach
  a pull request that changes SSH or the firewall. The label costs a maintainer a few seconds once notified.
- **Release automatically after a critical merge.** Not chosen: a release goes to every user, and only a maintainer
  can judge that the fix is complete.
- **Release branches (`release/1.1.x`).** Not needed while `main` is always releasable and only the latest release is
  supported ([SECURITY.md](../../SECURITY.md#supported-versions)).
- **A self-update in the scripts.** Not chosen: a script that downloads and runs a new version of itself as root is a
  larger risk than the one it fixes. The audit tells the operator, who updates.
