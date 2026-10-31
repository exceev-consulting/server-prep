# Governance

How server-prep is run: who does what, how decisions are made, and who releases.

## Roles

- **Users** run the scripts on their servers. They get help through [SUPPORT.md](SUPPORT.md).
- **Contributors** open issues, discussions or pull requests. They follow [CONTRIBUTING.md](CONTRIBUTING.md).
- **Maintainers** triage issues, review and merge pull requests, publish releases, handle security reports
  and enforce the Code of Conduct.

The current maintainers are listed in [.github/CODEOWNERS](.github/CODEOWNERS). GitHub asks them to review pull requests.

## How decisions are made

- **Small fixes and doc changes** are decided in the pull request review.
- **Bigger changes need an issue first**: a new step, a new panel, a changed default, or anything that touches SSH,
  the firewall or root access. Open the issue (the feature request form works) and discuss it there.
  A maintainer labels it `proposal`, then moves it to `ready` when the approach is agreed. Only then open the pull request.
- **Architecture choices** get an ADR (architecture decision record) in [docs/decisions/](docs/decisions/README.md).
  It is reviewed in a pull request, like code.

## Releases

Only maintainers release, through the release workflow. See [Releases (maintainers)](CONTRIBUTING.md#releases-maintainers).

Nobody pushes to `main`. Every change goes through a pull request.

## Security reports

Security problems are reported privately, as an advisory: see [SECURITY.md](SECURITY.md). Maintainers handle them.
Never report one in a public issue or discussion.

## AI-assisted contributions

Contributions made with Claude Code, Codex or other AI tools are welcome. They follow the same rules
([CONTRIBUTING.md](CONTRIBUTING.md), [CLAUDE.md](CLAUDE.md)) and get the same review.

The person who opens the pull request answers for it. They understand the change, they ran the tests the pull request
mentions, and they reply to the review. See
[Working with AI agents](https://github.com/exceev-consulting/server-prep/wiki/Working-with-AI-agents) on the wiki.

## Becoming a maintainer

Maintainers invite contributors who have helped over time: merged pull requests, reviews, answers in Discussions,
triage. You can also ask a maintainer. The current maintainers agree together.

A new maintainer gets write access and is added to `.github/CODEOWNERS` in a pull request.
Stepping down works the same way: a pull request removes the name.

## Code of Conduct

Everyone follows the [Code of Conduct](CODE_OF_CONDUCT.md). The maintainers are the "community leaders" it mentions:
they enforce it. See [Enforcement](CODE_OF_CONDUCT.md#enforcement) for how to report a problem and
[Enforcement Guidelines](CODE_OF_CONDUCT.md#enforcement-guidelines) for what happens next.

## Changing this document

Through a pull request, like any other file.
