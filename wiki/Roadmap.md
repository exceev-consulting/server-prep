Where server-prep is going: the phases, the epics that group the work, the public board, and how to pick something to work on.

## The goal

The top epic is [#6](https://github.com/exceev-consulting/server-prep/issues/6). In short: someone with **no DevOps or security background** opens the repo in Claude Code or Codex, says "set up my new server", and ends with a hardened server, connected to their panel, with an audit that shows 0 FAIL.

To get there, the work is split into five workstreams. Each one is an epic, and each epic has sub-issues, one pull request each.

What exists today is described in the [README](https://github.com/exceev-consulting/server-prep/blob/main/README.md) and on [Architecture](Architecture). Everything on this page that is not marked as done is **planned**: follow the linked issue for its status.

## The public board

All issues are on the **[server-prep roadmap](https://github.com/orgs/exceev-consulting/projects/7)** project board. It is public: you can read it without an account.

The board has these fields:

- **Status**: Backlog, Ready, In progress, In review, Done.
- **Priority**: Critical, High, Medium, Low.
- **Size**: S (under a day), M (1 to 3 days), L (more than 3 days, may be split).
- **Area** and **Panel**: the part of the repo, and the panel when the work is panel-specific.
- **Milestone** and **Parent issue**: the phase, and the epic the issue belongs to.

And these views: All items, Board, Agent-ready, Phase 0: Foundation, Bugs, and Needs triage.

## Phases (milestones)

Each phase is a GitHub [milestone](https://github.com/exceev-consulting/server-prep/milestones). The phases are in order: Phase 0 unblocks the rest. Bug fixes go in their own milestone, released as a patch.

### Next patch release

[Milestone](https://github.com/exceev-consulting/server-prep/milestone/6) · Epic [#12](https://github.com/exceev-consulting/server-prep/issues/12)

Fixes from a code review of the scripts, the docs and CI (October 2026). Each defect was found by reading the code. **None was reproduced on a server yet**, so confirm it on a throwaway VM first. Examples:

- secrets in a log file that other users can read ([#64](https://github.com/exceev-consulting/server-prep/issues/64));
- `--yes` answering the SSH safety prompt by itself ([#65](https://github.com/exceev-consulting/server-prep/issues/65));
- `rollback.sh` that can lock you out ([#71](https://github.com/exceev-consulting/server-prep/issues/71));
- the audit's "Docker vs firewall" check passing too easily ([#69](https://github.com/exceev-consulting/server-prep/issues/69));
- `server-prep.sh` exiting 0 when a step failed ([#76](https://github.com/exceev-consulting/server-prep/issues/76)).

Many of these are small and labelled `good first issue` or `agent-ready`.

### Phase 0: Foundation

[Milestone](https://github.com/exceev-consulting/server-prep/milestone/1)

The base that everything else plugs into:

- `AGENTS.md`, one context file for every coding agent ([#32](https://github.com/exceev-consulting/server-prep/issues/32)), and the skills shared with Codex ([#33](https://github.com/exceev-consulting/server-prep/issues/33));
- `scripts/check.sh`, which runs every CI check on your machine ([#34](https://github.com/exceev-consulting/server-prep/issues/34));
- `scripts/check-consistency.sh`, which keeps steps, README, config example and audit in sync ([#35](https://github.com/exceev-consulting/server-prep/issues/35));
- Claude Code hooks: lint after each edit, block pushes to `main` ([#36](https://github.com/exceev-consulting/server-prep/issues/36));
- labels kept in `.github/labels.yml` ([#24](https://github.com/exceev-consulting/server-prep/issues/24));
- governance files: `GOVERNANCE.md`, `SUPPORT.md`, `CODEOWNERS`, a roadmap file and an ADR template ([#30](https://github.com/exceev-consulting/server-prep/issues/30)).

### Phase 1: Community & CI

[Milestone](https://github.com/exceev-consulting/server-prep/milestone/2) · Epics [#8](https://github.com/exceev-consulting/server-prep/issues/8) and [#9](https://github.com/exceev-consulting/server-prep/issues/9)

- **Wiki, Discussions and project management ([#8](https://github.com/exceev-consulting/server-prep/issues/8)).** This wiki, with its source in `wiki/` and published by a workflow ([#27](https://github.com/exceev-consulting/server-prep/issues/27), [#28](https://github.com/exceev-consulting/server-prep/issues/28)), a providers and hardware compatibility matrix ([#29](https://github.com/exceev-consulting/server-prep/issues/29)), Discussions categories and forms ([#26](https://github.com/exceev-consulting/server-prep/issues/26)), the board ([#25](https://github.com/exceev-consulting/server-prep/issues/25)) and triage automation ([#31](https://github.com/exceev-consulting/server-prep/issues/31)).
- **CI, templates and agent-ready contributing ([#9](https://github.com/exceev-consulting/server-prep/issues/9)).** Unit tests ([#37](https://github.com/exceev-consulting/server-prep/issues/37)), an integration matrix on Ubuntu and Debian that checks a second run changes nothing ([#38](https://github.com/exceev-consulting/server-prep/issues/38)), docs and link checks ([#39](https://github.com/exceev-consulting/server-prep/issues/39)), secret scanning and pinned actions ([#40](https://github.com/exceev-consulting/server-prep/issues/40)), PR hygiene checks ([#41](https://github.com/exceev-consulting/server-prep/issues/41)), new issue forms ([#42](https://github.com/exceev-consulting/server-prep/issues/42)), contributor skills ([#44](https://github.com/exceev-consulting/server-prep/issues/44)), a "contribute with an agent" guide ([#43](https://github.com/exceev-consulting/server-prep/issues/43)) and an optional agent review on PRs, started by maintainers only ([#45](https://github.com/exceev-consulting/server-prep/issues/45)).

### Phase 2: Panels & Openship

[Milestone](https://github.com/exceev-consulting/server-prep/milestone/3) · Epic [#10](https://github.com/exceev-consulting/server-prep/issues/10)

Today `PANEL=openship` only changes the labels in messages. Coolify has more: hints, audit checks, guides. This phase brings Openship to the same level:

- panel profiles instead of panel checks spread over the scripts ([#46](https://github.com/exceev-consulting/server-prep/issues/46)), and an `/add-panel` checklist ([#47](https://github.com/exceev-consulting/server-prep/issues/47));
- an Openship profile with its own questions and hints ([#48](https://github.com/exceev-consulting/server-prep/issues/48)), audit checks ([#53](https://github.com/exceev-consulting/server-prep/issues/53)) and a guide ([#55](https://github.com/exceev-consulting/server-prep/issues/55));
- Openship-specific fixes, for example the control plane on the same server that cannot SSH to its host ([#49](https://github.com/exceev-consulting/server-prep/issues/49));
- an end-to-end test on an Ubuntu 24.04 VPS and a Debian 13 dedicated server ([#57](https://github.com/exceev-consulting/server-prep/issues/57)).

### Phase 3: Agent install for beginners

[Milestone](https://github.com/exceev-consulting/server-prep/milestone/4) · Epic [#7](https://github.com/exceev-consulting/server-prep/issues/7)

- JSON outputs, so an agent reads facts instead of colored text: `server-preconfig.sh --check --json` ([#13](https://github.com/exceev-consulting/server-prep/issues/13)), `server-prep.sh --plan --json` ([#14](https://github.com/exceev-consulting/server-prep/issues/14)), a JSON report ([#15](https://github.com/exceev-consulting/server-prep/issues/15)), and a documented audit JSON ([#16](https://github.com/exceev-consulting/server-prep/issues/16));
- `--validate` for config files ([#17](https://github.com/exceev-consulting/server-prep/issues/17));
- a beginner mode in `/new-server` with safe defaults and a lockout guard ([#18](https://github.com/exceev-consulting/server-prep/issues/18));
- beginner notes per VPS provider and for dedicated servers ([#19](https://github.com/exceev-consulting/server-prep/issues/19)), and a "getting started with an agent" guide ([#20](https://github.com/exceev-consulting/server-prep/issues/20));
- a usability test with real beginners ([#23](https://github.com/exceev-consulting/server-prep/issues/23)).

### Phase 4: Capability page

[Milestone](https://github.com/exceev-consulting/server-prep/milestone/5) · Epic [#11](https://github.com/exceev-consulting/server-prep/issues/11)

**Partly done.** The [setup console](https://exceev-consulting.github.io/server-prep/) is live. Its data generator ([#59](https://github.com/exceev-consulting/server-prep/issues/59)), the page ([#60](https://github.com/exceev-consulting/server-prep/issues/60)) and the Pages deploy with a data-drift check ([#61](https://github.com/exceev-consulting/server-prep/issues/61)) are closed. Still open: an accessibility and mobile review ([#62](https://github.com/exceev-consulting/server-prep/issues/62)), and showing Openship and the beginner flow once they ship ([#63](https://github.com/exceev-consulting/server-prep/issues/63)).

## How to pick an item

1. **Start small.** Look for the [`good first issue`](https://github.com/exceev-consulting/server-prep/labels/good%20first%20issue) label, size `S`.
2. **Using Claude Code or Codex?** Pick from the board's **Agent-ready** view, or the [`agent-ready`](https://github.com/exceev-consulting/server-prep/labels/agent-ready) label. These issues have acceptance criteria and commands to verify the work. See [Working with AI agents](Working-with-AI-agents).
3. **Check the order.** Read the issue's *Depends on* line. Phase 0 items come first, and some Phase 1 items wait for them.
4. **Say you are on it.** Leave a comment on the issue, so two people do not do the same work.
5. **For a big change**, agree on the approach in the issue before you write code.
6. Then follow [CONTRIBUTING.md](https://github.com/exceev-consulting/server-prep/blob/main/CONTRIBUTING.md): a branch, one topic per PR, and the checks.

Have an idea that is not on the board? Open a [feature request](https://github.com/exceev-consulting/server-prep/issues/new/choose), or start a thread in [Discussions](https://github.com/exceev-consulting/server-prep/discussions).
