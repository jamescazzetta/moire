# tools/replay-corpus

The Phase 1 measurement harness. It reconstructs co-active AI-agent pull
request pairs from a public corpus, replays each pair through `moire replay`,
and accounts for every pair that drops out on the way.

It is tracked in this repository because a published measurement that cannot
be re-run is not a measurement. The decision rule it feeds is in
[`PHASE1-PREREGISTRATION.md`](../../PHASE1-PREREGISTRATION.md), committed
before any data existed.

## What makes a judgement, and what does not

    this harness    fetches data, constructs pairs, counts attrition, and
                    compares the textual rate against the published one.
    moire replay    every judgement: the textual oracle, the merged tree, the
                    checker, the rename canonicalisation, the subtraction.

Nothing here re-implements the oracle or the subtraction. That is what lets
the method section read *"`moire replay` over corpus X"* rather than *"a
script we wrote, which we believe does the same thing as the tool"*. If you
are about to add something here that decides whether a pair is broken, it
belongs in `bin/moire`, behind a test in `tests/test_verify.sh`.

`tests/test_verify.sh` case V37 asserts the property that claim rests on:
`moire replay` and `moire verify` return the same verdict, the same merged
tree and the same breakage for the same pair.

## Requirements

Python 3.8+ and git 2.38+. **Standard library only** — no pandas, no
requests, no pyarrow, nothing to install. `bin/moire` is stdlib-only by
constraint; this harness is stdlib-only for a different reason, which is that
a reviewer should be able to run it on whatever machine they already have.

The corpus is read over HuggingFace's `datasets-server` JSON API rather than
by parsing parquet, which is what makes that affordable. (The design
originally priced a `pyarrow`/`datasets` dependency here; the JSON row API
made it unnecessary.)

## The corpus

[AIDev](https://huggingface.co/datasets/hao-li/AIDev) — agent-authored pull
requests scraped from GitHub. Measured 2026-08-12:

| config | rows | what it is |
| --- | --- | --- |
| `pull_request` | 33,596 | the scoped set (the harness default) |
| `all_pull_request` | 932,791 | aggregated across every agent |
| `repository` | 2,807 | repo metadata incl. `language` |
| `all_repository` | 116,211 | the same, aggregated |

`repository.language` is GitHub linguist's primary language and is the tier
signal — no clone needed. In the scoped table: 650 TypeScript repos, 530
Python, 242 Go, 220 C#, 190 JavaScript, 159 Rust.

A pair is **co-active** when two PRs in the same repository have overlapping
`[created_at, closed_at-or-merged_at]` intervals — Xu, Subramanian & Karthik's
definition (arXiv:2607.04697), replicated so that their published textual
conflict rates can serve as the calibration reference.

## Running it

Every stage caches to `cache/` (gitignored) and every stage is resumable,
because the full run is network-dependent and compute-bound and *will* be
interrupted.

```bash
python3 replay_corpus.py fetch-prs                    # ~336 API pages
python3 replay_corpus.py fetch-repos                  # ~28 API pages
python3 replay_corpus.py pairs --tier python --sample 500
python3 replay_corpus.py run --limit 50               # replay, resumable
python3 replay_corpus.py report
```

Tier 2 replaces the checker:

```bash
python3 replay_corpus.py pairs --tier typescript --sample 100 --out ts-pairs.jsonl
python3 replay_corpus.py run --pairs ts-pairs.jsonl --out ts-results.jsonl \
    --checker 'npm ci --silent >/dev/null 2>&1 && npx tsc --noEmit | sed -E "s/\([0-9]+,[0-9]+\)//"'
```

The install is **inside the checker command** on purpose. `moire replay` runs
the checker with its working directory set to each materialised tree in turn,
so `npm ci` there installs from *that tree's own lockfile* — self, peer and
merged each get their own. That is what the pre-registration means by "no
`--link`, no borrowing", and it is why the reproduced dependency-divergence
false positive is structurally absent from tier 2 rather than merely
controlled for.

Positions are stripped from `tsc` output because the finding text is the
identity: the same error at a shifted line number must cancel in the
subtraction, or every insertion above a pre-existing error would read as new
breakage.

Once `cache/` is populated the only network the harness needs is git itself,
so the fetch stages can be run somewhere with access and the cache carried to
wherever the compute is.

## What it does to other people's repositories

Nothing. Each repository is cloned **bare and blobless**
(`git clone --bare --filter=blob:none`) into `cache/repos/`, and PR heads are
fetched into `refs/moire/pr-<n>` **in that local clone only**. There is no
push, no write of any kind to GitHub, and no checkout. `moire replay` itself
writes no log, no cache and no snapshot — see `tests/test_verify.sh` V38,
which asserts HEAD, the index and the full ref set are unchanged after a
replay.

Blobless cloning means blobs are lazily backfilled during the replay, so the
replay stage needs network too.

## What a pilot run measured, 12 August 2026

24 tier-1 pairs, sampled with `--max-pairs-per-repo 2 --sample 24 --seed
20260812` from 8,530 candidate Python pairs across 159 repositories, on an
M-series MacBook. **This is a feasibility pilot: it is far below the
pre-registered minimum of 500 and produces no rate.**

| stage | count |
| --- | --- |
| pairs constructed | 24 |
| pairs attempted | 24 |
| repo unavailable | 0 |
| head unfetchable | 0 |
| no merge base | 0 |
| textual conflict | 3 |
| not checker-eligible | 1 |
| **evaluated** | **20** |

No pair reported breakage, which at n=20 means nothing either way.

**PR heads are reachable.** Zero attrition at the fetch stage here, and a
separate check of 834 dataset PRs across six repositories found
`refs/pull/<n>/head` present for all 834, including all 464 that were closed
without being merged. `git ls-remote <repo> 'refs/pull/*/head'` lists every
head in one unauthenticated call and is the cheap way to pre-check this.

**Cost.** Median 3.4 s per pair, max 88.8 s (`getsentry/sentry`); 24 pairs
replayed in 3.5 minutes of wall clock. Bare blobless clones of the 22
repositories totalled 1.0 GB.

**Monorepos are the exception, by two orders of magnitude.** One
`Azure/azure-sdk-for-python` pair took **603 s**: three materialised trees of
~877 MB and ~53,700 files each, of which builtin-ast parsed ~45,000 Python
files per tree. Note that `MOIRE_CHECKER_TIMEOUT` does **not** bound the
builtin checker — only external checker commands — so the harness's own
`--replay-timeout` is what stops such a pair, and it lands on the
`replay_timeout` rung where it can be counted.

**Calibration at pilot scale is noise, not a result.** The measured intra-agent
textual conflict rate was 13.0% (3 of 23) against a published 19.8%; three
conflicts versus the ~4.6 expected is well inside binomial noise at n=23. The
cross-agent cell had n=1 and no signal at all. Neither number should be read
as agreement or disagreement — the gate is meaningful only at full scale.

**The cross-agent cell is structurally thin.** Of 8,530 tier-1 candidate pairs,
8,372 are intra-agent and only 158 (1.9%) cross-agent, because the scoped
`pull_request` table is dominated by one agent. The published 41.7% cross-agent
rate therefore has little support in this population; a run that wants to
calibrate against it should use `all_pull_request`.

**Run it with disk and memory headroom.** Three trees of a large repository are
materialised at once, and anything that truncates them mid-run makes the
checker under-count silently. `moire replay` now refuses to call a merged tree
"nothing to check" when its parents were non-empty, which converts that failure
into a visible error rather than a pair that quietly leaves the denominator.

## Attrition

The pre-registration requires the ladder be published with every drop counted:

    candidate_pairs -> repo_unavailable -> head_unfetchable -> no_merge_base
                    -> textual_conflict -> not_checker_eligible -> evaluated

`report` prints it. Each pair stops on exactly one rung, and the rung is
stored on the record when the pair is replayed rather than recomputed at read
time, so the table cannot drift from the records it summarises.

The largest known risk is `head_unfetchable`: GitHub keeps
`refs/pull/<n>/head` after a PR closes but does not promise to, and a
repository can be deleted or made private at any time. It is a counted stage
rather than an exception for that reason.

## What `report` will not do

`report` **withholds the semantic rate** unless all three hold:

1. at least 500 evaluated pairs (the pre-registered minimum),
2. `--calibration-passed`, and
3. `--audited`.

The pre-registration says *"gross divergence means our pair construction is
wrong"* and deliberately does not quantify "gross". This harness therefore
does not invent a threshold and does not decide the gate: it prints the
measured intra/cross textual rates next to the published 19.8% / 41.7% and
requires a human to affirm the comparison. Likewise it will not report an
unaudited breakage count as a rate — the audit is what separates true
collisions from relocated pre-existing breakage, checker artifacts and
environment artifacts, and only the true-collision count feeds the decision
rule.

Until then `report` prints the attrition table, the calibration comparison,
and the audit table with every hit `UNCLASSIFIED` and a two-line reproduction
attached.
