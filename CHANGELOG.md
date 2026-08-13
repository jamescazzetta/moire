# Changelog

The full history, including the defects each release found in itself and how they
were fixed. This file is where the project's past lives; the README states only what
is true now.

## 0.13.0 — 2026-08-13

- **`moire pending` is new** — the read-only query surface. It groups this worktree's
  own logged records by peer and prints what is still outstanding against each:
  finding id, kind, peer path and branch, the contested paths or breakage triples,
  the arbiter line, and the age of the record it came from. No snapshot, no peer
  worktree read, no log write. Every run says it is answering from the log and to
  re-run `check` for a live answer, because a log is a view of the past.
- **`moire compose <finding-id>` is new** — one finding rendered as a message
  ([README: From finding to conversation](README.md#from-finding-to-conversation))
  for whatever channel the agent's harness has. It composes only from records this
  side logged, translates the arbiter into sender/receiver terms, states the sender's
  own chosen action if `--action` was given, and ends with the command the receiver
  runs to confirm the same id themselves. moire has no transport and gains none:
  `compose` prints, and the agent moves it.
- **`moire report` counts findings cleared and outstanding.** A finding is cleared
  when a later check *of the same kind* no longer reports it. The line says
  `(cause is not implied)` in the output itself, because clearance does not
  distinguish a rebase from an abandonment. It is the instrument for measuring
  whether the finding-to-message loop changes anything, and that measurement has not
  been made.
- **The npm ghost is deleted** — `bin/moire.js` and the publish metadata are gone,
  and `package.json` is now a private manifest that exists only to run `npm test`.
  `@jamescazzetta/moire` has never been published; if you find that name on a
  registry, it is not this project.
- **Four defects were found by exercising `pending` and `compose` on a real fixture
  before documenting them**, and none of them by the suite that was supposed to
  cover them:
  - *A textual `check` could clear a semantic finding.* Both `pending` and `report`
    judged every finding against the pair's latest record whatever kind it was — and
    a plain `check` never asks the semantic question, so with `check` on a per-write
    hook the next keystroke erased the `BROKEN` finding `pending` exists to surface.
    Each finding is now judged against the latest record of its own kind.
  - *"Latest" was a coin flip inside a wall-clock second.* Two records with the same
    timestamp were ordered by `check_id`, which is random hex. The log is
    append-only, so arrival order is now the tiebreak everywhere a latest record is
    chosen; that is also what un-flaked an existing suite case.
  - *`compose` could speak from the peer's record.* The same finding id exists in
    both sides' records with `self` and `peer` swapped — which is the whole
    verification story — so when the peer had run the more recent check, `compose`
    rendered theirs: `FROM`, `HEAD` and the arbiter inverted, a message naming its
    own receiver as the sender. It now composes only from this worktree's records
    and refuses, with an explanation, when the id exists only on the other side.
  - *The arbiter crossed the message boundary untranslated.* A receiver would have
    read `peer yields` while their own moire printed `self yields` for the same
    fact — the exact ambiguity the message exists to remove. Also gone from
    `THE FACT`: a raw `verdict: clean` printed under a `BROKEN` header, which read
    as a contradiction and now reads `textually: clean - git reports no conflict`.

  Two new cases in `tests/test_report.sh` pin the behavioural fixes with the
  sequences that exposed them.
- **`tests/test_setup.sh` no longer writes into the invoker's real `$HOME`.** Its
  `init-swarm` cases ran with no `--skills` override, and `--skills user` is the
  default, so the suite copied this repository's `skills/` into `~/.claude/skills/`
  and `~/.agents/skills/`, moving anything already there to `*.moire-backup`. Two
  cases had isolated `$HOME` themselves, which is exactly why the leak survived:
  per-case isolation only protects the cases someone remembered. The suite now
  isolates `$HOME` once at setup and restores it in the exit trap, so a case added
  later cannot reintroduce the leak by omission. Verified 2026-08-13: the four real
  `SKILL.md` files under `~/.claude/skills/` and `~/.agents/skills/` hash
  identically before and after a full run of that suite, and no `*.moire-backup`
  directory was created.
- **The uninstall documentation was wrong once.** An earlier README said uninstalling
  was one directory; it is five places, and
  [docs/INSTALL.md](docs/INSTALL.md#uninstalling) now lists all of them.

## 0.12.0 — 2026-08-12

- **The builtin checker sees a module vanish, not only a name.** It used to skip any
  import whose module was absent from the materialised tree, which is right for `os`
  and `numpy` and catastrophic for a module the other agent just deleted or moved:
  the headline failure this tool is about reported `semantic ok`. Absent modules are
  now findings, and the existing `broken(merged) − broken(self) − broken(peer)`
  subtraction removes the ambient ones — recall on the recall benchmark
  ([README: Tests](README.md#tests)) goes from 4 of 11 to 9 of 11 with no new false
  positive there or on the pilot corpus pairs. Per-tree finding counts rise by one
  to two orders of magnitude as a result; the difference between them, which is the
  judgement, does not.
- **`moire report` rates situations, not observations.** Its denominators are now
  distinct *pair-states* — distinct observed `(self_tree, peer_tree)` content
  pairs — and distinct findings, with raw observation counts kept alongside for
  transparency. Previously one collision seen four times read as four broken pairs
  at a 100% rate. A pair-state is **not** a task, a merge, or a day; it is a
  distinct observed content state of a worktree pair. Records written by older
  versions are counted and excluded as `pre-v2 records ignored` rather than
  silently mixed in.
- **`moire replay <a> <b>` is new** — the same mechanism on two commits instead of
  two live worktrees, stateless and usable in a bare clone. It is what makes the
  Phase 1 measurement possible without adopters.
- **`moire explain` and the notes machinery are gone**, along with `report --study`
  and the `MOIRE_SURFACE_*` environment variables. `report --study` now refuses by
  name. The notes channel was a declared, agent-authored input inside a tool whose
  whole premise is observation, and the A/B machinery could not have produced an
  interpretable result. Agent-to-agent commentary belongs on the platform's own
  cross-session messaging; moire computes findings.
- **Unknown and valueless flags refuse with exit 2** before any snapshot or log
  write. `check --block` used to succeed silently; a trailing `--checker` used to
  fall back to the builtin.
- **A finding computed from a cached peer snapshot is recomputed** against the
  peer's state right now before it is emitted, so a peer that has already withdrawn
  its edit no longer produces a warning for the length of the cache TTL.
- **`git config moire.checker` and `moire.link`** set the checker and linked
  directories once per clone, so every agent only types `moire verify`.
- **What observation writes, and where**
  ([README](README.md#what-observation-writes-and-where)) is newly documented. It
  was always the behaviour; it was never written down.
