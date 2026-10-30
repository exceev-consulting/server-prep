# 0001. Record architecture decisions

## Status

accepted

## Date

2026-10-29

## Context

Some choices shape the scripts: how panels are handled, how tests run, which tools we use (like a formatter).
These choices were made in issues and chats. Later contributors and agents cannot find why they were made.

## Decision

We record architecture decisions here, in `docs/decisions/`, one file per decision.
Each file is a copy of [0000-template.md](0000-template.md) and follows [README.md](README.md) in this folder.

## Consequences

Past choices are easy to find, and they are reviewed in pull requests like code.
The cost is one small extra file for each big change.

## Alternatives considered

- Only issues and discussions: hard to find later, and they have no status.
- The wiki: it explains how things work today, not why a choice was made.
- Nothing: the reasons get lost.
