---
name: moire-parallel
description: Set up and run several coding agents in parallel on one repository, with moire watching for collisions between them. Use when asked to parallelise work across agents, split a task among agents, or run agents concurrently in git worktrees.
---

Run N agents at once, each in its own git worktree, with `moire` reporting when any
two of them are about to break each other.

## Before anything: should this be parallel at all?

Decomposition is a judgement call and it is yours (or the user's) to make — `moire`
has no opinion about it and will not help.

**Parallelise when** the work splits into pieces that touch mostly different parts of
the codebase, and each piece is independently verifiable.

**Do not parallelise when** the pieces share a core abstraction, or when one must land
before another can be written. Say so and work sequentially instead. Splitting tightly
coupled work across agents produces collisions faster than any tool can report them,
and serial execution is a legitimate answer, not a failure.

If unsure, prefer fewer agents. Three is usually plenty; the coordination cost grows
with every additional one.

## Setup

```bash
moire init-swarm --agents 3
```

This creates `../<repo>-agent-1`, `-2`, `-3`, installs the binary and git hooks into
`.git/` (shared by every worktree), places the skills, and runs `doctor`. It is
idempotent and `--dry-run` shows the plan without touching anything.

Each worktree is tracked files only. Install dependencies in each one separately —
do not symlink a shared `node_modules`, `.venv`, or `vendor` across worktrees to
skip the step. Concurrent agents would then be mutating each other's dependencies,
which is exactly the class of interference moire exists to detect.

If `moire doctor` reports the client hook is not wired, run this once — it prints a
diff first and writes nothing until `--apply`:

```bash
moire wire-client claude --scope user --apply
```

`init-swarm` does **not** assign work. That is the next step, and it is yours.

## Dispatch

Spawn one agent per worktree. If your harness supports worktree isolation, use it and
skip `init-swarm` — `moire` discovers peers through `git worktree list` and does not
care who created them.

Give each agent:

- **Its worktree path**, and an instruction to stay inside it. An agent that wanders
  into a sibling worktree defeats the whole arrangement.
- **One task**, scoped so it can be finished and verified alone.
- **No instruction to coordinate with the others.** They do not need to talk. Agents
  negotiating with each other has been measured to consume budget without improving
  outcomes; `moire` reports collisions as facts instead.

## What each agent must do

Two rules, and the second is the one that gets skipped:

1. **Act on findings as they appear.** The hook runs `moire check` after every write.
   A `CONFLICT` or `BROKEN` line means another agent's live work collides with yours —
   the `moire` skill covers how to read one and which action applies.
2. **Run `moire verify` before declaring the task done.** The per-write hook catches
   collisions as they happen, but a semantic break often only becomes one once *both*
   sides have finished writing. `verify` is what catches a merge that is textually
   clean and functionally broken.

## Collecting the result

Each agent's work is a branch. Merge them in whatever order suits; `moire report`
afterwards shows how often they collided and which paths were contested.

If two branches conflicted and neither yielded, the arbiter line in the finding named
which one should have — that is the one to rebase onto the other.

## What this does not do

`moire` detects and reports. It never blocks a write, never rebases for you, and never
decides who yields — the arbiter emits a recommendation both sides compute identically,
and acting on it is voluntary. If the agents ignore every finding, the tool changes
nothing, which is the failure mode worth watching for.
