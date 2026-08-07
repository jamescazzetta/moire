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

## Three things that make it unusual

**1. It needs no cooperation.** It reads the other agent's files directly — it never asks them anything. The other agent doesn't need the tool installed, doesn't need to know it exists, and can be from an entirely different vendor. Protection accrues to whoever runs the check.

This matters more than it sounds. The obvious design is to have agents *declare* what they're about to touch. That has been tried and measured, and it does not work: agents are unreliable narrators of their own scope. In a 360-run study of pre-write admission over declared intent ([arXiv:2608.00947](https://arxiv.org/abs/2608.00947)), the selective policy scored 22.2% against 23.3% for no coordination at all, failing closed on undeclared scope in 51% of runs. Watching beats asking.

**2. It's exact, not a guess.** No heuristics, no thresholds, no model, no tuning. `moire check` uses git's own merge engine, so its answer is the answer the real merge will give. `moire verify` runs a real checker on a real tree. False positives are structurally impossible.

**3. It never blocks.** Warn-only, by design — there is no block mode and no flag to add one. Blocking is a decision that needs evidence nobody has yet.

## Install

**Requires git ≥ 2.38.** Older git silently misses whole classes of conflict (rename/rename, modify/delete, binary), so `moire` refuses to run rather than give you a detector with blind spots. macOS ships 2.30 — `brew install git`.

```bash
# one worktree per agent
git worktree add ../repo-agent-a -b feat/a
git worktree add ../repo-agent-b -b feat/b

# install — ONCE PER CLONE, not per worktree
/path/to/moire install

# see the hook snippet for your agent client
/path/to/moire install --print-client-hooks

# verify everything is wired
/path/to/moire doctor
```

`moire install` puts the binary and git hooks inside `.git/`, which is shared by every worktree — so one install covers all of them, including worktrees you create later. Nothing executable is written into your working tree, and `core.hooksPath` is never touched.

For **Claude Code**, add this to `~/.claude/settings.json` (or a per-worktree `.claude/settings.local.json`):

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

Two things to know about that snippet:

- **The `command` path is absolute and specific to your clone.** Putting it in
  `~/.claude/settings.json` keeps it out of the repository entirely, which is the
  simplest option. If you prefer the in-repo `.claude/settings.local.json`, add that
  file to your `.gitignore` — committed, it would point at a path that exists only on
  your machine.
- **`moire install --print-client-hooks` prints the same snippet for Codex CLI, Cursor
  and OpenCode**, with the correct absolute path already filled in, so you can paste
  rather than hand-edit.

`moire` never writes to your client settings. It prints; you paste.

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

**The mechanism works and is tested.** 40 tests across three suites, all passing, including a negative-control run proving the suite can actually fail.

**Whether the problem is frequent enough to be worth solving is genuinely unknown.** In 2,347 real merges from six well-known open-source projects, the silent-semantic-breakage case that `moire verify` targets occurred **zero times**. Humans avoid it socially — issue claiming, standups, "I'm taking that module." AI agents dispatched in parallel have no such process, which is the whole premise of this tool. **That premise has never been measured.**

So this is a working instrument aimed at an open question, not a proven product. It is designed to answer its own question: point it at real concurrent agent work for a week and `moire report --study` gives you a base rate nobody has published.

The kill criterion, stated before the data arrives: **if semantic breakage stays at zero on real agent traffic, `moire verify` should be deleted** — leaving textual detection, which stands on its own.

## Tests

```bash
bash tests/test_oracle.sh    # 12 cases: conflict detection vs real `git merge`
bash tests/test_install.sh   # 16 cases: install, hooks, path resolution, concurrency
bash tests/test_study.sh     # 12 cases: finding IDs, randomised suppression, agent identity
```

Every suite verifies against independent ground truth and has been shown to fail when the implementation is stubbed out. A test suite that cannot fail is worse than none.

## Repository layout

```
bin/moire      the tool — a single file, Python 3.8, standard library only
tests/         40 tests across three suites
README.md      this file
LICENSE        MIT
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
