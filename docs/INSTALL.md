# Installing moire — the detail behind the quickstart

The [README's quickstart](../README.md#quickstart) is the whole install. This page is
everything behind it: why the symlink, the binary-only variant, what `init-swarm` and
`wire-client` actually write, doing it by hand, and uninstalling completely.

## Why a symlink rather than a copy

```bash
git clone https://github.com/jamescazzetta/moire.git ~/.moire
mkdir -p ~/.local/bin && ln -sf ~/.moire/bin/moire ~/.local/bin/moire
# ~/.local/bin must be on PATH:  export PATH="$HOME/.local/bin:$PATH"
```

`init-swarm` resolves the real path of the binary to find the `skills/` directory
beside it — a lone copy of `bin/moire` installs the tool but not the two Agent
Skills, and says so when it skips them. `git -C ~/.moire pull` is the upgrade.

If you only want the binary and will place the skills yourself:

```bash
mkdir -p ~/.local/bin && curl -fsSL \
  https://raw.githubusercontent.com/jamescazzetta/moire/main/bin/moire \
  -o ~/.local/bin/moire && chmod +x ~/.local/bin/moire
```

There is no npm package and the repository carries no npm packaging —
`package.json` is a private manifest that exists only to run `npm test`.
`@jamescazzetta/moire` has never been published; if you find that name on a
registry, it is not this project.

## Requirements

**git ≥ 2.38.** Older git silently misses whole classes of conflict (rename/rename,
modify/delete, binary), so `moire` refuses to run rather than give you a detector
with blind spots. Stock macOS ships 2.30 — `brew install git`. **Python 3.8+**,
standard library only. No daemon, no server, no config file — per-repo settings live
in `git config`, which never travels with a clone — no account, and nothing written
into your working tree.

## `init-swarm` and `wire-client`

```bash
# create N worktrees, install the binary and git hooks, place the skills, run doctor
moire init-swarm --agents 3

# merge the hook into your agent client's settings (prints a diff first)
moire wire-client claude --scope user
moire wire-client claude --scope user --apply
```

`init-swarm` is idempotent and `--dry-run` shows exactly what it would create. It
sets up worktrees and wires the tool — it does **not** decide what each agent works
on. Partitioning work across agents is a different and much harder problem, and
deliberately out of scope.

A fresh worktree has tracked files only — no `node_modules`, `.venv`, `vendor`, or
other install output. Install dependencies in each worktree separately; do not
symlink one dependency directory across worktrees to skip the step. Concurrent
agents would then be mutating each other's dependencies, which is exactly the class
of interference moire exists to detect.

`wire-client` prints a unified diff and writes nothing until you pass `--apply`. It
preserves hooks you already have, keeps a `.moire-backup`, refuses to touch a file
it cannot parse, and reports "already wired" on a second run. That config makes
`moire` run on every agent tool use, so it is treated as a change worth showing you
before it happens.

## Doing it by hand instead

```bash
git worktree add ../repo-agent-a -b feat/a
git worktree add ../repo-agent-b -b feat/b
moire install                          # binary + git hooks into .git/
moire install --print-client-hooks     # snippet to paste
moire doctor                           # verify
```

`moire install` puts the binary and git hooks inside `.git/`, which is shared by
every worktree — so one install covers all of them, including worktrees you create
later. Nothing executable is written into your working tree, and `core.hooksPath`
is never touched.

For **Claude Code**, the snippet goes in `~/.claude/settings.json` (or a
per-worktree `.claude/settings.local.json`):

```json
{
  "hooks": {
    "PostToolUse": [
      {"matcher": "Edit|Write|MultiEdit|Bash",
       "hooks": [{"type": "command", "command": "/abs/path/.git/moire/bin/moire check"}]}
    ]
  }
}
```

The `command` path is absolute and specific to your clone. Putting it in
`~/.claude/settings.json` keeps it out of the repository; if you prefer the in-repo
`.claude/settings.local.json`, add that file to your `.gitignore`.

## The two Agent Skills

`init-swarm` installs them (or copy `skills/` into `.claude/skills/` or
`.agents/skills/` yourself):

- **`moire`** — how to read a finding and which of the five actions applies. A
  warning an agent does not know how to act on is a warning it ignores, which is
  the failure mode that made ConE (see the README's prior-art table) a comment
  nobody measured.
- **`moire-parallel`** — how to set up and run the swarm. With it installed, *"use
  moire and parallelise this across three agents"* is enough; the skill covers
  worktrees, dispatch, and the rule agents most often skip — run `moire verify`
  before calling a task done, because a semantic break often only appears once both
  sides have finished writing.

Neither skill decides how to split the work. That judgement stays with you.

## Uninstalling

Setup writes in five places and all five have to go:

1. `.git/moire/` (per repo)
2. the `post-commit` / `post-merge` hooks in `.git/hooks/` (per repo)
3. the skills at `~/.claude/skills/moire*` and `~/.agents/skills/moire*`
4. the `moire check` entry in `~/.claude/settings.json`, which `wire-client` backs
   up before touching
5. `~/.moire` plus the `~/.local/bin/moire` symlink

Deleting only `.git/moire/` leaves two git hooks pointing at a binary that is no
longer there. The worktrees `init-swarm` created are yours to keep or
`git worktree remove`.
