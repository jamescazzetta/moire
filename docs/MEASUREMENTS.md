# Measurements, provenance, and the public record

Every number the [README](../README.md) states is either measured by this project or
cited to a primary source. This page is the ledger: how each measurement was taken,
what each score does and does not mean, the citation table with every denominator,
what this project tried and threw away, and the corrections it has had to make to
its own record. Nothing here is softened; it is filed.

## How the cost table was measured

Measured 2026-08-12. A purpose-built lab repository: 62 tracked `.py` files in a
chain of imports, three peer worktrees, each peer holding one committed and one
uncommitted edit. Median of 15 runs per cell, wall clock of the whole process.
*Warm* means the peer-snapshot cache hits (`MOIRE_CACHE_TTL=3600`); *cold* means it
never does (`MOIRE_CACHE_TTL=0`), so all three peers are re-snapshotted every run.
`verify` used the default `builtin-ast`, which reported `examined 62 of 63 files -
python only` on every run.

The machine — an Apple M1 MacBook Pro (`MacBookPro17,1`), macOS 15.7.3, Python
3.8.2, git 2.55.0 — carried load averages between 10.19 and 11.44 across the run,
on 8 cores. An idle machine will be faster; nothing here will be slower — which is
why the README publishes the table as a **ceiling**, not a figure. For scale on the
same machine and the same loading, `python3 -c pass` took 21 ms.

**Object-store behaviour.** Snapshots are content-addressed, so re-checking an
unchanged worktree writes no objects at all: in the same lab, 20 consecutive checks
against 3 peers with the cache disabled added **zero** loose objects. Observing a
genuinely *new* state does write objects — that is intrinsic, not overhead — and
those are refless and swept by git's own housekeeping, which normal commit and fetch
activity already triggers. moire never deletes an object; `moire doctor` warns if
loose objects ever accumulate past git's own `gc.auto` threshold.

## What the test suites can and cannot prove

`test_oracle.sh` is the suite with the strongest ground truth: it performs a real
`git merge` in a throwaway copy and compares moire's verdict against what git
actually did. `test_verify.sh` case 31 — the rename regression — is the one semantic
case that computes its ground truth without moire: it runs `git merge-tree
--write-tree`, unpacks the result with `git archive`, and asserts the broken import
*is* present at the renamed path, so that silence counts as correct only if the tool
saw the breakage and attributed it to the right side. The other semantic cases
assert against moire's own JSON, which is weaker, and is stated here rather than
glossed.

`tests/benchmark_recall.sh` is the answer to that weakness, and it asks a different
question from the suites: not whether the mechanism behaves as specified, but how
much of a real collision it sees. Eighteen textually clean fixtures — a deleted
module, a `git mv`, a package rename, a removed name, a broken `__init__.py`
re-export, a dotted submodule import, a changed signature, an attribute removed from
a surviving module, a name one side supplies for the other, a namespace package, and
the third-party imports that must never fire — are graded by materialising the same
three trees and **importing every module in each with CPython**, then subtracting
the interpreter's errors exactly as moire subtracts its own. Nothing in it consults
moire's verdict. Measured 2026-08-13: **9 of 11** confirmed collisions caught and
**0 of 7** clean merges reported, against **4 of 11** and 0 of 7 for the checker one
release earlier (`git show febc36b:bin/moire`).

## What 9 of 11 measures

**It is a robustness score inside one category, not a recall measurement over the
domain, and it should not be quoted as the second thing.**

The literature that classifies *causes* of build-layer breakage names nine of them.
An import-name resolver can reach exactly one — **Unavailable Symbol**, a reference
to a declaration the other side deleted or renamed. The other eight (duplicated
declaration, incompatible types, unimplemented interface method, changed signature,
dependency-version skew, dependency-code mismatch, project rules) are out of reach
of *any* implementation of this mechanism, not of this one. Add the behavioural
layer — interference between branches that both compile — and it is one of twelve.

So the eleven positives are **nine structural variants of a single category** plus
two declared out-of-reach misses. The variants are where a naive resolver actually
breaks — `git mv`, package rename, relative imports, re-export chains — so catching
them is real signal about the implementation. It is not evidence about coverage of
the problem.

The mitigating half, which is equally measured: that one category is the **single
largest cause** of build conflict in both corpora that count causes. da Silva, Borba
& Pires ([*JSEP* 34(4):e2441, 2022](https://doi.org/10.1002/smr.2441)) found
Unavailable Symbol to be **65.7%** of 239 conflict instances across 57,065 merge
scenarios; Shen, Gulzar, He & Meng
([*TOSEM* 32(2):40, 2023](https://doi.org/10.1145/3546944)) found **99 of 107**
inspected build conflicts reduce to edits that break def-use links — a name that
stopped resolving. The checker targets the right category; it simply cannot claim
the domain.

The full map, with each source's verification status, is in
[`research/semantic-conflict-taxonomy.md`](../research/semantic-conflict-taxonomy.md).

## The finding-to-conversation lab, verified end to end

The `pending` and `compose` output in the README was produced 2026-08-13 in a
two-worktree lab repo holding the README's own disjoint-edit example — agent A
renamed `validate_session` and had not committed, agent B committed a new file
calling the old name. Three properties were verified in that run rather than
asserted:

- **Both sides compute the same finding id.** Agent B's own `moire verify`, run from
  the other worktree, reported `[finding c7c86b514435]` for the same pair — the id
  is derived from the two worktree paths and the contested paths or breakage, never
  from anything either side declares.
- **The arbiter reads correctly from both ends.** A's record said `self yields`; B's
  own run printed `arbiter: peer yields` for the identical fact — the same
  recommendation, opposite label, which is why `compose` translates it to *the
  sender (this side)* / *the receiver (your side)* before it crosses the boundary.
- **`compose` refuses to speak from the other side's record.** In a second lab where
  only B had logged the finding, composing that id from A's worktree refused with
  exit 2 — *"finding '…' was recorded from another worktree's runs, not this
  one's"* — because rendering the peer's record would name the receiver as the
  sender.

A suite case additionally pins that `pending` and `compose` write nothing, by
fingerprinting every file under `.git/moire/` around five invocations and asserting
the fingerprints identical.

## What this project tried and threw away

Three mechanisms were designed here and then abandoned on evidence:

- **A declared-intent ledger with a model classifying whether two intents were
  compatible** — dropped once the measurements on declared-intent coordination
  landed.
- **A line-range overlap predicate.** 24.1% recall as first specified. Corrected to
  100% recall, but precision swung from **88.4%** on one repository to **36.6%** on
  another, because it only *approximates* git's merge condition. Replaced by asking
  git directly.
- **A symbol-matching heuristic** to catch the semantic case from diffs alone.
  Tested against a corpus of real clean merges *before* implementation: 24 fires,
  **0 true positives** — every one a regex artifact, including English prose in a
  docstring matching a definition pattern. Killed before a line was written.

**A retraction about that last one.** This project's README used to give the
denominator as "2,347 concurrent pairs" across flask, click, rich, requests, pytest
and httpx. That number is withdrawn. The only corpus table this project ever
recorded puts those six repositories at **2,017** concurrent pairs in total — 315
click, 273 flask, 787 rich, 355 pytest, 272 requests, 15 httpx — and clean merges
are a strict subset of concurrent pairs, so 2,347 exceeds its own population by
330. No recorded run reproduces it. The denominator could not be reconciled and is
therefore unpublishable, and it is withdrawn rather than adjusted to a number that
would look tidier.

**The finding survives the denominator.** 24 fires and 0 true positives is a count
of the numerator, and it is unaffected. The same table corroborates the direction
independently: pytest (355 concurrent pairs), requests (272) and httpx (15)
produced **zero** file conflicts between them, and four of the seven repositories
sampled produced no concurrent conflicts at all. Conflict frequency is a property
of a repository, not a constant.

The tool is what survived all of that.

## A note on the numbers

**Not every figure is measured on this machine — the external citations never
could be.** Each figure is one of three things, and which one is always stated:

**1. Measured here, on an Apple M1 MacBook Pro** (`MacBookPro17,1`, macOS 15.7.3,
Python 3.8.2, git 2.55.0). On 2026-08-12: the cost table and its 21 ms process
floor; the 62-of-63-files checker coverage; the zero loose objects over 20 idle
checks; the object-store observations behind the README's
[what observation writes](../README.md#what-observation-writes-and-where); both
Clash reproductions. On 2026-08-13: the 110 test cases and their 109/1/0 outcome,
the negative control's 10 of 10, the `pending` and `compose` output and the
two-worktree lab it was run in, and the recall benchmark's 9-of-11 and 4-of-11
scores with 0 of 7 false positives, the last of these after three fixtures were
added for shapes the suite had never exercised.

**2. Measured by this project earlier, on other machines, and labelled as such.**
The abandoned predicates' numbers (24.1% recall; 100% recall at 88.4%/36.6%
precision; 24 fires and 0 true positives) and the per-repository pair counts come
from this project's own working notes, which are **not published in this
repository** — so treat them as this project's word, not as something you can check
here. Where one of them could not be reconciled it has been withdrawn rather than
kept (above). The **git ≥ 2.38** floor comes from this project's direct testing:
the older three-argument `git merge-tree` reports *clean* for rename/rename,
modify/delete and binary-vs-binary conflicts that a real merge rejects. A detector
with silent blind spots is worse than no detector, so `moire` refuses to run below
that version rather than degrade.

**3. Cited to a primary source, with its scope attached.** Every external number
below was taken from the paper or report itself, and its denominator travels with
it:

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
| **1.9% vs 4.4%** | AI-assisted PRs broke main less often than PRs with no detectable AI assistance, across 200,000+ merges from 477 teams. See the strongest argument against this project, below | Mergify, *State of Merge Queues 2026* |

**The 9.3% arithmetic, shown.** Brun et al.'s Figure 4, re-read from the PDF for
this ledger, gives per system: Git 1,362 merges = 227 textual-fail + 2 build-fail +
53 test-fail + 1,080 clean-and-passing; Perl5 185 = 14 + 7 + 51 + 113; Voldemort
147 = 25 + 15 + 5 + 102. Every row sums to its own merge count. Totals: 1,694
merges, 266 textual, 24 build, 109 test. Textually clean = 1,694 − 266 = **1,428**;
broken among them = 24 + 109 = **133**; 133 / 1,428 = **9.3%**. ⚠️ The widely-quoted
*"33% of clean merges"* is a misreading of a sentence the paper itself got wrong:
399 is the count of *conflicting* merges (266 + 24 + 109), so 133/399 = 33% is
higher-order conflicts as a share of **all conflicts**, not of clean merges. Do not
cite 33%. Note also that this covers only 3 of the paper's 9 systems — the six
others had no test suite the authors could run — and that the paper's own prose
says "5,355 merges" where Figure 4 sums to 1,694, unreconciled; cite the table.

## Two corrections to this project's public record

**A retraction of a retraction.** This project previously published the figures
**41.7%** and **19.8%** for cross-agent versus intra-agent conflict, then retracted
them as fabricated after confirming they appear nowhere in
[arXiv:2604.03551](https://arxiv.org/abs/2604.03551). The confirmation was correct.
**The conclusion was wrong.** The figures are real; they belong to a *different*
paper. Xu, Subramanian & Karthik,
[arXiv:2607.04697](https://arxiv.org/abs/2607.04697), state in their abstract, and
this was re-checked against arXiv directly: *"the percentage of textual conflict
encountered was significantly higher for cross-agent pairs compared to intra-agent
pairs: 41.7% vs. 19.8%, respectively, with non-overlapping 95% confidence
intervals"* — from replaying three-way merges over 747 co-active pairs.
arXiv:2604.03551 is a different dataset entirely (AgenticFlict, Ogenrwot & Businge:
27.67% across 107K+ merge-simulated agent PRs, PR-vs-base). What went wrong was
**misattribution, not fabrication** — the right numbers filed under the wrong
paper — and the correction runs in this project's favour, which is exactly why it
is stated plainly rather than quietly fixed.

**A retraction that stands.** "2,347 concurrent pairs" is withdrawn and not
restored; see [what this project tried and threw
away](#what-this-project-tried-and-threw-away). Also removed without replacement:
contributor and download counts for MCP Agent Mail that appear in no research note
here; a Claim Plane restatement that dropped caveats the project's own notes say
must not be dropped; and a CooperBench token-budget figure that came from the same
paragraph of the same document as four statistics this project had already proven
to be fabrications.

## The strongest argument against this project

State it rather than omit it. Mergify's *State of Merge Queues 2026* reports that
across 200,000+ merges from 477 teams, **AI-assisted PRs broke main 1.9% of the
time against 4.4% for PRs with no detectable AI assistance.** If AI-authored
changes are *safer* at integration than human ones, the premise that agents
specifically need new integration safety is weakened. Three caveats partly defuse
it and none of them dissolves it: AI assistance is detected from commit signatures,
which the report itself calls a floor; "AI-assisted" means human-supervised PRs,
not autonomous parallel agents; and it is a vendor report on its own customers, a
population that already runs a merge queue. The same report finds broken-main
scaling with concurrency, from about 0.77% at 2–5 engineers to 12.5% at 40+ —
which cuts the other way.

These are one person's measurements plus other people's published work. They are
stated precisely so that they can be contradicted.
