# GitHub files (.github/)

The root `AGENTS.md` has the project rules. These rules are for new or changed workflows and actions. The current files do not all meet them yet (most actions are pinned by tag; `workflows/release.yml` and `workflows/wiki.yml` grant write at the top level), and #40 tracks that work, so do not read them as a description of today's files.

- Pin every action by its full commit SHA, with the version in a comment (`uses: actions/checkout@<sha> # v7`), because a tag can be moved.
- Permissions: `contents: read` at the top. Grant write only to the job that needs it, as `workflows/pages.yml` does for its deploy job.
- Never use `pull_request_target` with code from a fork: it runs with write access and the repo secrets. Use `pull_request`.
- `lint` is the required check on main. The release workflow (`workflows/release.yml`) opens no pull request: it creates the release commit and the release GitHub App puts it straight on `main` (the app is the one actor on `main`'s bypass list). So the workflow lints the files it commits and posts the `lint` check-run on that commit by hand. Keep the check name `lint`. When the lint job changes, make sure the release Lint step still covers the files it commits.
- `.github/release.yml` (outside `workflows/`) is not a workflow: it only sets the categories of the generated release notes.
