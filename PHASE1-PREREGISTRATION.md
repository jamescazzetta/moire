# Phase 1 — pre-registration

**Written 12 August 2026, before any data was collected.** Committed deliberately so the
decision rule cannot be adjusted after the result is known. If this file's git history shows
it changed after the first replay run, treat every number downstream of it as unregistered.

## The question

Among **textually clean** concurrent AI-agent pull-request pairs — pairs that `git merge` would
combine without conflict — what fraction is **semantically broken by the combination**?

This is the number `moire verify` exists to justify. Nothing else decides its fate.

## The decision rule

Replay **at least 500 textually clean co-active pairs**. Every reported breakage is manually
audited and classified into exactly one of:

- **true collision** — the combination genuinely broke something neither side broke alone
- **relocated pre-existing** — one side's own breakage, moved by the other side's rename
- **checker artifact** — nondeterminism, absolute paths, position drift, summary lines
- **environment artifact** — missing dependency, install failure, toolchain difference

Then, on the **audited true-collision rate across both tiers combined**:

| Rate | Outcome |
| --- | --- |
| **< 0.5%** | `verify` is **retired as a live product feature.** The hook and skill instructions to run it are removed. The mechanism survives only as `moire replay`, a measurement instrument. The README says exactly that. |
| **0.5% – 2%** | `verify` ships **opt-in**, with the measured number attached to every claim about it. |
| **> 2%** | `verify` is the **headline**. |

**A zero in the Python tier alone does not trigger the kill.** Import resolution is one narrow
failure mode — the same one the project's earlier search of human history covered, and the same
narrowness that made that search uninformative. The TypeScript tier must also be at or near zero
before `verify` is retired.

## Population and tiers

**Tier 1 — Python, `builtin-ast`.** Zero setup, no dependencies, structurally conservative about
false positives. Measures import-level breakage only. That scope is stated in every published
sentence about the result.

**Tier 2 — TypeScript, `tsc --noEmit` with positions stripped.** Capped at roughly the 100 most
feasible pairs; compute-bound. Dependencies are installed **per materialised tree** — self, peer
and merged each get their own install from their own lockfile. No `--link`, no borrowing.

An install that succeeds on both parents and fails on the merged tree is recorded as a
**dependency-level new breakage in its own category**, never folded into the checker rate.

## Contamination controls

Two false-positive classes were reproduced in this repository on 12 August 2026 and fixed in
commit `2edce48` before this measurement was designed. Both are controlled for:

- **Rename relocation** — one side's own breakage relocated by the other's `git mv`. Fixed by
  rename canonicalisation, which is active inside `replay`. The audit additionally classifies any
  survivor whose path appears as a rename target in the recorded rename maps.
- **Dependency divergence** — a borrowed dependency directory making the merged tree unbuildable.
  Structurally absent here: tier 2 installs per tree, tier 1 uses no links at all.
- **Ambient breakage** — handled by the subtraction itself. `self_broken` and `peer_broken` counts
  are recorded per pair so the audit can check it.
- **Nondeterminism** — when a breakage is found, the merged-tree checker runs three times. A
  finding that does not appear in all three runs is discarded and logged.

## Calibration — the run is void if this fails

Before any semantic number is read, the harness's **textual** conflict rate over the same pair
population is compared against the published rates for the same corpus (Xu, Subramanian &
Karthik, arXiv:2607.04697: 19.8% intra-agent, 41.7% cross-agent).

Gross divergence means our pair construction is wrong, not that we have discovered something.
Fix the construction and re-run before interpreting anything.

## What gets published, regardless of outcome

1. This file, unmodified.
2. The attrition table: candidate pairs → fetchable → merge-base found → textually clean →
   checker-eligible. Every drop counted, none silent.
3. The audit table: every hit, its classification, and a two-line reproduction for each true
   positive.
4. The number, phrased with its scope attached — *"X% of N textually clean co-active agent PR
   pairs, import-level (Python) and type-level (TypeScript) checkers, audited; measures these
   failure modes and not others."*
5. The keep-or-retire decision, executed.

**A null result is a publishable result.** If the rate is below 0.5%, that is a finding about
concurrent agent work that two recent papers left unmeasured, and it is worth publishing even
though it removes this project's only unique mechanism.

## Why this file exists

This project has retracted published numbers before. The failure mode being guarded against here
is not fabrication — it is the quieter one where a threshold moves a little once the data is in,
or a tier is dropped because it came out inconvenient, and everything downstream stays defensible
one small step at a time.

The rule above is fixed. The data decides.

---

## Amendment 1 — 18 August 2026, before any Phase 1 data

**Standing.** The rule above says a change after the first replay run voids what
follows. No Phase 1 replay has run: `research/phase1-results/` is empty, and the
only replays to date are the 24-pair feasibility pilot of 12 August 2026 (20
evaluated, declared uninformative at that n in `tools/replay-corpus/README.md`).
"First replay run" is defined, from here on, as the first replay of the Phase 1
corpus itself — the pilots were feasibility checks of the harness, not data. This
amendment rests on external evidence — published literature, not anything this
project has measured — and it commits to being the last: any change to this file
after the first Phase 1 replay run, including to this amendment, voids the
registration.

Three changes. None of them moves a threshold.

### A1.1 — A sensitivity gate, symmetric with the calibration gate

The original design controls false positives four ways and false negatives not at
all: a near-zero result cannot distinguish "the phenomenon is rare" from "the
instrument is blind". That is not hypothetical. Six days before this amendment the
builtin checker scored 2 of 8 on collisions CPython confirms on the merged tree,
and nothing in this study design would ever have caught it.

Before any semantic number is read: `tests/benchmark_recall.sh` — which grades
every fixture with the real interpreter and never consults moire's verdict — must
pass at its recorded floor **using the exact binary that replayed the corpus**, and
that binary's commit hash is recorded in the published results. Failure voids the
run, exactly as calibration failure does. This gate can only ever void a run;
nothing in it can rescue one.

### A1.2 — Per-tier rates are primary; the pooled rate is reported, not decisive

Pooling ≥500 Python pairs with ~100 TypeScript pairs lets the weakest checker
outvote the strongest five to one, and forces the TypeScript tier to clear roughly
4% before the pool clears 0.5%. The original text recognised the problem ("a zero
in the Python tier alone does not trigger the kill") but left "at or near zero"
undefined. Defined now:

- The audited true-collision rate is computed and published **per tier**, each
  with a Clopper–Pearson 95% interval. The pooled rate is published for
  completeness and decides nothing.
- The decision table applies per tier, and `verify`'s fate is the strongest band
  any tier reaches: **headline** if any tier exceeds 2%; **opt-in, number
  attached** if any tier lands in 0.5–2%; **retired** only if **every** tier is
  below 0.5%. Every published claim carries its tier's scope.
- Decisions follow the point estimates, exactly as the original table did. The
  intervals are published to be read, not to move the rule: an underpowered tier
  must not become an escape hatch, so a tier that reaches its pre-registered
  minimum (500 Python, 100 TypeScript) is decided on its point estimate, with its
  interval traveling alongside the claim.

### A1.3 — The prior, stated next to the threshold it judges

The 0.5% threshold is unchanged. What changes is that the reader gets the number
the literature puts beside it (compiled with sources and verification status in
`research/semantic-conflict-taxonomy.md` and `docs/MEASUREMENTS.md`):

- **5.4%** of textually clean human Java merges failed compile or tests
  (Schesch et al., ASE 2024; 6,045 merges, both parents green).
- **0.11%** of merge scenarios carried a confirmed build conflict, and **65.7%**
  of those instances are Unavailable Symbol — the one category an import resolver
  can reach (da Silva, Borba & Pires, JSEP 2022; 57,065 scenarios).
- Composed for the category the Python tier's checker can see: roughly
  **0.07%–0.6%** — a range that spans the kill line.

Stated plainly, ahead of the data: **a Python-tier result in the retire band is
the expected outcome under this prior.** If it lands there, the rule executes
anyway. The point of publishing the prior is that a retirement will then read as
what it is — a rare phenomenon, as the literature predicted, measured by an
instrument whose sensitivity was proven by gate A1.1 — rather than as a failed
tool. The prior's caveats are real and travel with it: it composes Java corpora
onto Python, human merges onto agent merges, and all-scenario denominators onto
textually-clean-pair denominators. It is an order-of-magnitude prior, not a
calibration.
