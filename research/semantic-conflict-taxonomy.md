# The causes of semantic merge conflict — a map

Compiled 13 August 2026. `research/landscape.md` already carries the **frequency**
layer (how often higher-order conflicts happen). It has no taxonomy of **causes** —
what kind of program fact actually breaks. That is this document.

Every row carries how well it was verified. This project has retracted misattributed
statistics twice; an uncited number is worse than no number, and a
secondhand one that looks firsthand is worse still.

## 0. Vocabulary, first, because moire's own docs walk into a collision

The literature does **not** treat "build", "higher-order", "dynamic" and "semantic" as
synonyms.

- **Brun, Holmes, Ernst & Notkin (ESEC/FSE 2011)** use **higher-order** as the umbrella
  over *both* build and test failures.
- **da Silva, Borba et al. (arXiv:2310.02395)** reserve **semantic conflict** for the
  *behavioural/test* layer specifically, and place a separate, lower **build conflict**
  layer beneath it: merge conflicts → build conflicts → test and production conflicts.

moire's own materials collapse these. **moire's checker operates at the build layer,
not the behavioural layer.** That distinction decides most of what follows.

## 1. The build layer (static)

| # | Category | What breaks | Source | Verification |
|---|---|---|---|---|
| **A1** | Unavailable Symbol — missing class/module | Reference to a declaration the other branch deleted or renamed | da Silva, Borba & Pires, *JSEP* 34(4):e2441, 2022, DOI 10.1002/smr.2441, Table 3 | PDF fetched directly |
| **A2** | Unavailable Symbol — missing method/variable | Same mechanism, different declaration kind | same | PDF fetched directly |
| **A2b** | …reached by **attribute access** after a plain `import M` | `M.foo()` where `foo` was removed; the *import* still resolves | not an academic split — drawn to describe moire's mechanism precisely | own analysis, labelled as such |
| **A3** | Unimplemented Method | One branch adds an interface method, the other adds an implementing class unaware of it | da Silva et al. 2022 (5.02%); corroborated as "super-sub" by Shen, Gulzar, He & Meng, *TOSEM* 32(2):40, 2023, DOI 10.1145/3546944, §5.1.1(b) | both PDFs fetched |
| **A4** | Duplicated Declaration | Both branches independently add the same-named entity | da Silva et al. 2022 Table 3; Shen et al. 2023 §5.1.3 | both PDFs fetched |
| **A5** | Incompatible Method Signature | Call site not updated when the callee's signature changed elsewhere | da Silva et al. 2022 Table 3 | PDF fetched |
| **A6** | Incompatible Types | Type mismatch, often via a transitive dependency bump changing a return type | da Silva et al. 2022 Table 3 | PDF fetched |
| **A7** | Project Rules | Lint/licence/style failure — da Silva et al. explicitly classify this as *not* a static-semantic conflict | da Silva et al. 2022 Table 2/3 | PDF fetched |
| **A8** | Version-version | One branch bumps a declared dependency version, the other still references the old string in a manifest | Shen et al. 2023 §5.1.1(c) | PDF fetched |
| **A9** | Dependency-code | One branch upgrades a library, the other calls an API only the old version had | Shen et al. 2023 §5.1.1(d) | PDF fetched |

## 2. The behavioural layer (dynamic)

Categorically beyond any static resolver — these require execution.

| # | Category | What breaks | Source | Verification |
|---|---|---|---|---|
| **B1** | Divergent Updates (Type I interference) | Base, left and right disagree on a shared state element's final value | Lira, Borba, Bonifácio, Santos & Barbosa, arXiv:2510.01960, Oct 2025, §2.1 (formalising Horwitz et al.) | PDF fetched |
| **B2** | Non-preserving Integration (Type II) | One branch's change to a state element is silently dropped by the merge | same | PDF fetched |
| **B3** | Emergent Divergence (Type III) | Neither branch touches a value; the merge changes it anyway | same | PDF fetched |

## 3. Frequency — which causes actually occur

| Source | Population | Finding |
|---|---|---|
| da Silva, Borba & Pires 2022 | 451 projects, 57,065 merge scenarios → **65 (0.11%)** with a confirmed build conflict → 239 instances | **Unavailable Symbol 65.70%** (157/239); Incompatible Method Signature 10.88%; Project Rules 9.20%; Incompatible Types 7.11%; Unimplemented Method 5.02%; Duplicated Declaration 2.09%. Missing-*class* is 73% within Unavailable Symbol → ≈**46.9%** of all build conflicts |
| Shen, Gulzar, He & Meng 2023 | 208 repos; 15,886 scenarios hit textual conflicts, **79** hit build conflicts, **33** hit test conflicts | **99 of 107** inspected build conflicts (**92.5%**) reduce to two edit patterns that break def-use links — a name stopped resolving |
| Brun, Holmes, Ernst & Notkin 2011 | Git / Perl5 / Voldemort | Within higher-order, the **dynamic layer (6% avg, 3–28%)** outweighs the **static/build layer (~1% avg)** — the layer moire cannot reach is reported as the larger one. Shen et al.'s 79-vs-33 points the other way; **no single paper resolves this** |
| Schesch et al., ASE 2024, arXiv:2410.09934 | 6,045 Java merges, both parents green | **5.4%** of textually clean merges failed compile *or* tests |
| da Silva et al. 2023 (SAM) | 51 merge scenarios, 28 confirmed-interference cases | SAM caught **9/28 (32%)** — a **tool recall figure on a small labelled sample, not a base rate.** Do not cite as "32% of merges have dynamic conflicts" |

**Weaker verification, flagged:**
- **Bucond** (Towqir, Shen, Gulzar & Meng, ASE 2022, DOI 10.1145/3551349.3556950) — the
  closest prior *tool* to moire at the build layer: "57 patterns, covering 97% of the
  build conflicts", 100% precision, 88–100% recall on their sample. **Abstract only,
  via Semantic Scholar API.**
- **Sung, Lahiri, Kaufman, Choudhury & Wang** (ICSE-SEIP 2020, DOI 10.1145/3377813.3381362),
  "398 build conflicts" in one C++ project over three months — **secondhand, relayed
  through da Silva et al. 2022's literature review. Not independently fetched.**
- **Mens**, "A State-of-the-Art Survey on Software Merging", *IEEE TSE* 28(5), 2002,
  DOI 10.1109/TSE.2002.1000449 — origin of the textual/syntactic/semantic split.
  **Journal PDF paywalled; quoted only through the author's own lecture slides.**
- **Chacón Sartori**, arXiv:2603.24284, March 2026 — AI agents implementing stub methods
  of a shared class against an under-specified contract. PDF fetched, **but it is not a
  git-merge study**: no VCS, no independent base branches. Structurally adjacent, not an
  instance. Its numbers must not be blended into the merge-conflict frequency picture.

**No source measures semantic or build conflict rates among concurrent AI coding
agents' git merges.** Only *textual* rates exist for that population (AgenticFlict; Xu
et al.), already in `landscape.md`. That gap is what Phase 1 was designed to fill, and
it is still open.

## 4. Coverage — what moire's builtin checker can reach

The checker resolves import names over `ast`. Scoped to the build layer, since that is
the layer it operates in:

| # | Detectable in principle? | Covered by a fixture? |
|---|---|---|
| A1 | **Yes** — this is precisely `from M import N` / `import M.N` / `import M` resolution | P1, P2, P3, P4, P8 |
| A2 | **Yes**, same mechanism | P5, P6 |
| A2b | **No** — `import M` asserts only that M is a module; attribute resolution is a materially larger mechanism | gap |
| A3 | No — Python has no compile-time interface conformance to hook | gap (arguably N/A to Python) |
| A4 | No — and invisible to the CPython ground truth too: a second definition silently shadows the first, raising nothing | gap, unfixable within this benchmark's methodology |
| A5 | No — no arity checking | P7, a **declared** miss |
| A6 | No — no type system | gap |
| A7 | No — and out of scope by the source taxonomy's own definition | gap |
| A8 | No — the checker does not parse manifests | adjacent to N1/N2 |
| A9 | No — third-party modules are deliberately withheld | adjacent to N1/N2 |

**Sized: of nine literature-defined build-layer categories, one (A1/A2, which the
checker does not internally distinguish) is detectable in principle — and it is the one
covered.** Six of the remaining eight are out of reach of *any* implementation of an
import-name resolver, not of this implementation. Adding the behavioural layer, the
ratio across the full higher-order landscape is **1 of 12 named categories detectable in
principle, 1 of 12 covered.**

## 5. What this means for the "7 of 8" claim

"7 of 8" means: the checker resolves **seven structural variants of one category** —
deletion, `git mv`, package rename, plain vs relative import, name-level vs
module-level — plus one declared out-of-reach miss. That is a real robustness result;
those variants are exactly where a naive resolver breaks, and catching all of them is
engineering signal.

It is **not** a recall measurement against the domain, and must not be published as
one.

The honest form, which is neither the good news nor the bad news alone:

> Of the one category of build conflict that a static import resolver can address at
> all, the checker catches it across seven tested structural variants. That category is
> empirically the single largest cause of build conflicts in both corpora that measure
> causes — 65.7% of instances (da Silva et al. 2022) and 92.5% of inspected conflicts
> reducing to broken def-use links (Shen et al. 2023). But it is bounded above by
> roughly a third to a half of build-layer breakage even in the best case, and the
> build layer is itself only part of higher-order conflict — per Brun et al., possibly
> the smaller part.

## 6. What the map changes about Phase 1

Composing §3 for the category moire can actually reach gives a prior of roughly
**0.07%–0.6%**. `PHASE1-PREREGISTRATION.md` retires `verify` below **0.5%**.

The threshold sits inside the prior's range, near its top. The pre-registered rule is
therefore closer to a weighted coin-flip toward retirement than to a test of whether
moire works — a result in the retire band is the *expected* outcome of measuring a
genuinely rare phenomenon with a correctly built instrument, and the rule cannot
distinguish that from failure.

This is external evidence, published, and independent of any data this project holds.
It is the one kind of ground on which amending a pre-registration before data
collection is legitimate rather than self-serving.
