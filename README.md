# moire

**Tells parallel AI coding agents when their in-flight work would break each other — before either of them lands.**

---

## The problem

You run several AI coding agents at once to go faster. Each works in its own git worktree so they can't overwrite each other. Then you combine their work, and it breaks.

Here's the shape of it:

> **Agent A** renames `validate_session` to `validate_session_v2` in `auth.py`, and carefully updates every caller it can see. Correct work.
>
> **Agent B**, in a different file, adds a new function that calls `validate_session`. Also correct work.
>
> The two agents touched **completely different files**. Git merges them cleanly — no conflict markers, no warning. The program is broken.

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

Needs **git ≥ 2.38** and **Python 3.8+**. No daemon, no server, no config file, no
account, and nothing written into your working tree. Uninstalling is deleting a
directory.

## Three things that make it unusual

- **It asks nobody anything.** It reads the other agent's files. The other agent needs
  no setup, no awareness of the tool, and may be from a different vendor.
- **It is exact, not a guess.** No heuristics, thresholds, model or tuning — `check`
  runs git's own merge engine, `verify` runs a real checker on a real tree.
- **It never blocks.** Warn-only by design, with no block mode and no flag to add one.

Each of those is a reaction to something that has already been tried and measured.

## What has been tried before

This is a well-populated graveyard, and the failures are more instructive than the
designs.

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
  against 2,347 real merges *before* implementation: 24 fires, **0 true positives** —
  every one a regex artifact, including English prose in a docstring matching a
  definition pattern. Killed before a line was written.

The tool is what survived that.

## Install

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
| `moire verify` | Would the merged result be **semantically broken**, right now? |
| `moire explain <id> <text>` | Attach a one-sentence *why* to a specific finding. Advisory only — it can never change a verdict. |
| `moire install` | Install git hooks and the binary into `.git/` |
| `moire doctor` | Check git version, hook wiring, install state |
| `moire report` | Conflict base rate and most-contested paths |
| `moire report --study` | Per-finding lifecycle and A/B arm comparison |
| `moire init-swarm` | Create N worktrees, install, place the skill, verify |
| `moire wire-client` | Merge the hook into a client's settings (diff, then `--apply`) |

Both `check` and `verify` **always exit 0**. They warn; they never fail your build.

## How it works

For each peer worktree:

1. **Snapshot both sides** — committed, staged, unstaged and untracked changes — by working through a *copy* of the worktree's index. The observed worktree is never modified, and a peer that's mid-`git add` doesn't block observation.
2. **Ask git** — `git merge-tree --write-tree`. Exit code gives the verdict; conflicting paths come out on stdout.
3. **For `verify`** — that command prints the merged tree's ID *even when the merge is clean*. That tree is a merge that has never been attempted and may never be. Materialise it, run a checker over self / peer / merged, and report only breakage the **combination** creates:

   ```
   new_breakage = broken(merged) − broken(self) − broken(peer)
   ```

   Breakage already present in someone's branch is their own problem, not a collision.

The default checker is a small Python import resolver with no dependencies. `--checker 'mypy .'` or `--checker 'pytest -x'` swaps in whatever your repo already runs — so the check gets stronger for free as your own test suite does.

**Cost:** ~187 ms per write with 3 peers (warm), ~335 ms cold. Peer snapshots are cached; your own is always recomputed, because a stale self-snapshot is the one error that would silently produce a wrong answer.

## Status — read this before adopting

**The mechanism works and is tested.** 54 tests across four suites, all passing, including a negative-control run proving the suite can actually fail.

**Whether the problem is frequent enough to be worth solving is genuinely unknown.** In 2,347 real merges from six well-known open-source projects, the silent-semantic-breakage case that `moire verify` targets occurred **zero times**. Humans avoid it socially — issue claiming, standups, "I'm taking that module." AI agents dispatched in parallel have no such process, which is the whole premise of this tool. **That premise has never been measured.**

So this is a working instrument aimed at an open question, not a proven product. It is designed to answer its own question: point it at real concurrent agent work for a week and `moire report --study` gives you a base rate nobody has published.

The kill criterion, stated before the data arrives: **if semantic breakage stays at zero on real agent traffic, `moire verify` should be deleted** — leaving textual detection, which stands on its own.

## Tests

```bash
bash tests/test_oracle.sh    # 12 cases: conflict detection vs real `git merge`
bash tests/test_install.sh   # 16 cases: install, hooks, path resolution, concurrency
bash tests/test_study.sh     # 12 cases: finding IDs, randomised suppression, agent identity
bash tests/test_setup.sh     # 14 cases: init-swarm, wire-client, HOME containment
```

Every suite verifies against independent ground truth and has been shown to fail when the implementation is stubbed out. A test suite that cannot fail is worse than none.

## Repository layout

```
bin/moire        the tool — a single file, Python 3.8, standard library only
bin/moire.js     Node launcher, used only by the npm distribution
skills/          two Agent Skills: one for acting on a finding, one for
                 setting up parallel work
tests/           54 tests across four suites
package.json     npm packaging
README.md        this file
LICENSE          MIT
```

That is the whole thing. There is no build step, no package to install, no
configuration file and no runtime dependency beyond git.

## A note on the numbers

Every figure in this README is measured on this machine rather than estimated,
and the method is short enough to restate:

- **Conflict rates** come from replaying real merge history. Each merge commit on
  trunk is treated as a branch with a fork point and a merge date; two branches
  whose windows overlap were genuinely concurrent. Across flask, click, rich,
  requests, pytest and httpx that yields 2,347 concurrent pairs which merged
  cleanly — and zero instances of the silent semantic breakage `moire verify`
  targets.
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
