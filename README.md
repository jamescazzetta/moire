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
- `moire verify` catches the disjoint case, which nothing else does.

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

That second one is the case git merges cleanly. It took 38 ms to find.

```bash
git clone https://github.com/jamescazzetta/moire.git
moire init-swarm --agents 3                     # worktrees, hooks, skills, verify
moire wire-client claude --scope user --apply   # shows a diff first
```

Needs **git ≥ 2.38** and **Python 3.8+**. No daemon, no server, no config file — per-repo
settings live in `git config`, which never travels with a clone — no account, and nothing
written into your working tree. Uninstalling is deleting a directory.

## Where it fits

Everything below already runs somewhere in your pipeline. The gap is the last two rows.

| | sees | catches |
| --- | --- | --- |
| `git merge` | overlapping lines | conflicts — at merge time |
| code review | two separate diffs | nothing; each diff looks correct |
| CI | the merged result | everything — after both have landed |
| **`moire check`** | **both live worktrees** | **conflicts, while both are still writing** |
| **`moire verify`** | **the merge that would result, right now** | **breakage that merges cleanly** |

## Three things that make it unusual

- **It asks nobody anything.** It reads the other agent's files. The other agent needs
  no setup, no awareness of the tool, and may be from a different vendor.
- **It is exact, not a guess.** No heuristics, thresholds, model or tuning — `check`
  runs git's own merge engine, `verify` runs a real checker on a real tree.
- **It never blocks.** Warn-only by design, with no block mode and no flag to add one.

Each of those is a reaction to something that has already been tried and measured.

## Install

The three lines above are the whole thing; this section is the detail behind them.

**Requires git ≥ 2.38.** Older git silently misses whole classes of conflict
(rename/rename, modify/delete, binary), so `moire` refuses to run rather than give you
a detector with blind spots. Stock macOS ships 2.30 — `brew install git`.

```bash
# create N worktrees, install the binary and git hooks, place the skill, verify
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
  mode that made ConE, above, a comment nobody measured.
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
| `moire explain <id> <text>` | Attach a one-sentence *why* to a specific finding. Advisory only — it can never change a verdict. |
| `moire install` | Install git hooks and the binary into `.git/` |
| `moire doctor` | Check git version, hook wiring, install state |
| `moire report` | Conflict base rate and most-contested paths |
| `moire report --study` | Per-finding lifecycle and A/B arm comparison |
| `moire init-swarm` | Create N worktrees, install, place the skill, verify |
| `moire wire-client` | Merge the hook into a client's settings (diff, then `--apply`) |

`check` and `verify` **never exit nonzero because of a finding** — they warn; they never fail your build. The one exception is a refusal: they exit 2 on an unusable environment or a bad argument (no usable git, an invalid `--link` name), before writing any log.

## How it works

For each peer worktree:

1. **Snapshot both sides** — committed, staged, unstaged and untracked changes — by working through a *copy* of the worktree's index. The observed worktree is never modified, and a peer that's mid-`git add` doesn't block observation.
2. **Ask git** — `git merge-tree --write-tree`. Exit code gives the verdict; conflicting paths come out on stdout.
3. **For `verify`** — that command prints the merged tree's ID *even when the merge is clean*. That tree is a merge that has never been attempted and may never be. Materialise it, run a checker over self / peer / merged, and report only breakage the **combination** creates:

   ```
   new_breakage = broken(merged) − broken(self) − broken(peer)
   ```

   Breakage already present in someone's branch is their own problem, not a collision.

The default checker is a small Python import resolver with no dependencies: it proves an imported name still resolves, not that its contract held — a function whose exported name is unchanged while its return type widens from `string` to `string | null` is invisible to it. For a statically-typed language, point `--checker` at a real type checker.

It **reads Python only**, and it says so rather than implying otherwise. When the merged tree contains no `.py` files there is nothing it can examine, so `verify` reports that instead of claiming the merge is fine:

```
$ moire verify
clean   with /repo-agent-b (textual only - no semantic check was performed)
  builtin-ast examined 0 of 847 files: it reads only Python and this tree has no .py files.
  The merged result was NOT semantically verified - "clean" above means only that git found no textual conflict.
  To enable semantic verification for this repo: git config moire.checker '<command>'   (README: the --checker contract)
```

Such a record is excluded from `moire report`'s semantic rate and counted under `unperformed_semantic_checks` instead — a check that measured nothing must not be averaged in as a clean one. On the happy path the same honesty appears as scope: `(semantic ok: self=0 peer=0 merged=0 broken; builtin-ast examined 12 of 40 files - python only)`.

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
- **Strip line and column numbers.** A finding string embedding a position changes whenever an unrelated edit shifts lines — it fails to cancel, and it churns the `finding_id` that recurrence tracking and `moire explain` key on. `tsc` emits `src/x.ts(4,1): error TS2551: …`, so it needs `| sed -E "s/\([0-9]+,[0-9]+\)//"`.
- **It runs on tracked files only.** The materialised tree is `git archive` output — no gitignored `node_modules`, `.venv` or `vendor`. `--link <name>` symlinks a named directory from the worktree into each tree instead; `<name>` must be a single path component. The link is live, not read-only, so only link a directory you're content to have your checker write into — `tsc --incremental`, `eslint --cache` and anything using `node_modules/.cache` write through it into the real worktree.
- **Invoke tool binaries directly**, never through `npm run` / `pnpm exec` / `yarn run`. The materialised tree is not a project directory, and package-manager wrappers do their own project discovery and dependency repair as a side effect of running your command — under a hook there's no TTY for that to fail safely against.
- **Non-source import targets are unresolved, not broken.** If you're writing a checker: a relative import resolving to a `.json`, `.css` or `.svg` has no export syntax to find. Treat it like an unresolvable path — an alias, a bundler-only import — not a missing export. This was the most common false positive when a reference TS/JS resolver was written against moire.

The worked example above — `tsc --noEmit` piped through `sed` to strip positions, with `node_modules` linked — satisfies all six. The same thing as a one-off flag, without configuring the repo:

```bash
moire verify --checker './node_modules/.bin/tsc --noEmit | sed -E "s/\([0-9]+,[0-9]+\)//"' --link node_modules
```

</details>

**Cost:** ~187 ms warm, ~335 ms cold, for `check` plus a **builtin**-checker `verify` against 3 peers, measured on this repo. Peer snapshots are cached; your own is always recomputed, because a stale self-snapshot is the one error that would silently produce a wrong answer.

Snapshots are content-addressed, so re-checking an unchanged worktree writes no objects at all: on a 200-file lab repo, 60 idle checks add one object the first time and none on any run after. Observing a genuinely *new* state does write objects — that is intrinsic, not overhead — and those are refless and swept by git's own housekeeping, which normal commit and fetch activity already triggers. moire never deletes an object; `moire doctor` warns if loose objects ever accumulate past git's own `gc.auto` threshold.

Point `--checker` at anything real and that figure stops applying: cost becomes `snapshot overhead + K × checker runtime`, where `K = 2 × peers + 1` — self is checked once per run, peer and merged once per peer. With a checker in the seconds range, that puts `verify` past what belongs on a per-write hook: run `check` on every write, and `verify` before declaring a task done, which is what `skills/moire-parallel/SKILL.md` already instructs. `verify --json` reports its own elapsed time, so you measure your own cost instead of trusting this one.

## Why not do it another way?

Several other approaches exist. Their measured outcomes are more instructive than the
designs, and they are why moire is shaped the way it is.

| Approach | Example | What happened |
| --- | --- | --- |
| **Agents declare what they will touch**; a registry arbitrates | MCP Agent Mail, Agent Claim MCP | Advisory by their own documentation — nothing enforces a claim. The most-starred has 2,069 stars, one contributor, and ~117 downloads a month. |
| **The same idea, enforced at write time** | [Claim Plane](https://arxiv.org/abs/2608.00947) | Measured across 360 runs. Selective admission scored **22.2%** against **23.3%** for no coordination at all — indistinguishable. **51%** of runs failed closed on scope the agent never declared. The conservative variant reached parity only by serialising **96.7%** of the work. |
| **Let the agents talk to each other** | [CooperBench](https://arxiv.org/abs/2601.13295) | A communication channel reduced merge conflicts and **did not raise task success**, while consuming ~20% of the token budget. |
| **Detect overlap at pull-request time** | [ConE](https://arxiv.org/abs/2101.06542) (Microsoft) | Works, at scale — 234 repositories, 26,000 PRs, 71% of notifications rated useful. Detects *file* overlap, after both branches already exist, and ships as a comment. |
| **Warn human developers proactively** | Palantír, Crystal (FSE 2011) | Demonstrated in the lab across 550,000 versions. Fifteen years later, no industrial adoption. |
| **Isolate, merge later** | every commercial agent orchestrator | Works, and defers the problem to a human at merge time. This is what everyone actually ships. |
| **Partition the work before dispatch** | [Co-Coder](https://arxiv.org/abs/2606.00953) | **This one works** — 2.10× wall-clock, −35% cost, +14pp pass rate. It degrades to sequential when the repository is tightly coupled, which is precisely the gap left over. |

### Why this is different

The first three rows share a shape: they ask an agent to describe its own work, before
or while it does it. That assumption is what the measurements destroyed. An agent that
misjudges its blast radius also misdescribes it, and no amount of protocol repairs an
unreliable input.

**moire never asks.** It reads the other worktree's files. There is no declaration to
be wrong, so there is no 51% failure mode to inherit.

Three consequences follow structurally, not by effort:

1. **Nothing to tune.** `check` runs git's own merge engine, so the answer *is* the
   answer the real merge will give. No threshold, no model, no precision that degrades
   on a repository it was not calibrated against.
2. **It sees what nothing else does.** Git catches overlapping lines at merge time.
   ConE catches overlapping files at PR time. Neither sees a merge that is textually
   clean and semantically broken — the case in the example above. `verify` does,
   because it runs a real checker against the merged tree that `merge-tree` produces
   even when the merge succeeds.
3. **One-sided by construction.** Every other scheme here needs both parties to
   participate. This one protects whoever runs it, against agents that are not
   cooperating and may be from another vendor.

And it is aimed at the case partitioning cannot reach: Co-Coder's approach wins where
a repository decomposes cleanly, and falls back to sequential where it does not.
Tightly-coupled work is exactly where concurrent agents still collide.

### What this project tried and threw away

Three mechanisms were designed here and then abandoned on evidence:

- **A declared-intent ledger with a model classifying whether two intents were
  compatible** — dropped once the measurements above landed.
- **A line-range overlap predicate.** 24.1% recall as first specified. Corrected to
  100% recall, but precision swung from **88.4%** on one repository to **36.6%** on
  another, because it only *approximates* git's merge condition. Replaced by asking
  git directly.
- **A symbol-matching heuristic** to catch the semantic case from diffs alone. Tested
  against 2,347 concurrent branch pairs *before* implementation: 24 fires, **0 true
  positives** —
  every one a regex artifact, including English prose in a docstring matching a
  definition pattern. Killed before a line was written.

The tool is what survived that.

## Status — read this before adopting

**The mechanism works and is tested.** 81 tests across five suites, all passing (one skips below Python 3.12), including a negative-control run proving the suite can actually fail.

**What is unknown is the frequency, not the existence.** The failure is real and easy to
reproduce — case 2 of `tests/test_verify.sh` is exactly it: one agent renames a function,
another adds a file calling the old name, git merges clean, `verify` catches it. What nobody has published, as far as I
can find, is how *often* two concurrent agents produce a clean merge that doesn't work.
That number is what decides whether `verify` is worth its cost. It runs before declaring a task done, not on every write — only `check` sits on that hook.

A search of human open-source history turned up little, but that says less than it
sounds like: it covered one failure mode (cross-module references, not changed
signatures or arity mismatches) on the wrong population. Human teams also coordinate
socially — issue claiming, standups, "I'm taking that module" — which agents dispatched
in parallel do not. See [A note on the numbers](#a-note-on-the-numbers).

So this is a working instrument aimed at an open quantity, not a proven product. It is
built to answer its own question: point it at real concurrent agent work for a week and
`moire report --study` gives you a base rate.

The kill criterion, stated before the data arrives: **if the rate on real agent traffic
is too low to justify the cost, `moire verify` should be deleted** — leaving textual
detection, which stands on its own.

## Tests

```bash
bash tests/test_oracle.sh    # 12 cases: conflict detection vs real `git merge`
bash tests/test_install.sh   # 19 cases: install, hooks, path resolution, concurrency, object-store growth
bash tests/test_study.sh     # 12 cases: finding IDs, randomised suppression, agent identity
bash tests/test_setup.sh     # 14 cases: init-swarm, wire-client, HOME containment
bash tests/test_verify.sh    # 24 cases: the semantic path — new_breakage, --link, checker coverage, report fields
```

Every suite verifies against independent ground truth and has been shown to fail when the implementation is stubbed out. A test suite that cannot fail is worse than none.

## Repository layout

```
bin/moire        the tool — a single file, Python 3.8, standard library only
bin/moire.js     Node launcher, used only by the npm distribution
skills/          two Agent Skills: one for acting on a finding, one for
                 setting up parallel work
tests/           81 tests across five suites
package.json     npm packaging
README.md        this file
LICENSE          MIT
```

That is the whole thing. There is no build step, no package to install, no
configuration file and no runtime dependency beyond git.

## A note on the numbers

Every figure in this README is measured on this machine rather than estimated,
and the method is short enough to restate:

- **Conflict rates** come from replaying real merge history. Each merge commit on trunk
  is treated as a branch with a fork point and a merge date; two branches whose windows
  overlap were genuinely concurrent. Across flask, click, rich, requests, pytest and
  httpx that yields 2,347 concurrent pairs which would have merged cleanly. Most of
  those merges never happened — they are synthesised pairwise, not merge commits that
  occurred.
- **The search for semantic breakage covered one failure mode, not all of them.**
  Each merged tree was checked for cross-module references the combination broke — a
  name one side removed while the other started using it. That found nothing. It does
  **not** cover changed signatures with the same name, arity mismatches, or type errors,
  so "not found" means "not found by an import check," not "does not happen." It is also
  human history, not agent history, which is the whole open question.
- **Latency** is a median over repeated runs on a small repository, reported warm
  and cold separately because caching dominates.
- **The git ≥ 2.38 floor** comes from direct testing: the older three-argument
  `git merge-tree` reports *clean* for rename/rename, modify/delete and
  binary-vs-binary conflicts that a real merge rejects. A detector with silent
  blind spots is worse than no detector, so `moire` refuses to run below that
  version rather than degrade.

These are one person's measurements on a handful of repositories, not a study.
They are stated precisely so that they can be contradicted.

## License

MIT — see [LICENSE](LICENSE).
