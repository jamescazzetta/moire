# moire

**Tells parallel AI coding agents when their in-flight work would break each other — before either of them lands.**

> When two agents work at once, what checks that their changes still fit together —
> before one of them lands?

---

## The problem

You run several AI coding agents at once to go faster. Each works in its own git worktree so they can't overwrite each other. Then you combine their work, and it breaks.

Here's the shape of it:

> **Agent A** renames `validate_session` to `validate_session_v2` in `auth.py`, and carefully updates every caller it can see. Correct work.
>
> **Agent B** adds a new file that calls `validate_session`. Also correct work — in B's
> worktree, that function still exists.
>
> A touched `auth.py` and its callers. B touched a file A never opened. Their file sets
> are **disjoint**, so git merges them cleanly — no conflict markers, no warning. The
> merged result calls a function that is no longer there.

That last detail is what makes it slip through. Had B added the call *into* a file A
also edited, git would have raised a conflict and someone would have looked. Disjoint
edits get no such scrutiny — which is why there are two checks:

- `moire check` catches the overlapping case **earlier than git would**, while both
  agents are still writing.
- `moire verify` catches the disjoint case, which nothing surveyed does.

Or, as a house:

> One builder moves the front door to the side. Another builds a garden path up to where the front door used to be. Neither touched the other's work. Both jobs are individually correct. Together you have a path leading to a wall.

Git catches overlapping **lines**. It cannot catch overlapping **meaning**. CI catches it only after both changes have landed, when unwinding is expensive and both agents have moved on.

## What moire does

After each file write, it runs a **dress rehearsal**: it combines your working tree with each other agent's working tree in a scratch space nobody sees, and checks whether the combination actually holds.

```
$ moire check
CONFLICT with /repo-agent-b (feat/auth) [finding 675ef3f810e1]
    src/api.py
  arbiter: self yields (adoptability: self has uncommitted work, peer is fully committed)
  actions: rebase onto theirs | narrow your change | retarget | wait for them to land | proceed
```

```
$ moire verify
BROKEN with /repo-agent-b (1 new breakage, merged tree d6d2141b)
    ('src/service.py', 'src.auth', 'validate_session')
```

That second one is the case git merges cleanly. What it costs to find is
[measured below](#cost).

## Quickstart

```bash
git clone https://github.com/jamescazzetta/moire.git ~/.moire
mkdir -p ~/.local/bin && ln -sf ~/.moire/bin/moire ~/.local/bin/moire
# ~/.local/bin must be on PATH:  export PATH="$HOME/.local/bin:$PATH"

cd your-repo
moire init-swarm --agents 3                     # worktrees, hooks, skills, doctor
moire wire-client claude --scope user --apply   # shows a diff first
```

A symlink rather than a copy, because `init-swarm` resolves the real path of the
binary to find the `skills/` directory beside it — a lone copy of `bin/moire`
installs the tool but not the two Agent Skills, and says so when it skips them.
`git -C ~/.moire pull` is the upgrade.

If you only want the binary and will place the skills yourself:

```bash
mkdir -p ~/.local/bin && curl -fsSL \
  https://raw.githubusercontent.com/jamescazzetta/moire/main/bin/moire \
  -o ~/.local/bin/moire && chmod +x ~/.local/bin/moire
```

There is no npm package. `package.json` exists in this repository and
`@jamescazzetta/moire` has never been published; if you find that name on a
registry, it is not this project.

Needs **git ≥ 2.38** and **Python 3.8+**. No daemon, no server, no config file — per-repo
settings live in `git config`, which never travels with a clone — no account, and nothing
written into your working tree.

**Uninstalling is not one directory**, and an earlier version of this README said it
was. Setup writes in five places and all five have to go: `.git/moire/` and the
`post-commit` / `post-merge` hooks in `.git/hooks/` (per repo); the skills at
`~/.claude/skills/moire*` and `~/.agents/skills/moire*`; the `moire check` entry in
`~/.claude/settings.json`, which `wire-client` backs up before touching; and `~/.moire`
plus the `~/.local/bin/moire` symlink. Deleting only `.git/moire/` leaves two git hooks
pointing at a binary that is no longer there. The worktrees `init-swarm` created are
yours to keep or `git worktree remove`.

## Where it fits

Everything below already runs somewhere in your pipeline. The gap is the last two rows.

| | sees | catches |
| --- | --- | --- |
| `git merge` | overlapping lines | conflicts — at merge time |
| code review | two separate diffs | nothing; each diff looks correct |
| CI | the merged result | everything — after both have landed |
| [Clash](https://github.com/clash-sh/clash) | the committed HEAD of each worktree | conflicts between two agents' last commits |
| **`moire check`** | **both live worktrees, uncommitted included** | **conflicts, while both are still writing** |
| **`moire verify`** | **the merge that would result, right now** | **breakage that merges cleanly** |

### Compared with Clash

**`moire check` is not novel.** [Clash](https://github.com/clash-sh/clash) (Rust, MIT)
ships the same `git merge-tree` oracle between agent worktrees, with a Claude Code
hook, and got there first. The same primitive was also published as a measurement
method by Xu, Subramanian & Karthik ([arXiv:2607.04697](https://arxiv.org/abs/2607.04697)),
who ran `git merge-tree --write-tree $C_A $C_B` over 747 co-active agent PR pairs.
`moire check` is *different*, not first, and the difference is two testable claims.

**Claim 1 — Clash's simulation cannot see uncommitted work; moire's is built on it.**
Clash merges each worktree's `commit.tree_id()`; it renders a `Dirty` marker but
excludes dirty state from the simulation. That comes from reading
`src/worktree/conflict.rs` — Clash's README does not say it — so this is a claim about
its source, not about a run of it. Two minutes to falsify:

```bash
git init -q A && cd A
mkdir src && printf 'def validate_session(t):\n    return t\n' > src/auth.py
git add -A && git commit -qm base
git worktree add -q ../B -b feat/b

# both agents edit the SAME LINE; neither commits
printf 'def validate_session(t):\n    return t and 1\n' > src/auth.py
printf 'def validate_session(t):\n    return t and 2\n' > ../B/src/auth.py

git rev-parse --short HEAD; git -C ../B rev-parse --short HEAD   # identical
moire check
```

The two HEADs are the same commit, so a HEAD-based simulation has nothing to compare
and can only report nothing. Run here 2026-08-12: both worktrees at `77e092d`,
`moire check` → `CONFLICT ... src/auth.py`. Commit both sides and every tool agrees.

**Claim 2 — nothing surveyed runs a checker on the speculative merged tree.**
Clash's FAQ scopes it to detection, textual only. This is the canonical example
(`tests/test_verify.sh` case 2): A renames a function and updates its callers, B adds a
*new* file calling the old name, file sets disjoint, merge textually clean.

```bash
git init -q A && cd A
mkdir src
printf 'def validate_session(t):\n    return t\n' > src/auth.py
printf 'from src.auth import validate_session\n\n\ndef go(t):\n    return validate_session(t)\n' > src/api.py
git add -A && git commit -qm base
git worktree add -q ../B -b feat/b

# A renames, and updates the caller it can see
printf 'def validate_session_v2(t):\n    return t\n' > src/auth.py
printf 'from src.auth import validate_session_v2\n\n\ndef go(t):\n    return validate_session_v2(t)\n' > src/api.py
# B adds a new file calling the old name
printf 'from src.auth import validate_session\n\n\ndef handle(t):\n    return validate_session(t)\n' > ../B/src/service.py

moire check    # clean   — correct; there is no textual conflict
moire verify   # BROKEN  ('src/service.py', 'src.auth', 'validate_session')
```

A textual detector reporting nothing here is right by its own scope, which is the
point: the two tools disagree because they answer different questions. Run here
2026-08-12, output exactly as commented.

**Where Clash wins, and it is conceded.** A Rust binary installs more easily than a
Python file you have to put on `PATH`. Clash can *gate* an edit through a `PreToolUse`
ask-hook; moire never blocks and has no flag to make it — a design position, not a
missing feature, and if you want a gate you should use Clash. Per-check latency has
not been compared and no claim is made either way.

## Three things that make it unusual

- **It asks nobody anything.** It reads the other agent's files. The other agent needs
  no setup, no awareness of the tool, and may be from a different vendor.
- **It is exact, not a guess.** No heuristics, thresholds, model or tuning — `check`
  runs git's own merge engine, `verify` runs a real checker on a real tree.
- **It never blocks.** Warn-only by design, with no block mode and no flag to add one.

Each of those is a reaction to something that has already been tried and measured.

## Install

The quickstart above is the whole thing; this section is the detail behind it.

**Requires git ≥ 2.38.** Older git silently misses whole classes of conflict
(rename/rename, modify/delete, binary), so `moire` refuses to run rather than give you
a detector with blind spots. Stock macOS ships 2.30 — `brew install git`.

```bash
# create N worktrees, install the binary and git hooks, place the skills, run doctor
moire init-swarm --agents 3

# merge the hook into your agent client's settings (prints a diff first)
moire wire-client claude --scope user
moire wire-client claude --scope user --apply
```

`init-swarm` is idempotent and `--dry-run` shows exactly what it would create.
It sets up worktrees and wires the tool — it does **not** decide what each agent
works on. Partitioning work across agents is a different and much harder problem,
and deliberately out of scope.

A fresh worktree has tracked files only — no `node_modules`, `.venv`, `vendor`, or
other install output. Install dependencies in each worktree separately; do not
symlink one dependency directory across worktrees to skip the step. Concurrent
agents would then be mutating each other's dependencies, which is exactly the
class of interference moire exists to detect.

`wire-client` prints a unified diff and writes nothing until you pass `--apply`.
It preserves hooks you already have, keeps a `.moire-backup`, refuses to touch a
file it cannot parse, and reports "already wired" on a second run. That config
makes `moire` run on every agent tool use, so it is treated as a change worth
showing you before it happens.

<details>
<summary>Doing it by hand instead</summary>

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

</details>

`init-swarm` also installs two Agent Skills (or copy `skills/` into `.claude/skills/`
or `.agents/skills/` yourself):

- **`moire`** — how to read a finding and which of the five actions applies. A warning
  an agent does not know how to act on is a warning it ignores, which is the failure
  mode that made ConE, below, a comment nobody measured.
- **`moire-parallel`** — how to set up and run the swarm. With it installed, *"use
  moire and parallelise this across three agents"* is enough; the skill covers
  worktrees, dispatch, and the rule agents most often skip — run `moire verify` before
  calling a task done, because a semantic break often only appears once both sides have
  finished writing.

Neither skill decides how to split the work. That judgement stays with you.

## Commands

| | |
|---|---|
| `moire check` | Would my worktree conflict **textually** with each peer, right now? |
| `moire verify` | Would the merged result be **semantically broken**, right now? Reads `moire.checker` / `moire.link` from `git config` when `--checker` / `--link` are absent. |
| `moire replay <a> <b>` | The `verify` mechanism on two **commits** instead of two live worktrees — the measurement instrument. Stateless: no log, no cache, no snapshot, and it works in a bare clone. |
| `moire install` | Install git hooks and the binary into `.git/` |
| `moire doctor` | Check git version, hook wiring, install state |
| `moire report` | Rates over distinct pair-states, distinct findings, contested paths |
| `moire init-swarm` | Create N worktrees, install, place the skills, run doctor |
| `moire wire-client` | Merge the hook into a client's settings (diff, then `--apply`) |

`check`, `verify` and `replay` **never exit nonzero because of a finding** — they warn; they never fail your build. The one exception is a refusal: they exit 2 on an unusable environment or a bad argument, before writing any log. An unknown flag, or a value flag with nothing after it, is a bad argument — `check --block` and a trailing `--checker` both refuse rather than being silently ignored.

## How it works

For each peer worktree:

1. **Snapshot both sides** — committed, staged, unstaged and untracked changes — by working through a *copy* of the worktree's index. The observed worktree is never modified, and a peer that's mid-`git add` doesn't block observation.
2. **Ask git** — `git merge-tree --write-tree`. Exit code gives the verdict; conflicting paths come out on stdout.
3. **For `verify`** — that command prints the merged tree's ID *even when the merge is clean*. That tree is a merge that has never been attempted and may never be. Materialise it, run a checker over self / peer / merged, and report only breakage the **combination** creates:

   ```
   new_breakage = broken(merged) − broken(self) − broken(peer)
   ```

   Breakage already present in someone's branch should be their own problem, not a
   collision. That subtraction only cancels when a finding's *text* is identical
   across the three trees, which two ordinary agent actions used to break: a peer
   `git mv` relocated your pre-existing findings to a new path, and a peer's new
   dependency was missing from the merged tree. Both were reproduced, and both are
   now controlled — findings are rewritten through a rename map
   (`git diff --name-status -M50%`) before the subtraction, and a linked directory
   that differs between the two worktrees is built as a per-entry union rather than
   borrowed whole from your side. The residual limits are in the `--checker`
   contract below; they are real and they are stated.

The default checker is a small Python import resolver with no dependencies: it proves an import still resolves — both the module and the name it takes from it — not that its contract held. A function whose exported name is unchanged while its return type widens from `string` to `string | null` is invisible to it, and so is an argument added to a signature. For a statically-typed language, point `--checker` at a real type checker.

It records an import of a module that is not in the tree as a finding, `os` and `numpy` included, and lets the subtraction throw those away: they are unresolvable in all three trees and cancel, while a module one agent deleted or `git mv`d is unresolvable only in the merge. Withholding those at detection time instead — which is what it used to do — made it blind to the case this tool exists for, one agent moving the door while the other builds a path to where it was. The consequence is that the per-tree counts on the clean line are large and mostly stdlib; they are an intermediate quantity, and only the difference between them is a judgement. `tests/benchmark_recall.sh` measures what that buys: **9 of 11** textually clean collisions whose breakage CPython confirms on the merged tree, against **4 of 11** before, with **0 of 7** clean merges reported as broken. The two it still misses are a changed signature and an attribute removed from a module that still resolves — neither is a name that stopped resolving, and both are out of reach of an import resolver by construction rather than by quality. [What that score does and does not mean](#what-9-of-11-measures) is worth reading before quoting it.

It **reads Python only**, and it says so rather than implying otherwise. When the merged tree contains no `.py` files there is nothing it can examine, so `verify` reports that instead of claiming the merge is fine:

```
$ moire verify
clean   with /repo-agent-b (textual only - no semantic check was performed)
  builtin-ast examined 0 of 847 files: it reads only Python and this tree has no .py files.
  The merged result was NOT semantically verified - "clean" above means only that git found no textual conflict.
  To enable semantic verification for this repo: git config moire.checker '<command>'   (README: the --checker contract)
```

Such a record is excluded from `moire report`'s semantic rate and counted under `unperformed_semantic_checks` instead — a check that measured nothing must not be averaged in as a clean one. On the happy path the same honesty appears as scope: `(semantic ok: no new breakage; findings self=37 peer=39 merged=39; builtin-ast examined 12 of 40 files - python only)`. Those per-tree counts are *findings*, not breakage the merge caused — most of them are the repository's ordinary stdlib and third-party imports, which the builtin checker cannot resolve inside a materialised tree and which cancel in the subtraction. Only their difference is a judgement.

### Pointing `verify` at your language, per repo

Set the checker once per clone and every agent only ever types `moire verify`:

```bash
git config moire.checker './node_modules/.bin/tsc --noEmit | sed -E "s/\([0-9]+,[0-9]+\)//"'
git config --add moire.link node_modules
moire doctor      # warns when `verify` would have nothing to read
```

This is `git config`, not a file committed to the repository, and the difference is the point: `.git/config` is never cloned, so a checkout cannot carry a command that runs on someone else's machine. Setting it requires local write access to the clone — the same trust level as installing moire's hooks, and the same stance as the `core.hooksPath` warning in `moire doctor`.

It lives in `$GIT_COMMON_DIR`, so one setting covers every worktree of the swarm. `--checker` and `--link` still work and take precedence: `--checker` flag > `moire.checker` > `builtin-ast`, and links are the union of both sources. An invalid `moire.link` name is refused with exit 2 before any log is written, exactly like an invalid `--link`.

Because that set difference is computed over the checker's output *lines*, a checker has to be deterministic and emit one finding per line with repo-relative paths. Break those rules and you get false breakage rather than silence, so read the contract before pointing `--checker` or `moire.checker` at something.

<details>
<summary><strong>The <code>--checker</code> contract</strong> — read this before writing or choosing one</summary>

- **One finding per line, deterministic.** Identical input must give identical output. No timestamps, durations, run counts or summary lines: anything that varies between runs never cancels in the set difference and surfaces as false breakage. This is why a bare `pytest -x` or `mypy .` is unsound — both print a summary line that differs run to run.
- **Repo-relative paths.** The three trees are materialised into three different temporary directories, so an absolute path never cancels and always reports false breakage.
- **Strip line and column numbers.** A finding string embedding a position changes whenever an unrelated edit shifts lines — it fails to cancel, and it churns the `finding_id` that recurrence tracking keys on. `tsc` emits `src/x.ts(4,1): error TS2551: …`, so it needs `| sed -E "s/\([0-9]+,[0-9]+\)//"`.
- **Path-prefixed findings survive renames; others do not.** Rename canonicalisation rewrites a finding's *leading path* into the merged tree's namespace before the subtraction, so `src/x.ts: error …` cancels across a peer's `git mv` and a finding that does not begin with a path does not. A path mentioned mid-line is deliberately left alone rather than rewritten by guesswork.
- **Context-invariance, which no checker fully has.** A finding whose text embeds information from elsewhere in the tree changes when that elsewhere changes: rename a type and every pre-existing `tsc` diagnostic mentioning it gets new text and fails to cancel. This is a known limit of the subtraction, not a bug to report.
- **Emit everything, every time.** A checker that stops early (`-x`, `--max-errors`, fail-fast) emits a *prefix* of its findings, and prefixes of different sets do not cancel.
- **It runs on tracked files only.** The materialised tree is `git archive` output — no gitignored `node_modules`, `.venv` or `vendor`. `--link <name>` symlinks a named directory from the worktree into each tree instead; `<name>` must be a single path component. The link is live, not read-only, so only link a directory you're content to have your checker write into — `tsc --incremental`, `eslint --cache` and anything using `node_modules/.cache` write through it into the real worktree.
- **Invoke tool binaries directly**, never through `npm run` / `pnpm exec` / `yarn run`. The materialised tree is not a project directory, and package-manager wrappers do their own project discovery and dependency repair as a side effect of running your command — under a hook there's no TTY for that to fail safely against.
- **Non-source import targets are unresolved, not broken.** If you're writing a checker: a relative import resolving to a `.json`, `.css` or `.svg` has no export syntax to find. Treat it like an unresolvable path — an alias, a bundler-only import — not a missing export. This was the most common false positive when a reference TS/JS resolver was written against moire.

The worked example above — `tsc --noEmit` piped through `sed` to strip positions, with `node_modules` linked — satisfies the mechanical rules. The same thing as a one-off flag, without configuring the repo:

```bash
moire verify --checker './node_modules/.bin/tsc --noEmit | sed -E "s/\([0-9]+,[0-9]+\)//"' --link node_modules
```

</details>

## Cost

Re-measured 2026-08-12, because the figure this section used to carry was measured on
*this* repository — which tracks no `.py` files, so the builtin checker examined
nothing and the headline cost of the semantic step was the cost of it doing no work.

**Method.** A purpose-built lab repository: 62 tracked `.py` files in a chain of
imports, three peer worktrees, each peer holding one committed and one uncommitted
edit. Median of 15 runs per cell, wall clock of the whole process. *Warm* means the
peer-snapshot cache hits (`MOIRE_CACHE_TTL=3600`); *cold* means it never does
(`MOIRE_CACHE_TTL=0`), so all three peers are re-snapshotted every run. `verify` used
the default `builtin-ast`, which reported `examined 62 of 63 files - python only` on
every run.

| against 3 peers | warm | cold |
| --- | --- | --- |
| `moire check` | 219 ms | 404 ms |
| `moire verify` (builtin-ast, 62 files) | 454 ms | 635 ms |

**These are ceilings, not figures.** The machine — an Apple M1 MacBook Pro
(`MacBookPro17,1`), macOS 15.7.3, Python 3.8.2, git 2.55.0 — carried load averages
between 10.19 and 11.44 across the run, on 8 cores. An idle machine will be faster;
nothing here will be slower. For scale on the same machine and the same loading,
`python3 -c pass` took 21 ms.

`verify --json` reports its own elapsed time, so measure your own cost rather than
trusting this one — and do, because point `--checker` at anything real and the figure
above stops applying entirely: cost becomes `snapshot overhead + K × checker runtime`,
where `K = 2 × peers + 1` (self once per run, peer and merged once per peer). With a
checker in the seconds range that puts `verify` past what belongs on a per-write hook.
Run `check` on every write and `verify` before declaring a task done, which is what
`skills/moire-parallel/SKILL.md` instructs.

Snapshots are content-addressed, so re-checking an unchanged worktree writes no
objects at all: in the same lab, 20 consecutive checks against 3 peers with the cache
disabled added **zero** loose objects. Observing a genuinely *new* state does write
objects — that is intrinsic, not overhead — and those are refless and swept by git's
own housekeeping,
which normal commit and fetch activity already triggers. moire never deletes an
object; `moire doctor` warns if loose objects ever accumulate past git's own `gc.auto`
threshold.

## What observation writes, and where

"The peer needs zero participation" has a cost, and it is the peer's: **a peer cannot
opt out of being observed.** Snapshotting runs `git add -A` through a *copy* of the
peer's index, so every file in the peer's worktree that is **untracked and not
gitignored** is written as a blob into the repository's shared object store. That is
load-bearing — the canonical example is a peer's brand-new, not-yet-committed file,
and it is invisible without this — but you should know it happens.

Verified here 2026-08-12, on a lab repo with three peer worktrees: a peer's untracked
`.env.local` was found as a blob in the shared object store after one `moire check`,
and a file under a gitignored directory was not.

Three properties bound it:

- **No new read access.** The object store is shared by every worktree of the repo.
  Anyone who can read it could already read the peer's worktree directly.
- **Gitignored files are never captured.** `git add -A` respects `.gitignore`, so the
  ordinary hygiene of gitignoring `.env*`, credentials and key material is also the
  fix here. Do it anyway; do it first.
- **The exposure is persistence, not access.** The blob is refless — unreachable from
  any ref — so nothing shows it in a log or a diff, and it survives until git's
  housekeeping prunes it, which for loose objects is git's own cruft window (two
  weeks by default). `git gc --prune=now` removes it immediately; verified here, the
  blob was gone straight after.

## Why not do it another way?

Several other approaches exist. Their measured outcomes are more instructive than the
designs, and they are why moire is shaped the way it is.

| Approach | Example | What happened |
| --- | --- | --- |
| **Agents declare what they will touch**; a registry arbitrates | MCP Agent Mail, Agent Claim MCP, [wit](https://github.com/amaar-mc/wit), [grit](https://github.com/rtk-ai/grit) | Advisory by their own documentation — nothing enforces a claim — or enforced by a lock registry every agent must join. All fail open the moment one agent, say another vendor's, doesn't participate. |
| **Let the agents talk to each other** | Claude Code cross-session messaging | Shipped by the vendor, and explicitly transport: *"a message is a piece of text one Claude writes to another, never conversation history or files."* It fires only if an agent notices the collision, decides to send, and picks the right session. |
| **Detect overlap at pull-request time** | [ConE](https://arxiv.org/abs/2101.06542) (Microsoft Research + TU Delft) | Works, at scale — flagged 775 of 26,000 pull requests (3.33%) across 234 repositories; 554 of those 775 notifications (71.48%) were flagged "Resolved" *by users*, which is a user rating and not precision against ground truth. Detects *file* overlap, after both branches already exist, and ships as a comment. |
| **Warn human developers proactively** | Crystal ([Brun et al., ESEC/FSE 2011](https://cs.uwaterloo.ca/~rtholmes/papers/fse_2011_brun.pdf)) | moire's direct ancestor: it merged peers' committed code, built it, ran its tests, and showed a per-peer icon. Nine systems, 3.4M LOC, 550,000 development versions. Fifteen years later, no published evidence of durable industrial adoption for it or any of its successors. |
| **Isolate, merge later** | every commercial agent orchestrator | Works, and defers the problem to a human at merge time. This is what everyone actually ships. |
| **Merge queues** | Mergify, GitHub merge queue | Real semantic detection: full CI on speculatively merged combinations, ejecting the culprit. It runs on completed, pushed PRs — the same idea as `verify`, at the opposite end of the lifecycle. |
| **Partition the work before dispatch** | [Co-Coder](https://arxiv.org/abs/2606.00953) | The strongest result in the table. Across 28 tasks on DevEval and CodeProjectEval, cohesion-aware partitioning beat the sequential baseline (68.1% vs 56.8% pass on DevEval), while *naïve* file-based parallelism cost 60% more for a 3.2% pass-rate gain because concurrently generated files violated cross-file type contracts. Greenfield generation, not repository modification. |

### Why this is different

The first two rows share a shape: they ask an agent to describe or announce its own
work. moire never asks — it reads the other worktree's files, so there is no
declaration to be wrong.

Three consequences follow structurally, not by effort:

1. **Nothing to tune.** `check` runs git's own merge engine, so the answer *is* the
   answer the real merge will give. No threshold, no model, no precision that degrades
   on a repository it was not calibrated against.
2. **It sees what nothing surveyed does.** Git catches overlapping lines at merge time.
   ConE catches overlapping files at PR time. Clash catches conflicts between two
   agents' last commits. None of them sees a merge that is textually clean and
   semantically broken — the case in the example above. `verify` does, because it
   runs a real checker against the merged tree that `merge-tree` produces even when
   the merge succeeds. The nearest thing this project's own survey of the category
   found is weave's `weave_validate_merge`, which is static reference analysis rather
   than a checker run on a tree. "Nothing surveyed does this" is a statement about a
   survey, so read it as one: it is a claim that can be falsified by one
   counter-example, and a counter-example would be welcome.
3. **One-sided by construction.** Every declaring scheme here needs both parties to
   participate. This one protects whoever runs it, against agents that are not
   cooperating and may be from another vendor — though note that the measured
   cross-vendor case is thin: only 0.5% of co-active agent PR pairs were cross-agent,
   in 122 of 2,807 repositories (~4.3%), per Xu et al.

And it is aimed at the case partitioning cannot reach: cohesion-aware partitioning
wins where a repository decomposes cleanly, and falls back to sequential where it does
not. Tightly-coupled work is exactly where concurrent agents still collide — which
also means moire's addressable surface is the residue a good dispatcher leaves, not
"everyone running parallel agents".

### What this project tried and threw away

Three mechanisms were designed here and then abandoned on evidence:

- **A declared-intent ledger with a model classifying whether two intents were
  compatible** — dropped once the measurements on declared-intent coordination landed.
- **A line-range overlap predicate.** 24.1% recall as first specified. Corrected to
  100% recall, but precision swung from **88.4%** on one repository to **36.6%** on
  another, because it only *approximates* git's merge condition. Replaced by asking
  git directly.
- **A symbol-matching heuristic** to catch the semantic case from diffs alone. Tested
  against a corpus of real clean merges *before* implementation: 24 fires, **0 true
  positives** — every one a regex artifact, including English prose in a docstring
  matching a definition pattern. Killed before a line was written.

**A retraction about that last one.** This README used to give its denominator as
"2,347 concurrent pairs" across flask, click, rich, requests, pytest and httpx. That
number is withdrawn. The only corpus table this project ever recorded puts those six
repositories at **2,017** concurrent pairs in total — 315 click, 273 flask, 787 rich,
355 pytest, 272 requests, 15 httpx — and clean merges are a strict subset of
concurrent pairs, so 2,347 exceeds its own population by 330. No recorded run
reproduces it. The denominator could not be reconciled and is therefore
unpublishable, and it is withdrawn rather than adjusted to a number that would look
tidier.

**The finding survives the denominator.** 24 fires and 0 true positives is a count of
the numerator, and it is unaffected. The same table corroborates the direction
independently: pytest (355 concurrent pairs), requests (272) and httpx (15) produced
**zero** file conflicts between them, and four of the seven repositories sampled
produced no concurrent conflicts at all. Conflict frequency is a property of a
repository, not a constant.

The tool is what survived all of that.

## Status — read this before adopting

**`moire check`: done.** Correct, tested against real `git merge` outcomes, and not
novel (see [Compared with Clash](#compared-with-clash)). Everything it finds, git
finds later, for free; its whole value is that it finds it earlier, and on live
uncommitted trees.

**`moire verify`: mechanism fixed, rate unmeasured, decision rule pre-registered.**
That is its complete status and none of the three parts should be read without the
other two.

- *Mechanism fixed* — the failure is real and easy to reproduce (case 2 of
  `tests/test_verify.sh` is exactly it), and the two false-BROKEN classes that used to
  fire on ordinary agent behaviour — a peer `git mv`, a peer installing a dependency —
  were reproduced and fixed, each with a regression test. The rename one computes its
  ground truth from git rather than from moire.
- *Rate unmeasured* — **what is unknown is the frequency, not the existence.** Nobody
  has published how often two concurrent agents produce a clean merge that doesn't
  work. The two papers that measured agent merge conflicts both name that layer as
  their own limitation: *"no tracking is done for deeper build or semantic
  conflicts"* (Xu et al.), *"it does not account for higher-level forms of conflict
  such as logical inconsistencies or post-merge defects"* (AgenticFlict).
- *Decision rule pre-registered* — [`PHASE1-PREREGISTRATION.md`](PHASE1-PREREGISTRATION.md)
  fixes the rule before the data: replay ≥500 textually clean co-active agent PR
  pairs, audit every reported breakage, and retire `verify` as a live feature below a
  0.5% audited true-collision rate. `moire replay` is the instrument and
  [`tools/replay-corpus/`](tools/replay-corpus/) is the harness.

**No Phase 1 result exists.** A feasibility pilot on 2026-08-12 constructed 24 pairs
and evaluated **20** of them, against a pre-registered minimum of 500. No pair
reported breakage, which at n=20 means nothing in either direction. That pilot is
written up in [`tools/replay-corpus/README.md`](tools/replay-corpus/README.md) with its
attrition ladder; it establishes that the harness runs, and nothing else. The harness
refuses to print a semantic rate until the 500-pair minimum, the calibration check and
the audit have all been affirmed.

An earlier search of *human* open-source history turned up little, but that says less
than it sounds like: it covered one failure mode (cross-module references, not changed
signatures or arity mismatches) on the wrong population. Human teams also coordinate
socially — issue claiming, standups, "I'm taking that module" — which agents
dispatched in parallel do not.

So this is a working instrument aimed at an open quantity, not a proven product.

## What changed in 0.12

- **The builtin checker sees a module vanish, not only a name.** It used to skip any
  import whose module was absent from the materialised tree, which is right for `os`
  and `numpy` and catastrophic for a module the other agent just deleted or moved: the
  headline failure this tool is about reported `semantic ok`. Absent modules are now
  findings, and the existing `broken(merged) − broken(self) − broken(peer)` subtraction
  removes the ambient ones — recall on the new
  [recall benchmark](#tests) goes from 4 of 11 to 9 of 11 with no new false positive
  there or on the pilot corpus pairs. Per-tree finding counts rise by one to two orders
  of magnitude as a result; the difference between them, which is the judgement, does
  not.
- **`moire report` rates situations, not observations.** Its denominators are now
  distinct *pair-states* — distinct observed `(self_tree, peer_tree)` content pairs —
  and distinct findings, with raw observation counts kept alongside for transparency.
  Previously one collision seen four times read as four broken pairs at a 100% rate.
  A pair-state is **not** a task, a merge, or a day; it is a distinct observed content
  state of a worktree pair. Records written by older versions are counted and excluded
  as `pre-v2 records ignored` rather than silently mixed in.
- **`moire replay <a> <b>` is new** — the same mechanism on two commits instead of two
  live worktrees, stateless and usable in a bare clone. It is what makes the Phase 1
  measurement possible without adopters.
- **`moire explain` and the notes machinery are gone**, along with `report --study` and
  the `MOIRE_SURFACE_*` environment variables. `report --study` now refuses by name.
  The notes channel was a declared, agent-authored input inside a tool whose whole
  premise is observation, and the A/B machinery could not have produced an
  interpretable result. Agent-to-agent commentary belongs on the platform's own
  cross-session messaging; moire computes findings.
- **Unknown and valueless flags refuse with exit 2** before any snapshot or log write.
  `check --block` used to succeed silently; a trailing `--checker` used to fall back to
  the builtin.
- **A finding computed from a cached peer snapshot is recomputed** against the peer's
  state right now before it is emitted, so a peer that has already withdrawn its edit
  no longer produces a warning for the length of the cache TTL.
- **`git config moire.checker` and `moire.link`** set the checker and linked
  directories once per clone, so every agent only types `moire verify`.
- **[What observation writes, and where](#what-observation-writes-and-where)** is newly
  documented. It was always the behaviour; it was never written down.

## Tests

```bash
bash tests/test_oracle.sh    # 12 cases: conflict detection vs real `git merge`
bash tests/test_install.sh   # 21 cases: install, hooks, path resolution, concurrency, object-store growth
bash tests/test_report.sh    #  7 cases: finding identity, pair-state metrics, replay statelessness
bash tests/test_setup.sh     # 14 cases: init-swarm, wire-client, settings-file handling
bash tests/test_verify.sh    # 44 cases: the semantic path — new_breakage, renames, --link union, replay
bash tests/negative_control.sh   # proves the five suites above can fail
bash tests/benchmark_recall.sh   # 18 collision fixtures graded by CPython, not by moire
```

**98 cases; measured 2026-08-12: 97 passed, 1 skipped, 0 failed.** The skip is a
`DeprecationWarning` check that only applies on Python 3.12+ and this machine runs
3.8.2.

`tests/negative_control.sh` is the answer to "a test suite that cannot fail is worse
than none". It points `MOIRE_BIN` at a `#!/bin/sh; exit 0` stub and then at a path that
does not exist, and asserts that **every** suite exits nonzero in both scenarios.
Measured 2026-08-12: 10 of 10 checks went red as required, 0 wrongly stayed green.

⚠️ **`tests/test_setup.sh` is not contained.** Its `init-swarm` cases run with your real
`$HOME`, and `init-swarm` places skills at `--skills user` by default, so running that
suite copies this repository's `skills/` into `~/.claude/skills/` and
`~/.agents/skills/`, moving anything already there to `*.moire-backup`. It is a
test-suite defect, not a tool one, and it is written here rather than left for you to
discover. Run that suite with `HOME=$(mktemp -d)` if you would rather it did not.

`test_oracle.sh` is the suite with the strongest ground truth: it performs a real `git
merge` in a throwaway copy and compares moire's verdict against what git actually did.
`test_verify.sh` case 31 — the rename regression — is the one semantic case that
computes its ground truth without moire: it runs `git merge-tree --write-tree`, unpacks
the result with `git archive`, and asserts the broken import *is* present at the renamed
path, so that silence counts as correct only if the tool saw the breakage and attributed
it to the right side. The other semantic cases assert against moire's own JSON, which is
weaker, and is stated here rather than glossed.

`tests/benchmark_recall.sh` is the answer to that weakness, and it asks a different
question from the suites: not whether the mechanism behaves as specified, but how much
of a real collision it sees. Eighteen textually clean fixtures — a deleted module, a
`git mv`, a package rename, a removed name, a broken `__init__.py` re-export, a dotted
submodule import, a changed signature, an attribute removed from a surviving module, a
name one side supplies for the other, a namespace package, and the third-party imports
that must never fire — are graded
by materialising the same three trees and **importing every module in each with
CPython**, then subtracting the interpreter's errors exactly as moire subtracts its
own. Nothing in it consults moire's verdict. Measured 2026-08-13: **9 of 11** confirmed
collisions caught and **0 of 7** clean merges reported, against **4 of 11** and 0 of 7
for the previous checker (`git show febc36b:bin/moire`).

### What 9 of 11 measures

**It is a robustness score inside one category, not a recall measurement over the
domain, and it should not be quoted as the second thing.**

The literature that classifies *causes* of build-layer breakage names nine of them.
An import-name resolver can reach exactly one — **Unavailable Symbol**, a reference to
a declaration the other side deleted or renamed. The other eight (duplicated
declaration, incompatible types, unimplemented interface method, changed signature,
dependency-version skew, dependency-code mismatch, project rules) are out of reach of
*any* implementation of this mechanism, not of this one. Add the behavioural layer —
interference between branches that both compile — and it is one of twelve.

So the eleven positives are **nine structural variants of a single category** plus two
declared out-of-reach misses. The variants are where a naive resolver actually breaks —
`git mv`, package rename, relative imports, re-export chains — so catching them is real
signal about the implementation. It is not evidence about coverage of the problem.

The mitigating half, which is equally measured: that one category is the **single
largest cause** of build conflict in both corpora that count causes. da Silva, Borba &
Pires ([*JSEP* 34(4):e2441, 2022](https://doi.org/10.1002/smr.2441)) found Unavailable
Symbol to be **65.7%** of 239 conflict instances across 57,065 merge scenarios; Shen,
Gulzar, He & Meng ([*TOSEM* 32(2):40, 2023](https://doi.org/10.1145/3546944)) found
**99 of 107** inspected build conflicts reduce to edits that break def-use links — a
name that stopped resolving. The checker targets the right category; it simply cannot
claim the domain.

The full map, with each source's verification status, is in
`research/semantic-conflict-taxonomy.md`.

## Repository layout

```
bin/moire            the tool — a single file, Python 3.8, standard library only
bin/moire.js         Node launcher, retained for a distribution that does not exist yet
skills/              two Agent Skills: one for acting on a finding, one for
                     setting up parallel work
tests/               98 cases across five suites, plus the negative control and
                     the recall benchmark
tools/replay-corpus/ the Phase 1 measurement harness (stdlib only, not shipped)
PHASE1-PREREGISTRATION.md   the decision rule, committed before any data
package.json         npm packaging metadata; nothing is published
README.md            this file
LICENSE              MIT
```

There is no build step, no configuration file and no runtime dependency beyond git.

## A note on the numbers

**Not every figure here is measured on this machine — the external citations never
could be.** The previous version of this section claimed otherwise, which was the
single least defensible sentence in the document. Each figure is one of three things,
and which one is always stated:

**1. Measured here, 2026-08-12, on an Apple M1 MacBook Pro** (`MacBookPro17,1`,
macOS 15.7.3, Python 3.8.2, git 2.55.0): the [cost table](#cost) and its 21 ms
process floor; the 62-of-63-files checker coverage; the zero loose objects over 20
idle checks; the 98 test cases and their 97/1/0 outcome; the negative control's 10 of
10; the object-store observations in [what
observation writes](#what-observation-writes-and-where); both Clash reproductions. The
recall benchmark's 9-of-11 and 4-of-11 scores with 0 of 7 false positives were measured
on the same machine **2026-08-13**, after three fixtures were added for shapes the
suite had never exercised. The
cost table was taken under load averages of 10.19–11.44 on 8 cores and is published as
a **ceiling**, not a figure.

**2. Measured by this project earlier, on other machines, and labelled as such.** The
abandoned predicates' numbers (24.1% recall; 100% recall at 88.4%/36.6% precision; 24
fires and 0 true positives) and the per-repository pair counts come from this
project's own working notes, which are **not published in this repository** — so treat
them as this project's word, not as something you can check here. Where one of them
could not be reconciled it has been withdrawn rather than kept (above). The **git ≥
2.38** floor comes from this project's direct testing: the older three-argument `git
merge-tree` reports *clean* for rename/rename, modify/delete and binary-vs-binary
conflicts that a real merge rejects. A detector with silent blind spots is worse than
no detector, so `moire` refuses to run below that version rather than degrade.

**3. Cited to a primary source, with its scope attached.** Every external number below
was taken from the paper or report itself, and its denominator travels with it:

| Figure | What it actually measures | Source |
| --- | --- | --- |
| **19.8% / 41.7%** | textual conflict when three-way merges were replayed over 747 co-active agent PR pairs — intra-agent vs cross-agent, non-overlapping 95% CIs. Cross-agent stratum is 115 pairs | Xu, Subramanian & Karthik, [arXiv:2607.04697](https://arxiv.org/abs/2607.04697) |
| **40.2% / 79.4% / 0.5%** | share of repositories with co-active agent PR pairs; share of agent PRs those pairs account for; share of co-active pairs that are cross-agent, in 122 of 2,807 repos | same |
| **27.67%** | textual conflict rate for 107K+ agent PRs simulated **against their base branch** — agent-vs-mainline drift, not agent-vs-agent | Ogenrwot & Businge, [arXiv:2604.03551](https://arxiv.org/abs/2604.03551) |
| **3% / 5.4%** | of 6,045 real Java merges from 1,120 repositories **where both parents passed their tests**, git produced a clean merge that failed compilation or tests in 157 cases — 3% of all merges, 5.4% of textually clean ones. Human merges, not agent merges | Schesch, Featherman, Yang, Roberts & Ernst, ASE 2024, [arXiv:2410.09934](https://arxiv.org/pdf/2410.09934) |
| **51% vs 3%** | in that same corpus git reported a textual conflict on 51% of merges and a silently-broken clean merge on 3%: textual conflicts were roughly 17× more frequent. `verify`'s event is the rarer, costlier one | same, Fig. 5 |
| **9.3%** | recomputed from Brun et al.'s Figure 4: 133 of 1,428 textually clean merges failed to build or failed tests. Arithmetic below | Brun, Holmes, Ernst & Notkin, ESEC/FSE 2011 |
| **65.7%** | share of 239 build-conflict *instances* that are Unavailable Symbol — the one category this checker can reach. Those instances came from 65 scenarios (0.11%) out of 57,065 merge scenarios in 451 Java projects, so the 65.7% is a share of causes, **not** a rate of occurrence | da Silva, Borba & Pires, *JSEP* 34(4):e2441, 2022, [DOI 10.1002/smr.2441](https://doi.org/10.1002/smr.2441) |
| **99 of 107** | inspected build conflicts that reduce to co-applied edits breaking def-use links — a name that stopped resolving. 208 Java repos; 79 scenarios hit build conflicts against 15,886 that hit textual ones | Shen, Gulzar, He & Meng, *TOSEM* 32(2):40, 2023, [DOI 10.1145/3546944](https://doi.org/10.1145/3546944) |
| **20% / 93%** | 20% of previously-safe relationships devolved into a conflict, and 93% of all conflicts developed *from* a previously-safe state — the published argument for continuous rather than one-shot checking | same, §4.4 |
| **2.1–14.7% / 5.6–35%** | of clean merges across four projects, the build-failure range; of correct builds, the test-failure range. Do not collapse to a midpoint; neither paper isolates merge-*caused* from ambient failures | Kasi & Sarma, ICSE 2013 |
| **3.33% / 71.48%** | ConE flagged 775 of 26,000 pull requests across 234 repositories; 554 of those 775 notifications were rated "Resolved" **by users** — not precision against ground truth | Maddila, Nagappan, Bird, Gousios & van Deursen, ACM TOSEM 31(2), 2022 |
| **60% cost / 3.2% pass** | naïve file-based parallelism cost 60% more for a 3.2% pass-rate gain across 28 tasks, because concurrently generated files violated cross-file type contracts. Greenfield generation, not repository modification | Co-Coder, [arXiv:2606.00953](https://arxiv.org/abs/2606.00953) |
| **1.9% vs 4.4%** | AI-assisted PRs broke main less often than PRs with no detectable AI assistance, across 200,000+ merges from 477 teams. See the risk it poses, below | Mergify, *State of Merge Queues 2026* |

**The 9.3% arithmetic, shown.** Brun et al.'s Figure 4, re-read from the PDF for this
README, gives per system: Git 1,362 merges = 227 textual-fail + 2 build-fail + 53
test-fail + 1,080 clean-and-passing; Perl5 185 = 14 + 7 + 51 + 113; Voldemort 147 = 25
+ 15 + 5 + 102. Every row sums to its own merge count. Totals: 1,694 merges, 266
textual, 24 build, 109 test. Textually clean = 1,694 − 266 = **1,428**; broken among
them = 24 + 109 = **133**; 133 / 1,428 = **9.3%**. ⚠️ The widely-quoted *"33% of clean
merges"* is a misreading of a sentence the paper itself got wrong: 399 is the count of
*conflicting* merges (266 + 24 + 109), so 133/399 = 33% is higher-order conflicts as a
share of **all conflicts**, not of clean merges. Do not cite 33%. Note also that this
covers only 3 of the paper's 9 systems — the six others had no test suite the authors
could run — and that the paper's own prose says "5,355 merges" where Figure 4 sums to
1,694, unreconciled; cite the table.

### Two corrections to this project's public record

**A retraction of a retraction.** This project previously published the figures
**41.7%** and **19.8%** for cross-agent versus intra-agent conflict, then retracted
them as fabricated after confirming they appear nowhere in
[arXiv:2604.03551](https://arxiv.org/abs/2604.03551). The confirmation was correct.
**The conclusion was wrong.** The figures are real; they belong to a *different*
paper. Xu, Subramanian & Karthik,
[arXiv:2607.04697](https://arxiv.org/abs/2607.04697), state in their abstract, and
this was re-checked against arXiv directly for this README: *"the percentage of
textual conflict encountered was significantly higher for cross-agent pairs compared
to intra-agent pairs: 41.7% vs. 19.8%, respectively, with non-overlapping 95%
confidence intervals"* — from replaying three-way merges over 747 co-active pairs.
arXiv:2604.03551 is a different dataset entirely (AgenticFlict, Ogenrwot & Businge:
27.67% across 107K+ merge-simulated agent PRs, PR-vs-base). What went wrong was
**misattribution, not fabrication** — the right numbers filed under the wrong paper —
and the correction runs in this project's favour, which is exactly why it is stated
plainly rather than quietly fixed.

**A retraction that stands.** "2,347 concurrent pairs" is withdrawn and not restored;
see [what this project tried and threw away](#what-this-project-tried-and-threw-away).
Also removed from this README, without replacement: contributor and download counts
for MCP Agent Mail that appear in no research note here; a Claim Plane restatement
that dropped caveats the project's own notes say must not be dropped; and a CooperBench
token-budget figure that came from the same paragraph of the same document as four
statistics this project had already proven to be fabrications.

### The strongest argument against this project

State it rather than omit it. Mergify's *State of Merge Queues 2026* reports that
across 200,000+ merges from 477 teams, **AI-assisted PRs broke main 1.9% of the time
against 4.4% for PRs with no detectable AI assistance.** If AI-authored changes are
*safer* at integration than human ones, the premise that agents specifically need new
integration safety is weakened. Three caveats partly defuse it and none of them
dissolves it: AI assistance is detected from commit signatures, which the report itself
calls a floor; "AI-assisted" means human-supervised PRs, not autonomous parallel
agents; and it is a vendor report on its own customers, a population that already runs
a merge queue. The same report finds broken-main scaling with concurrency, from about
0.77% at 2–5 engineers to 12.5% at 40+ — which cuts the other way.

These are one person's measurements plus other people's published work. They are
stated precisely so that they can be contradicted.

## License

MIT — see [LICENSE](LICENSE).
