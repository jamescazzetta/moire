---
name: moire
description: Interpret and act on a moire finding. Use when `moire check` or `moire verify` reports a CONFLICT or BROKEN result against another agent's worktree, or when deciding how to respond to an overlap with concurrent in-flight work.
---

A `moire` finding means another agent is working, right now, on something that
collides with what you just wrote. It is a fact, not a suggestion: the verdict comes
from running git's own merge engine against the other worktree's actual contents.

Nothing about it blocks you: a finding never makes `moire` exit nonzero, so it can
never fail your build. (It exits 2 on a bad argument or an unusable environment, before
writing anything — that is a refusal, not a finding.) Deciding is your job.

## Read the finding

```
CONFLICT with /repo-agent-b (feat/auth) [finding 675ef3f810e1]
    src/api.py
  arbiter: self yields (adoptability: self has uncommitted work, peer is fully committed)
  actions: rebase onto theirs | narrow your change | retarget | wait for them to land | proceed
```

**`CONFLICT`** — the two working trees would not merge cleanly. Git will stop with
conflict markers at `src/api.py`. Someone resolves this by hand, later, with less
context than you have now.

**`BROKEN`** — more important, and easy to under-react to. The merge is textually
*clean*; git will report no conflict at all. The combination is nevertheless broken —
typically one side removed or renamed something the other side started calling.

```
BROKEN with /repo-agent-b (1 new breakage, merged tree d6d2141b)
    ('src/service.py', 'src.auth', 'validate_session')
```

Read that as: in the merged result, `src/service.py` refers to `validate_session` in
`src.auth`, and it will not be there. **Nothing downstream catches this** — not git,
not review, only CI after both branches land. A `BROKEN` finding is the one case
worth interrupting yourself for.

`moire` reports only breakage the *combination* creates: breakage already present in
either branch alone is subtracted out, and findings are rewritten through a rename map
first, so a peer's `git mv` no longer relocates your own pre-existing problems into
the result. That subtraction cancels on the *text* of a finding, so it is strong but
not absolute — a checker whose message embeds something from elsewhere in the tree can
still fail to cancel. Treat `BROKEN` as a strong signal to look, not as a proof.

A verdict may also carry a line like `linked directory 'node_modules': merged tree
used self's, plus 1 entry/entries only the peer has (left-pad)`. That is
informational, never a finding: the two worktrees' linked directories differed and the
merged tree was given a per-entry union of both, which is the tool saying what the
checker was allowed to read.

**On its status:** the mechanism works and is tested; **how often this happens in real
concurrent agent work has not been measured.** A decision rule for keeping or retiring
`verify` was pre-registered before any data (`PHASE1-PREREGISTRATION.md`), and no
result exists yet. Act on a finding you get; do not claim a base rate.

## A third outcome: `no semantic check was performed`

```
clean   with /repo-agent-b (textual only - no semantic check was performed)
  builtin-ast examined 0 of 847 files: it reads only Python and this tree has no .py files.
  The merged result was NOT semantically verified - "clean" above means only that git found no textual conflict.
```

This is neither `CONFLICT` nor `BROKEN` nor a pass. `verify` gave **no semantic
answer at all** — the default checker reads Python and this repository has none for it
to read. Treat it as *"verify was unavailable"*, exactly as you would a tool that
failed to run. It is never *"verify passed"*: the merged result was not examined, so
the `BROKEN` case above would have been invisible.

**Do not improvise a checker mid-task.** A `--checker` command that is
nondeterministic, prints a summary line, or emits absolute paths manufactures false
breakage rather than silence, and you will act on it. Choosing one correctly is a
setup decision, not something to guess at while working.

What to do instead: finish and report the gap to whoever dispatched you — the repo
needs `git config moire.checker '<command>'` set once, and `moire doctor` says so.
State plainly that your work was checked textually but not semantically, rather than
reporting it as verified.

## The arbiter line

`arbiter: self yields` is a **recommendation**, computed from facts observable in both
worktrees — who has committed, diff size, branch age. It is not an instruction and no
one enforces it.

Its value is that both agents compute the same answer independently, with no
negotiation. If it says you yield, the other agent's `moire` is telling them they win.
Following it means you converge without talking. Deviating is fine when you know
something it cannot observe — but the other side has no way to learn that from
`moire`, so it will keep acting on a recommendation you have silently abandoned. If
your harness gives you a channel to that session, that is where to say so; `moire`
computes findings and does not carry messages.

## Choosing an action

All five are things you can do **alone**. None requires the other agent to agree,
notice, or respond.

| Action | Use when |
| --- | --- |
| **rebase onto theirs** | Their work is committed and yours is not. Cheapest path: you inherit their change and re-apply on top. Re-verify afterwards — your work was written against a base that no longer exists. |
| **narrow your change** | You touched the contested file incidentally. Drop that part, keep the rest, and the finding disappears. |
| **retarget** | The thing you were about to build already exists in their work, or belongs in their file. Build on it instead of beside it. |
| **wait for them to land** | The collision is real and neither side can narrow. Switch to another part of your task; re-run `moire check` afterwards. |
| **proceed** | The arbiter says you win, or the overlap is genuinely harmless. **This is a legitimate choice**, not a failure — but choose it deliberately. |

## The failure mode to avoid

**Reading the finding and carrying on unchanged.** The most common outcome, and the
one that makes the whole mechanism worthless. If you decide to proceed, that is fine —
but decide, rather than defaulting.

And re-check rather than reasoning about what the peer probably did since. A verdict
is cheap; a belief about another agent's worktree is not evidence.

## Checking on demand

```bash
moire check      # textual: would these merge cleanly right now?
moire verify     # semantic: would the merged result actually work?
moire report     # this repo's rates over distinct pair-states and findings
```

`verify` is worth running before you consider a piece of work finished, since it
catches what `check` structurally cannot.

`moire report` counts **distinct pair-states** — distinct observed content pairs of two
worktrees — not invocations, so running `check` on a hook does not inflate it. It is
also not per task, per merge or per day: do not report it as one.
