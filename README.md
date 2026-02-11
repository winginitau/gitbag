# gitwrap (a.k.a. `g`)

An opinionated, safety-first wrapper around Git commands for people doing frequent AI-agent coding sessions (short and long) and wanting a repeatable “don’t let me destroy my repo” workflow.

We wrote this after lessons learned from a rogue agent run and subsequent recovery work: the goal is to reduce footguns, surface repository health issues early, and enforce a clean merge discipline.

## Why this exists

When you run coding agents often, you get:
- large, rapid change sets
- intermittent partial refactors
- occasional “agent went rogue” scenarios
- more frequent branch churn and merges

This tool is a guardrail:
- it runs repository health checks every time
- it blocks merges/branch ops when the repo is in a suspicious state
- it provides simple, repeatable workflows for commit/push/merge

## What `g` does

Every invocation:
- verifies you’re in a Git worktree
- checks for in-progress operations (merge/rebase/cherry-pick/revert)
- optionally runs `git fsck --full` (default enabled)

Commands:
- `g` — health check + help
- `g c` — stage all (including deletes), auto-commit if needed, push current branch
- `g b <branch>` — create/switch branch, create initial commit, push branch (blocked unless A/B/C are clean)
- `g m` — merge workflow with strict blocking rules and no-ff merge

## Blocking model (A/B/C)

`g` blocks if ANY of these are true:

A) Other local branches are ahead of upstream OR have no upstream set.  
B) Other local branches contain commits not merged into the main branch.  
C) Other worktrees are dirty (includes untracked files).

> Note: Git cannot directly inspect "uncommitted changes" on branches that are not checked out.  
> Worktrees allow multiple checked-out branches; that's what C covers.

## Configuration (environment variables)

- `G_MAIN_BRANCH` (default: `main`)
- `G_REMOTE` (default: `origin`)
- `G_FETCH` (default: `1`) — fetch remote refs before A/B checks
- `G_STRICT_FSCK` (default: `1`) — run `git fsck --full` each run (can be slow on very large repos)

Example:
```bash
G_MAIN_BRANCH=trunk G_REMOTE=upstream G_STRICT_FSCK=0 ./g c

