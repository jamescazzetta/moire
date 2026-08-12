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
