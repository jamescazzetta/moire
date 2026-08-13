# moire

**Tells parallel AI coding agents when their in-flight work would break each other — before either of them lands.**

*One file · Python 3.8+ · standard library only · git ≥ 2.38 · MIT · warns, never blocks*

## The problem

You run several AI coding agents at once. Each works in its own git worktree so they
can't overwrite each other. Then you combine their work, and it breaks:

> **Agent A** renames `validate_session` to `validate_session_v2` in `auth.py`, and
> carefully updates every caller it can see. Correct work.
>
> **Agent B** adds a new file that calls `validate_session`. Also correct work — in
> B's worktree, that function still exists.
>
> Their file sets are **disjoint**, so git merges them cleanly — no conflict markers,
> no warning. The merged result calls a function that is no longer there.

Or, as a house: one builder moves the front door to the side. Another builds a garden
path up to where the front door used to be. Neither touched the other's work. Both
jobs are individually correct. Together you have a path leading to a wall.

**Git catches overlapping *lines*. It cannot catch overlapping *meaning*.** CI
catches it only after both changes have landed, when unwinding is expensive and both
agents have moved on.

## What moire does

After each file write, it runs a **dress rehearsal**: it combines your working tree
with each other agent's working tree in a scratch space nobody sees, and checks
whether the combination actually holds. On the exact scenario above — run here
2026-08-12, output as commented:

```bash
moire check    # clean   — correct; there is no textual conflict
moire verify   # BROKEN  ('src/service.py', 'src.auth', 'validate_session')
```

Two commands, same trees, opposite verdicts — and both are right, because they answer
different questions. `check` finds textual conflicts between **live, uncommitted
worktrees**, earlier than git would. `verify` runs a real checker on the merge git
*would* produce, and reports the breakage that merges cleanly. In full:

```
$ moire check
CONFLICT with /repo-agent-b (feat/auth) [finding 675ef3f810e1]
    src/api.py
  arbiter: self yields (adoptability: self has uncommitted work, peer is fully committed)
  actions: rebase onto theirs | narrow your change | retarget | wait for them to land | proceed

$ moire verify
BROKEN with /repo-agent-b (1 new breakage, merged tree d6d2141b)
    ('src/service.py', 'src.auth', 'validate_session')
```

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

## Three things that make it unusual

- **It asks nobody anything.** It reads the other agent's files. The other agent needs
  no setup, no awareness of the tool, and may be from a different vendor.
- **It is exact, not a guess.** No heuristics, thresholds, model or tuning — `check`
  runs git's own merge engine, `verify` runs a real checker on a real tree.
- **It never blocks.** Warn-only by design, with no block mode and no flag to add one.

Each of those is a reaction to an approach that has already been tried and measured —
the [prior-art table below](#why-not-do-it-another-way) has the outcomes.

**New in 0.13:** a finding can now travel. `moire pending` lists what is outstanding
against each peer, and `moire compose` renders one finding as a message for whatever
agent-messaging channel your harness has — [From finding to
conversation](#from-finding-to-conversation). Full history in
[CHANGELOG.md](CHANGELOG.md).

## Quickstart

```bash
git clone https://github.com/jamescazzetta/moire.git ~/.moire
mkdir -p ~/.local/bin && ln -sf ~/.moire/bin/moire ~/.local/bin/moire
# ~/.local/bin must be on PATH:  export PATH="$HOME/.local/bin:$PATH"

cd your-repo
moire init-swarm --agents 3                     # worktrees, hooks, skills, doctor
moire wire-client claude --scope user --apply   # shows a diff first
```

Needs **git ≥ 2.38** (older git silently misses whole classes of conflict, so moire
refuses to run below it) and **Python 3.8+**. No daemon, no server, no config file,
no account, and nothing written into your working tree. `init-swarm` also installs
two Agent Skills — one teaches an agent to act on a finding, one to run the swarm.

The detail behind every line of that — why a symlink, the binary-only variant,
what `wire-client` writes, manual setup, and the five places a full uninstall
touches — is in [docs/INSTALL.md](docs/INSTALL.md). There is no npm package.

## Compared with Clash

**`moire check` is not novel.** [Clash](https://github.com/clash-sh/clash) (Rust,
MIT) ships the same `git merge-tree` oracle between agent worktrees, with a Claude
Code hook, and got there first. The same primitive was also published as a
measurement method by Xu, Subramanian & Karthik
([arXiv:2607.04697](https://arxiv.org/abs/2607.04697)). `moire check` is
*different*, not first, and the difference is two testable claims.

**Claim 1 — Clash's simulation cannot see uncommitted work; moire's is built on
it.** Clash merges each worktree's `commit.tree_id()`; it renders a `Dirty` marker
but excludes dirty state from the simulation. That comes from reading
`src/worktree/conflict.rs` — a claim about its source, not about a run of it. When
both agents edit the same line and neither has committed, the two HEADs are the same
commit: a HEAD-based simulation has nothing to compare. Run here 2026-08-12: both
worktrees at the same HEAD, `moire check` → `CONFLICT ... src/auth.py`.

<details>
<summary><strong>Two minutes to falsify Claim 1</strong></summary>

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

Commit both sides and every tool agrees.

</details>

**Claim 2 — nothing surveyed runs a checker on the speculative merged tree.**
Clash's FAQ scopes it to detection, textual only. The canonical disjoint-edit case
at the top of this README is exactly what that misses, and it is `tests/test_verify.sh`
case 2.

<details>
<summary><strong>Two minutes to falsify Claim 2</strong></summary>

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

</details>

**Where Clash wins, and it is conceded.** A Rust binary installs more easily than a
Python file you have to put on `PATH`. Clash can *gate* an edit through a
`PreToolUse` ask-hook; moire never blocks and has no flag to make it — a design
position, not a missing feature, and if you want a gate you should use Clash.
Per-check latency has not been compared and no claim is made either way.

## Commands

| | |
|---|---|
| `moire check` | Would my worktree conflict **textually** with each peer, right now? |
| `moire verify` | Would the merged result be **semantically broken**, right now? Reads `moire.checker` / `moire.link` from `git config` when `--checker` / `--link` are absent. |
| `moire replay <a> <b>` | The `verify` mechanism on two **commits** instead of two live worktrees — the measurement instrument. Stateless: no log, no cache, no snapshot, and it works in a bare clone. |
| `moire pending` | What findings are outstanding between me and each peer, **according to the log** — read-only, no new observation. Prints each finding's age and says to re-run `check` for a live answer. |
| `moire compose <id>` | Render one finding as a message for whatever channel your harness has, with the id the receiver re-computes from their own run. `--action rebase\|narrow\|retarget\|wait\|proceed` states what the sender chose. moire has no transport; the agent sends it. |
| `moire install` | Install git hooks and the binary into `.git/` |
| `moire doctor` | Check git version, hook wiring, install state |
| `moire report` | Rates over distinct pair-states, distinct findings, contested paths, and how many findings have cleared |
| `moire init-swarm` | Create N worktrees, install, place the skills, run doctor |
| `moire wire-client` | Merge the hook into a client's settings (diff, then `--apply`) |

`check`, `verify` and `replay` **never exit nonzero because of a finding** — they
warn; they never fail your build. The one exception is a refusal: exit 2 on an
unusable environment or a bad argument, before writing any log.

## How it works

For each peer worktree:

1. **Snapshot both sides** — committed, staged, unstaged and untracked changes — by
   working through a *copy* of the worktree's index. The observed worktree is never
   modified, and a peer that's mid-`git add` doesn't block observation.
2. **Ask git** — `git merge-tree --write-tree`. Exit code gives the verdict;
   conflicting paths come out on stdout.
3. **For `verify`** — that command prints the merged tree's ID *even when the merge
   is clean*. That tree is a merge that has never been attempted and may never be.
   Materialise it, run a checker over self / peer / merged, and report only breakage
   the **combination** creates:

   ```
   new_breakage = broken(merged) − broken(self) − broken(peer)
   ```

   Breakage already present in someone's branch is their own problem, not a
   collision. Two ordinary agent actions could defeat that subtraction — a peer
   `git mv` relocating your pre-existing findings, a peer's new dependency missing
   from the merged tree — and both are controlled: findings are rewritten through a
   rename map before subtracting, and linked directories are built as a per-entry
   union. The residual limits are in the `--checker` contract below.

The default checker is a small Python import resolver with no dependencies: it
proves an import still resolves — both the module and the name it takes from it —
not that its contract held. An import of a module that is not in the tree is
recorded as a finding, `os` and `numpy` included, and the subtraction throws those
away: they are unresolvable in all three trees and cancel, while a module one agent
deleted or `git mv`d is unresolvable only in the merge — one agent moving the door
while the other builds a path to where it was. `tests/benchmark_recall.sh` measures
what it catches, graded by CPython rather than by moire: **9 of 11** textually clean
collisions, **0 of 7** clean merges reported as broken. [What that score does and
does not mean](docs/MEASUREMENTS.md#what-9-of-11-measures) is worth reading before
quoting it.

It **reads Python only**, and it says so rather than implying otherwise:

```
$ moire verify
clean   with /repo-agent-b (textual only - no semantic check was performed)
  builtin-ast examined 0 of 847 files: it reads only Python and this tree has no .py files.
  The merged result was NOT semantically verified - "clean" above means only that git found no textual conflict.
  To enable semantic verification for this repo: git config moire.checker '<command>'   (README: the --checker contract)
```

Such a record is excluded from `moire report`'s semantic rate and counted under
`unperformed_semantic_checks` instead — a check that measured nothing must not be
averaged in as a clean one.

### Pointing `verify` at your language, per repo

Set the checker once per clone and every agent only ever types `moire verify`:

```bash
git config moire.checker './node_modules/.bin/tsc --noEmit | sed -E "s/\([0-9]+,[0-9]+\)//"'
git config --add moire.link node_modules
moire doctor      # warns when `verify` would have nothing to read
```

This is `git config`, not a file committed to the repository, and the difference is
the point: `.git/config` is never cloned, so a checkout cannot carry a command that
runs on someone else's machine. It lives in `$GIT_COMMON_DIR`, so one setting covers
every worktree of the swarm. `--checker` and `--link` still work and take
precedence.

Because the set difference is computed over the checker's output *lines*, a checker
has to be deterministic and emit one finding per line with repo-relative paths.
Break those rules and you get false breakage rather than silence — read the
contract before pointing `--checker` at something.

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

The worked example above — `tsc --noEmit` piped through `sed` to strip positions, with `node_modules` linked — satisfies the mechanical rules. The same thing as a one-off flag:

```bash
moire verify --checker './node_modules/.bin/tsc --noEmit | sed -E "s/\([0-9]+,[0-9]+\)//"' --link node_modules
```

</details>

## Cost

Measured 2026-08-12 on a lab repository of 62 Python files with three peer worktrees
— method, machine and load in [docs/MEASUREMENTS.md](docs/MEASUREMENTS.md#how-the-cost-table-was-measured):

| against 3 peers | warm | cold |
| --- | --- | --- |
| `moire check` | 219 ms | 404 ms |
| `moire verify` (builtin-ast, 62 files) | 454 ms | 635 ms |

**These are ceilings, not figures** — taken under load averages of 10–11 on 8
cores; an idle machine will be faster, nothing here will be slower. Point
`--checker` at anything real and the figure stops applying entirely: cost becomes
`snapshot overhead + K × checker runtime`, where `K = 2 × peers + 1`. With a checker
in the seconds range that puts `verify` past what belongs on a per-write hook. Run
`check` on every write and `verify` before declaring a task done, which is what
`skills/moire-parallel/SKILL.md` instructs. Re-checking an unchanged worktree writes
no git objects at all — snapshots are content-addressed.

## From finding to conversation

A finding is only worth what happens next, and the two halves of *next* shipped
separately. Agent messaging is **transport with no trigger** — Claude Code's
cross-session messaging is explicit that *"a message is a piece of text one Claude
writes to another"*, and a collision warning carried that way fires only if an agent
notices the collision, decides to send, and picks the right session. moire is the
mirror image: a **trigger with no transport**. It notices the fact, names it, and
prints it to a terminal the other agent is not reading.

0.13 joins them, and the join is one command wide: moire composes the message; the
agent sends it.

`moire pending` answers *what is outstanding between me and each peer* from the log
alone — no snapshot, no peer read, nothing written (a suite case pins that by
fingerprinting `.git/moire/` around five invocations). Each finding is judged
against the latest record **of its own kind**: a plain `check` never asks the
semantic question, so a `check` on a per-write hook cannot clear a `BROKEN` finding
it never re-examined. Run here 2026-08-13, in a two-worktree lab holding this
README's own example:

```
$ moire pending
pre-v2 records ignored            : 0
BROKEN with /private/tmp/moire-lab/repo-agent-b (feat/b) [finding c7c86b514435] kind=semantic age=1s
    ('src/service.py', 'src.auth', 'validate_session')
  arbiter: self yields (adoptability: self has uncommitted work, peer is fully committed)
(from the log; oldest of the above is 1s old; re-run 'moire check' for a live answer)
```

`moire compose <finding-id>` renders one finding as a message, shaped for pasting
into whatever channel the harness provides:

```
$ moire compose c7c86b514435 --action rebase
moire finding c7c86b514435
(computable identically from your side - derived only from the two worktree paths and the contested paths/breakage, never from anything either of us declares)

FROM
  worktree : /private/tmp/moire-lab/repo-agent-a
  branch   : feat/a
  HEAD     : 85b6928df15065d9bf8c71fae8f6566e5a91ec8f
  age      : 11s

THE FACT
  BROKEN
  textually: clean - git reports no conflict
  breakage(s): 1 (merged tree 9b6548b2e379d20e5ab061e7820f750d4d577a46)
    ('src/service.py', 'src.auth', 'validate_session')
  meaning: git merges this cleanly; the result is broken

ARBITER
  recommendation: the sender (this side) yields
  reason: adoptability: self has uncommitted work, peer is fully committed
  computed from facts observable to both of us; your moire reports the same recommendation - its 'self' is you

SENDER'S ACTION
  sender is rebasing their own work onto the peer's

VERIFY
  run `moire verify` in your own worktree - the same finding id (c7c86b514435) confirms it
```

Four things in that message are load-bearing:

- **The finding id is the receiver's own check, not the sender's word** — both sides
  compute it independently and get the same string, verified in this lab run from
  both worktrees.
- **It composes only from records this side logged** — the same id sits in the
  peer's records with `self` and `peer` swapped, and rendering theirs would name
  the receiver as the sender; compose refuses instead, with an explanation.
- **The arbiter is translated across the boundary** — *the sender (this side)* /
  *the receiver (your side)*, because the stored labels are relative to whoever ran
  the check.
- **`SENDER'S ACTION` binds only the sender** — a statement, never a demand.

The receiving agent's first move is not to act on the message. It is to re-run
`moire check` or `moire verify` in its own worktree; the same finding id coming back
from its own run is the confirmation, and until then the message is another agent's
claim, not evidence. `skills/moire/SKILL.md` instructs the receiving side in exactly
those terms. The lab verification of all of this is written up in
[docs/MEASUREMENTS.md](docs/MEASUREMENTS.md#the-finding-to-conversation-lab-verified-end-to-end).

**moire never transmits any of this.** There is no `moire send`, no socket, no
discovery, no inbox and no delivery state; `compose` is a pure function of the log
that writes to stdout. Owning the wire means owning identity, retry and a config
surface, and a tool that does can only be one harness's tool. The agent owns the
wire.

**Whether any of this changes what agents do is unmeasured.** `moire report` now
counts findings *cleared* and *outstanding* — cleared meaning a later check of the
same kind no longer reports it, `(cause is not implied)` — which makes the question
answerable for the first time. That is the instrument for a clearance study, not
the study, and no data exists yet.

## What observation writes, and where

"The peer needs zero participation" has a cost, and it is the peer's: **a peer
cannot opt out of being observed.** Snapshotting runs `git add -A` through a *copy*
of the peer's index, so every file in the peer's worktree that is **untracked and
not gitignored** is written as a blob into the repository's shared object store.
That is load-bearing — the canonical example is a peer's brand-new, not-yet-committed
file, and it is invisible without this — but you should know it happens.

Verified here 2026-08-12, on a lab repo with three peer worktrees: a peer's
untracked `.env.local` was found as a blob in the shared object store after one
`moire check`, and a file under a gitignored directory was not. Three properties
bound it:

- **No new read access.** The object store is shared by every worktree of the repo.
  Anyone who can read it could already read the peer's worktree directly.
- **Gitignored files are never captured.** `git add -A` respects `.gitignore`, so
  the ordinary hygiene of gitignoring `.env*`, credentials and key material is also
  the fix here. Do it anyway; do it first.
- **The exposure is persistence, not access.** The blob is refless — nothing shows
  it in a log or a diff, and it survives until git's housekeeping prunes it (two
  weeks by default for loose objects). `git gc --prune=now` removes it immediately;
  verified here.

## Why not do it another way?

Several other approaches exist. Their measured outcomes are more instructive than
the designs, and they are why moire is shaped the way it is.

| Approach | Example | What happened |
| --- | --- | --- |
| **Agents declare what they will touch**; a registry arbitrates | MCP Agent Mail, Agent Claim MCP, [wit](https://github.com/amaar-mc/wit), [grit](https://github.com/rtk-ai/grit) | Advisory by their own documentation — nothing enforces a claim — or enforced by a lock registry every agent must join. All fail open the moment one agent, say another vendor's, doesn't participate. |
| **Let the agents talk to each other** | Claude Code cross-session messaging | Shipped by the vendor, and explicitly transport: *"a message is a piece of text one Claude writes to another, never conversation history or files."* It fires only if an agent notices the collision, decides to send, and picks the right session. moire 0.13 is the noticing-and-composing half of exactly that pipeline — [`pending` and `compose`](#from-finding-to-conversation) — without becoming the transport. |
| **Detect overlap at pull-request time** | [ConE](https://arxiv.org/abs/2101.06542) (Microsoft Research + TU Delft) | Works, at scale — flagged 775 of 26,000 pull requests (3.33%) across 234 repositories; 71.48% of notifications rated "Resolved" *by users*, a user rating and not precision against ground truth. Detects *file* overlap, after both branches already exist, and ships as a comment. |
| **Warn human developers proactively** | Crystal ([Brun et al., ESEC/FSE 2011](https://cs.uwaterloo.ca/~rtholmes/papers/fse_2011_brun.pdf)) | moire's direct ancestor: it merged peers' committed code, built it, ran its tests, and showed a per-peer icon. Fifteen years later, no published evidence of durable industrial adoption for it or any of its successors. |
| **Isolate, merge later** | every commercial agent orchestrator | Works, and defers the problem to a human at merge time. This is what everyone actually ships. |
| **Merge queues** | Mergify, GitHub merge queue | Real semantic detection: full CI on speculatively merged combinations, ejecting the culprit. It runs on completed, pushed PRs — the same idea as `verify`, at the opposite end of the lifecycle. |
| **Partition the work before dispatch** | [Co-Coder](https://arxiv.org/abs/2606.00953) | The strongest result in the table: cohesion-aware partitioning beat the sequential baseline (68.1% vs 56.8% pass on DevEval), while *naïve* file-based parallelism cost 60% more for a 3.2% pass-rate gain. Greenfield generation, not repository modification. |

The first two rows share a shape: they ask an agent to describe or announce its own
work. moire never asks — it reads the other worktree's files, so there is no
declaration to be wrong. Three consequences follow structurally: **nothing to
tune** (git's merge engine *is* the answer the real merge will give); **it sees what
nothing surveyed does** (a claim about a survey — one counter-example falsifies it,
and would be welcome); **one-sided by construction** (it protects whoever runs it,
against agents that are not cooperating — though the measured cross-vendor case is
thin: 0.5% of co-active agent PR pairs, per Xu et al.).

It is aimed at the case partitioning cannot reach: tightly-coupled work is exactly
where concurrent agents still collide — which also means moire's addressable surface
is the residue a good dispatcher leaves, not "everyone running parallel agents".
Three earlier mechanisms designed for this project — a declared-intent ledger, a
line-range overlap predicate, a symbol-matching heuristic — were abandoned when
measurement said no; the record is in
[docs/MEASUREMENTS.md](docs/MEASUREMENTS.md#what-this-project-tried-and-threw-away).

## Status — read this before adopting

**`moire check`: done.** Correct, tested against real `git merge` outcomes, and not
novel (see [Compared with Clash](#compared-with-clash)). Everything it finds, git
finds later, for free; its whole value is that it finds it earlier, and on live
uncommitted trees.

**`moire verify`: mechanism verified, rate unmeasured, decision rule
pre-registered.** That is its complete status and none of the three parts should be
read without the other two.

- *Mechanism verified* — the failure it detects is real and easy to reproduce
  (case 2 of `tests/test_verify.sh` is exactly it); the recall benchmark grades the
  checker against CPython, not against moire; and the two false-BROKEN classes that
  ordinary agent behaviour produces — a peer `git mv`, a peer installing a
  dependency — are controlled, each with a regression test.
- *Rate unmeasured* — **what is unknown is the frequency, not the existence.**
  Nobody has published how often two concurrent agents produce a clean merge that
  doesn't work. The two papers that measured agent merge conflicts both name that
  layer as their own limitation: *"no tracking is done for deeper build or semantic
  conflicts"* (Xu et al.), *"it does not account for higher-level forms of conflict
  such as logical inconsistencies or post-merge defects"* (AgenticFlict).
- *Decision rule pre-registered* —
  [`PHASE1-PREREGISTRATION.md`](PHASE1-PREREGISTRATION.md) fixes the rule before the
  data: replay ≥500 textually clean co-active agent PR pairs, audit every reported
  breakage, and retire `verify` as a live feature below a 0.5% audited
  true-collision rate. `moire replay` is the instrument and
  [`tools/replay-corpus/`](tools/replay-corpus/) is the harness.

**No Phase 1 result exists.** A feasibility pilot on 2026-08-12 constructed 24 pairs
and evaluated **20** of them, against a pre-registered minimum of 500. No pair
reported breakage, which at n=20 means nothing in either direction. The pilot and
its attrition ladder are in
[`tools/replay-corpus/README.md`](tools/replay-corpus/README.md); it establishes
that the harness runs, and nothing else.

**`moire pending` and `moire compose`: new, and unmeasured in a second way.**
Whether a finding that reaches the other agent changes what that agent does is
unmeasured — [`report`'s cleared/outstanding
counts](#from-finding-to-conversation) are the instrument for measuring it, and no
data exists yet.

So this is a working instrument aimed at an open quantity, not a proven product.

## Tests

```bash
bash tests/test_oracle.sh    # 12 cases: conflict detection vs real `git merge`
bash tests/test_install.sh   # 21 cases: install, hooks, path resolution, concurrency, object-store growth
bash tests/test_report.sh    # 19 cases: finding identity, pair-state metrics, replay statelessness, pending and compose
bash tests/test_setup.sh     # 14 cases: init-swarm, wire-client, settings-file handling
bash tests/test_verify.sh    # 44 cases: the semantic path — new_breakage, renames, --link union, replay
bash tests/negative_control.sh   # proves the five suites above can fail
bash tests/benchmark_recall.sh   # 18 collision fixtures graded by CPython, not by moire
```

**110 cases; measured 2026-08-13: 109 passed, 1 skipped, 0 failed.** The skip is a
`DeprecationWarning` check that only applies on Python 3.12+ and this machine runs
3.8.2. `tests/negative_control.sh` is the answer to "a test suite that cannot fail
is worse than none": it points `MOIRE_BIN` at a `#!/bin/sh; exit 0` stub and then at
a path that does not exist, and asserts that **every** suite exits nonzero in both
scenarios — measured 2026-08-13, 10 of 10 checks went red as required.

`test_oracle.sh` has the strongest ground truth (a real `git merge`, compared);
`tests/benchmark_recall.sh` grades the semantic checker against CPython on the
merged tree rather than against moire's own output. What each suite can and cannot
prove — and what the benchmark's score means — is in
[docs/MEASUREMENTS.md](docs/MEASUREMENTS.md#what-the-test-suites-can-and-cannot-prove).

## Repository layout

```
bin/moire            the tool — a single file, Python 3.8, standard library only
skills/              two Agent Skills: one for acting on a finding, one for
                     setting up parallel work
tests/               110 cases across five suites, plus the negative control and
                     the recall benchmark
tools/replay-corpus/ the Phase 1 measurement harness (stdlib only, not shipped)
docs/                INSTALL.md and MEASUREMENTS.md — the detail behind this page
PHASE1-PREREGISTRATION.md   the decision rule, committed before any data
CHANGELOG.md         what changed in each release, and why
package.json         private test-runner manifest — `npm test` only, never published
README.md            this file
LICENSE              MIT
```

There is no build step, no configuration file and no runtime dependency beyond git.

## A note on the numbers

Every figure here is one of three things, and which one is always stated: **measured
here** (dated, machine attached, published as a ceiling where load makes it one),
**this project's own working notes** (labelled as its word, not something you can
check here), or **cited to a primary source with its denominator attached**. The
full ledger — method and machine for every measurement, the citation table, and the
scope of every score — is [docs/MEASUREMENTS.md](docs/MEASUREMENTS.md).

That ledger also states [the strongest published argument against this
project](docs/MEASUREMENTS.md#the-strongest-argument-against-this-project) rather
than omitting it: Mergify's *State of Merge Queues 2026* found AI-assisted PRs broke
main **1.9%** of the time against **4.4%** for PRs with no detectable AI assistance,
across 200,000+ merges — if AI-authored changes integrate more safely, the premise
here weakens. The same report finds broken-main scaling with concurrency, from
0.77% at 2–5 engineers to 12.5% at 40+, which cuts the other way. The caveats on
both cuts are in the ledger.

These are one person's measurements plus other people's published work. They are
stated precisely so that they can be contradicted.

## License

MIT — see [LICENSE](LICENSE).
