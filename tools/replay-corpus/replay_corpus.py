#!/usr/bin/env python3
"""replay_corpus.py - the Phase 1 measurement harness.

Reconstructs co-active AI-agent pull-request pairs from a public corpus,
replays each pair through `moire replay`, and accounts for every pair that
falls out along the way.

The division of labour is deliberate and load-bearing:

    this script   fetches data, constructs pairs, counts attrition, and
                  compares the textual rate against the published one.
    moire replay  makes every judgement - the textual oracle, the merged
                  tree, the checker, the rename canonicalisation, and the
                  subtraction.

Nothing here re-implements the oracle or the subtraction. That is what lets
the published method section read "moire replay over corpus X" instead of
"a script we wrote, which we believe does the same thing". If you find
yourself about to add a heuristic here that decides whether a pair is
broken, put it in bin/moire instead, behind a test.

Stdlib only, Python 3.8 - no pandas, no requests, no pyarrow. That is a
harder constraint than the binary strictly needs, and it buys one thing:
this runs on any machine with a python3 and a git, including whatever
machine a reviewer reaches for, with no install step to get wrong. The
corpus is read over HuggingFace's datasets-server JSON API rather than by
parsing parquet, which is what makes that affordable.

Every stage caches to disk and every stage is resumable, because the full
run is compute-bound and network-dependent and will be interrupted.

    python3 replay_corpus.py fetch-prs                 # cache the PR table
    python3 replay_corpus.py fetch-repos               # cache repo metadata
    python3 replay_corpus.py pairs --tier python       # construct pairs
    python3 replay_corpus.py run --limit 20            # replay them
    python3 replay_corpus.py report                    # attrition + audit

See README.md for what each stage costs and what it writes.
"""

import argparse
import json
import os
import random
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from collections import OrderedDict
from datetime import datetime

HF_ROWS = "https://datasets-server.huggingface.co/rows"
HF_SIZE = "https://datasets-server.huggingface.co/size"
DATASET = "hao-li/AIDev"

# Xu, Subramanian & Karthik (arXiv:2607.04697), the paper whose 747 co-active
# pairs this construction replicates. PHASE1-PREREGISTRATION.md makes a
# comparison against these two rates a precondition for reading any semantic
# number. They are constants here so the calibration line cannot quietly
# acquire a different reference after the data is in.
PUBLISHED_TEXTUAL = {"intra": 19.8, "cross": 41.7}

# PHASE1-PREREGISTRATION.md: "Replay at least 500 textually clean co-active
# pairs." Also a constant, for the same reason.
PREREG_MIN_CLEAN_PAIRS = 500

DEFAULT_CACHE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "cache")


# ------------------------------------------------------------------ plumbing

def log(msg):
    sys.stderr.write("%s\n" % msg)
    sys.stderr.flush()


def http_json(url, params=None, timeout=60, retries=7):
    """GET a JSON document, with backoff. -> dict, or raises RuntimeError.

    Degrades honestly: a network that is not there produces one clear
    message naming the URL, not a traceback and not an empty result that a
    later stage would mistake for "the corpus contains nothing".

    The datasets-server rate-limits per client, and a full fetch is thousands
    of requests, so 429 is an expected part of normal operation rather than
    an error: honour Retry-After when the server sends one, and otherwise
    back off exponentially to a minute. Everything is resumable, so the worst
    case of giving up is a rerun.
    """
    if params:
        url = url + "?" + urllib.parse.urlencode(params)
    last = None
    for attempt in range(retries):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "moire-replay-corpus"})
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                return json.loads(resp.read().decode("utf-8"))
        except urllib.error.HTTPError as ex:
            last = "HTTP %s %s" % (ex.code, ex.reason)
            # 429/5xx are worth waiting out; a 404 or 400 never is.
            if ex.code not in (429, 500, 502, 503, 504):
                break
            wait = None
            try:
                wait = float(ex.headers.get("Retry-After") or 0) or None
            except (TypeError, ValueError):
                wait = None
            if wait:
                time.sleep(min(wait, 120))
                continue
        except Exception as ex:                    # URLError, socket timeout, bad JSON
            last = "%s: %s" % (type(ex).__name__, ex)
        if attempt < retries - 1:
            time.sleep(min(2 ** attempt, 60))
    raise RuntimeError("could not fetch %s (%s)" % (url, last))


def run_git(args, cwd=None, timeout=1800):
    """-> (rc, stdout, stderr). Never raises on a nonzero git."""
    try:
        p = subprocess.Popen(["git"] + args, cwd=cwd, stdout=subprocess.PIPE,
                             stderr=subprocess.PIPE)
        out, err = p.communicate(timeout=timeout)
        return p.returncode, out.decode("utf-8", "replace"), err.decode("utf-8", "replace")
    except subprocess.TimeoutExpired:
        p.kill()
        p.communicate()
        return 124, "", "timeout after %ds" % timeout
    except OSError as ex:
        return 127, "", str(ex)


def read_jsonl(path):
    if not os.path.exists(path):
        return []
    out = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line:
                try:
                    out.append(json.loads(line))
                except ValueError:
                    continue                       # a torn last line from an interrupted run
    return out


def append_jsonl(path, obj):
    d = os.path.dirname(path)
    if d and not os.path.isdir(d):
        os.makedirs(d)
    with open(path, "a") as f:
        f.write(json.dumps(obj) + "\n")
        f.flush()
        os.fsync(f.fileno())                       # the full run WILL be interrupted


def parse_ts(s):
    """GitHub's '2025-07-26T02:59:01Z' -> datetime, or None."""
    if not s:
        return None
    try:
        return datetime.strptime(s[:19], "%Y-%m-%dT%H:%M:%S")
    except (ValueError, TypeError):
        return None


def repo_slug(repo_url):
    """'https://api.github.com/repos/milvus-io/pymilvus' -> 'milvus-io/pymilvus'."""
    if not repo_url:
        return None
    parts = [p for p in repo_url.rstrip("/").split("/") if p]
    if len(parts) < 2:
        return None
    return "%s/%s" % (parts[-2], parts[-1])


# --------------------------------------------------------------- fetch stages

def hf_num_rows(config):
    try:
        d = http_json(HF_SIZE, {"dataset": DATASET, "config": config})
    except RuntimeError:
        return None
    size = d.get("size") or {}
    for key in ("config", "dataset"):
        v = size.get(key) or {}
        if isinstance(v, dict) and v.get("num_rows"):
            return v["num_rows"]
    for s in (size.get("splits") or []):
        if s.get("num_rows"):
            return s["num_rows"]
    return None


def cmd_fetch(args, config, out_name, fields):
    """Page a HuggingFace config into a local JSONL cache. Resumable.

    Resumption is by line count, which is exact because the API is paged by
    a stable offset and this only ever appends. An interrupted run continues
    where it stopped; a completed one is a no-op.

    Everything downstream reads this cache, never the network, so a corpus
    run can be launched on a machine with no access to HuggingFace at all
    provided the cache came with it.
    """
    out = os.path.join(args.cache, out_name)
    have = len(read_jsonl(out))
    total = hf_num_rows(config)
    log("%s: %s rows cached, %s reported upstream" % (config, have, total if total else "?"))
    if args.limit and have >= args.limit:
        log("%s: already have %d >= --limit %d, nothing to do" % (config, have, args.limit))
        return 0
    if total is not None and have >= total:
        log("%s: cache complete" % config)
        return 0

    page = args.page_size
    offset = have
    fetched = 0
    while True:
        if args.limit and have + fetched >= args.limit:
            break
        if total is not None and offset >= total:
            break
        want = page
        if args.limit:
            want = min(page, args.limit - (have + fetched))
        try:
            d = http_json(HF_ROWS, {"dataset": DATASET, "config": config,
                                    "split": "train", "offset": offset, "length": want})
        except RuntimeError as ex:
            log("STOP: %s" % ex)
            log("      %d rows are cached at %s; rerun to resume." % (have + fetched, out))
            return 1
        rows = d.get("rows") or []
        if not rows:
            break
        if total is None:
            total = d.get("num_rows_total")
        for r in rows:
            row = r.get("row") or {}
            append_jsonl(out, {k: row.get(k) for k in fields} if fields else row)
        fetched += len(rows)
        offset += len(rows)
        if args.delay:
            # The datasets-server rate-limits per client and a full table is
            # hundreds of requests. Pacing costs minutes; tripping the limit
            # costs a restart.
            time.sleep(args.delay)
        if fetched % (page * 10) == 0 or len(rows) < want:
            log("  %s: %d rows" % (config, have + fetched))
        if len(rows) < want:
            break
    log("%s: %d rows cached at %s" % (config, have + fetched, out))
    return 0


# AIDev ships each table twice. The scoped tables (`pull_request`,
# `repository`) cover the agents the paper studied; the `all_*` tables
# aggregate across every agent GitHub exposes. Measured 2026-08-12:
# pull_request 33,596 rows / all_pull_request 932,791; repository 2,807 /
# all_repository 116,211. The design's "932K agent PRs" is all_pull_request.
# Which one a run uses changes the population, so it is an explicit flag
# recorded in the pairs manifest rather than a constant buried here - and
# the scoped table is the default because 33,596 rows is 336 API pages
# where 932,791 is 9,328.
PR_FIELDS = ["id", "number", "agent", "state", "created_at", "closed_at",
             "merged_at", "repo_id", "repo_url", "html_url"]


def cmd_fetch_prs(args):
    return cmd_fetch(args, args.config, args.config + ".jsonl", PR_FIELDS)


def cmd_fetch_repos(args):
    return cmd_fetch(args, args.config, args.config + ".jsonl", None)


# ---------------------------------------------------------- pair construction

def overlaps(a_start, a_end, b_start, b_end):
    """Xu et al.'s co-activity definition: the two [created, closed] intervals
    intersect. Touching endpoints do not count as overlap.

    A PR with no end timestamp (still open) has no interval, so it cannot be
    tested; the caller drops it and counts the drop rather than guessing an
    end.
    """
    if not (a_start and a_end and b_start and b_end):
        return False
    return a_start < b_end and b_start < a_end


def cmd_pairs(args):
    prs = read_jsonl(os.path.join(args.cache, args.prs))
    if not prs:
        log("no cached PRs at %s; run `fetch-prs` first" % os.path.join(args.cache, args.prs))
        return 1

    # `repository.language` is GitHub linguist's primary language - the
    # cheapest tier signal there is, and it needs no clone. A repo missing
    # from the table has an unknown language, which --require-language turns
    # from "keep" into "drop".
    languages = {}
    repo_rows = read_jsonl(os.path.join(args.cache, args.repos))
    lang_key = None
    for row in repo_rows:
        if lang_key is None:
            for k in ("language", "primary_language", "repo_language"):
                if k in row:
                    lang_key = k
                    break
        slug = row.get("full_name") or repo_slug(row.get("url") or row.get("repo_url"))
        if slug and lang_key:
            languages[slug] = (row.get(lang_key) or "").lower()

    # Every drop gets a counter. PHASE1-PREREGISTRATION.md: "Every drop
    # counted, none silent."
    drops = OrderedDict([
        ("pr_rows", len(prs)),
        ("dropped_no_repo", 0),
        ("dropped_no_interval", 0),
        ("dropped_wrong_tier", 0),
        ("prs_kept", 0),
        ("repos_with_2plus_prs", 0),
        ("candidate_pairs", 0),
        ("pairs_after_sampling", 0),
    ])

    by_repo = {}
    for pr in prs:
        slug = repo_slug(pr.get("repo_url"))
        if not slug or not pr.get("number"):
            drops["dropped_no_repo"] += 1
            continue
        start = parse_ts(pr.get("created_at"))
        end = parse_ts(pr.get("closed_at")) or parse_ts(pr.get("merged_at"))
        if not (start and end) or end <= start:
            # Still open, or a zero-length interval we cannot reason about.
            drops["dropped_no_interval"] += 1
            continue
        if args.tier != "any":
            lang = languages.get(slug)
            if lang is None:
                if args.require_language:
                    drops["dropped_wrong_tier"] += 1
                    continue
            elif lang != args.tier:
                drops["dropped_wrong_tier"] += 1
                continue
        drops["prs_kept"] += 1
        by_repo.setdefault(slug, []).append(
            {"number": pr["number"], "agent": pr.get("agent") or "unknown",
             "start": start, "end": end, "html_url": pr.get("html_url"),
             "state": pr.get("state"), "merged_at": pr.get("merged_at")})

    pairs = []
    for slug in sorted(by_repo):
        prs_r = sorted(by_repo[slug], key=lambda p: (p["start"], p["number"]))
        if len(prs_r) < 2:
            continue
        drops["repos_with_2plus_prs"] += 1
        found = []
        for i in range(len(prs_r)):
            for j in range(i + 1, len(prs_r)):
                a, b = prs_r[i], prs_r[j]
                if a["number"] == b["number"]:
                    continue
                # Sorted by start, so once b starts at or after a's end no
                # later j can overlap a either.
                if b["start"] >= a["end"]:
                    break
                if not overlaps(a["start"], a["end"], b["start"], b["end"]):
                    continue
                found.append({
                    "repo": slug,
                    "a": a["number"], "b": b["number"],
                    "a_agent": a["agent"], "b_agent": b["agent"],
                    # The calibration gate is reported per kind, because the
                    # published rates are per kind (19.8% intra, 41.7% cross).
                    "kind": "intra" if a["agent"] == b["agent"] else "cross",
                    "tier": args.tier,
                    "a_url": a["html_url"], "b_url": b["html_url"],
                    "a_state": a["state"], "b_state": b["state"],
                })
        if args.max_pairs_per_repo and len(found) > args.max_pairs_per_repo:
            # One very active repo can otherwise supply most of the corpus,
            # which would make the result a statement about that repo. The
            # cap is deterministic given --seed and recorded in the manifest.
            rnd = random.Random("%s:%d" % (slug, args.seed))
            found = sorted(rnd.sample(found, args.max_pairs_per_repo),
                           key=lambda p: (p["a"], p["b"]))
        pairs.extend(found)

    drops["candidate_pairs"] = len(pairs)
    if args.sample and len(pairs) > args.sample:
        rnd = random.Random(args.seed)
        pairs = sorted(rnd.sample(pairs, args.sample), key=lambda p: (p["repo"], p["a"], p["b"]))
    drops["pairs_after_sampling"] = len(pairs)

    out = os.path.join(args.cache, args.out)
    if os.path.exists(out):
        os.remove(out)
    for p in pairs:
        append_jsonl(out, p)

    manifest = {"generated": datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"),
                "tier": args.tier, "sample": args.sample, "seed": args.seed,
                "max_pairs_per_repo": args.max_pairs_per_repo,
                "require_language": args.require_language,
                "language_field_found": lang_key, "counts": drops}
    with open(os.path.join(args.cache, args.out + ".manifest.json"), "w") as f:
        json.dump(manifest, f, indent=2)

    for k, v in drops.items():
        log("%-24s %s" % (k, v))
    if lang_key is None and args.tier != "any":
        log("NOTE: no language field in the cached repository table, so --tier %s "
            "was not enforced by language." % args.tier)
    log("wrote %d pairs to %s" % (len(pairs), out))
    return 0


# ----------------------------------------------------------------- the replay

def ensure_clone(cache, slug, timeout):
    """-> (path, error). A bare, blobless clone, made once per repo.

    Bare because there is nothing to check out: replay reads the object
    store. Blobless because the corpus is large and most blobs are never
    needed; the ones that are get lazily fetched during the replay.

    This is OUR clone in OUR cache. The refs written into it below exist
    only here - nothing is ever pushed, and the GitHub repository is only
    ever read.
    """
    d = os.path.join(cache, "repos", slug.replace("/", "-") + ".git")
    if os.path.isdir(os.path.join(d, "objects")):
        return d, None
    parent = os.path.dirname(d)
    if not os.path.isdir(parent):
        os.makedirs(parent)
    rc, _out, err = run_git(["clone", "--bare", "--filter=blob:none",
                             "https://github.com/%s.git" % slug, d], timeout=timeout)
    if rc != 0:
        return None, (err.strip().split("\n")[-1] if err.strip() else "clone failed rc=%d" % rc)
    return d, None


def fetch_pr_head(repo_dir, number, timeout):
    """Fetch one closed PR's head commit into a local ref. -> (ref, error).

    GitHub keeps refs/pull/<n>/head after a PR closes, but does not promise
    to: this is the single largest attrition risk in the whole measurement,
    so its failure is a counted stage rather than an exception.
    """
    ref = "refs/moire/pr-%d" % number
    rc, _out, err = run_git(["fetch", "--quiet", "--no-tags", "origin",
                             "+refs/pull/%d/head:%s" % (number, ref)],
                            cwd=repo_dir, timeout=timeout)
    if rc != 0:
        return None, (err.strip().split("\n")[-1] if err.strip() else "fetch failed rc=%d" % rc)
    return ref, None


def _ts_eligible(repo_dir, ref):
    """Can the tier-2 checker command actually run on this head?

    -> (eligible, reason). Two requirements, both read via git cat-file from
    the bare clone (nothing is checked out to answer this):

    - a root package-lock.json, because `npm ci` refuses to run without one.
      A yarn- or pnpm-managed repository fails the install identically in
      self, peer and merged, the sentinel cancels in the subtraction, and
      the pair would count as evaluated-clean with nothing measured -
      observed on elastic/kibana and OneKeyHQ/app-monorepo in the 18 August
      smoke run. Narrower population, stated in the published scope, is
      strictly better than a silently inflated denominator.
    - a root tsconfig.json, or typescript declared in (dev)dependencies,
      because a tree without tsc cannot be type-checked at all.
    """
    def _cat(path):
        try:
            pr = subprocess.Popen(["git", "-C", repo_dir, "cat-file", "-p",
                                   "%s:%s" % (ref, path)],
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            o, _ = pr.communicate(timeout=30)
            return o if pr.returncode == 0 else None
        except Exception:
            return None
    if _cat("package-lock.json") is None:
        return (False, "no package-lock.json (npm ci cannot run)")
    if _cat("tsconfig.json") is not None:
        return (True, None)
    pkg = _cat("package.json")
    if pkg is None:
        return (False, "no package.json")
    try:
        d = json.loads(pkg.decode("utf-8", "replace"))
    except Exception:
        return (False, "unparsable package.json")
    for k in ("dependencies", "devDependencies"):
        if "typescript" in (d.get(k) or {}):
            return (True, None)
    return (False, "no tsconfig.json and no typescript dependency")


def cmd_run(args):
    pairs = read_jsonl(os.path.join(args.cache, args.pairs))
    if not pairs:
        log("no pairs; run `pairs` first")
        return 1
    out = os.path.join(args.cache, args.out)
    done = set()
    for r in read_jsonl(out):
        done.add((r.get("repo"), r.get("a"), r.get("b")))
    if done:
        log("resuming: %d pairs already replayed" % len(done))

    moire = args.moire
    if not os.path.exists(moire):
        log("moire binary not found at %s (use --moire)" % moire)
        return 1

    # Amendment A1.1: the sensitivity gate is defined on "the exact binary
    # that replayed the corpus", so that binary's identity is recorded HERE,
    # at run time, not reconstructed later from memory. sha256 of the file
    # is the identity; the repo HEAD is a courtesy pointer and may be absent.
    import hashlib
    with open(moire, "rb") as fh:
        moire_sha = hashlib.sha256(fh.read()).hexdigest()
    head = None
    try:
        p_h = subprocess.Popen(
            ["git", "-C", os.path.dirname(os.path.dirname(os.path.abspath(moire))),
             "rev-parse", "HEAD"],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        out_h, _ = p_h.communicate(timeout=10)
        if p_h.returncode == 0:
            head = out_h.decode("ascii", "replace").strip()
    except Exception:
        pass
    prov_path = out + ".manifest.json"
    prov = {}
    if os.path.exists(prov_path):
        try:
            with open(prov_path) as fh:
                prov = json.load(fh)
        except Exception:
            prov = {}
    binaries = prov.setdefault("moire_binaries", [])
    entry = {"path": os.path.abspath(moire), "sha256": moire_sha, "repo_head": head}
    if entry not in binaries:
        binaries.append(entry)
    with open(prov_path, "w") as fh:
        json.dump(prov, fh, indent=1)
    if len(binaries) > 1:
        log("WARNING: this results file has now been written by %d distinct "
            "moire binaries; the sensitivity gate is per-binary, so a mixed "
            "run must pass it for EVERY one of them." % len(binaries))
    log("moire binary sha256 %s%s" % (moire_sha[:16], (" (repo HEAD %s)" % head[:12]) if head else ""))

    n = 0
    bad_repos = {}
    for p in pairs:
        key = (p["repo"], p["a"], p["b"])
        if key in done:
            continue
        if args.limit and n >= args.limit:
            break
        n += 1
        rec = dict(p)
        rec["replayed_at"] = datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")
        rec["stage"] = "started"
        rec["replay"] = None
        rec["error"] = None

        if p["repo"] in bad_repos:
            # One dead repo would otherwise pay the clone timeout once per
            # pair it appears in.
            rec["stage"] = "repo_unavailable"
            rec["error"] = bad_repos[p["repo"]]
            append_jsonl(out, rec)
            log("[%d] %s #%s+#%s  repo_unavailable (cached)" % (n, p["repo"], p["a"], p["b"]))
            continue

        repo_dir, err = ensure_clone(args.cache, p["repo"], args.clone_timeout)
        if err:
            bad_repos[p["repo"]] = err
            rec["stage"] = "repo_unavailable"
            rec["error"] = err
            append_jsonl(out, rec)
            log("[%d] %s #%s+#%s  repo_unavailable: %s" % (n, p["repo"], p["a"], p["b"], err))
            continue

        ref_a, err_a = fetch_pr_head(repo_dir, p["a"], args.fetch_timeout)
        ref_b, err_b = fetch_pr_head(repo_dir, p["b"], args.fetch_timeout)
        if err_a or err_b:
            rec["stage"] = "head_unfetchable"
            rec["error"] = err_a or err_b
            append_jsonl(out, rec)
            log("[%d] %s #%s+#%s  head_unfetchable: %s" %
                (n, p["repo"], p["a"], p["b"], (err_a or err_b)[:70]))
            continue

        # Tier-2 eligibility, checked from the fetched heads BEFORE the
        # replay. An external checker has no coverage channel, and a tree
        # without the tool it invokes fails identically in self, peer and
        # merged - the sentinel cancels in the subtraction and the pair
        # would silently count as evaluated-clean, inflating the
        # denominator with pairs on which nothing was measured. Same
        # blindspot class the builtin checker's `performed` flag closed;
        # this is the external-checker equivalent. Eligible = either head
        # carries a tsconfig.json or declares typescript in (dev)deps.
        # Tier-2 eligibility does NOT skip the replay: the textual verdict
        # costs no checker and feeds the calibration gate, and the
        # pre-registered ladder puts "textually clean" BEFORE
        # "checker-eligible". An ineligible pair is replayed without the
        # checker, keeps its textual verdict, and only a pair that would
        # otherwise count as evaluated is reclassified to the
        # not_checker_eligible rung below. (First smoke run got this wrong:
        # llmgateway stopped at eligibility and its textual conflict
        # vanished from calibration.)
        ineligible_reason = None
        if args.checker and (p.get("tier") == "typescript"):
            # BOTH heads must be able to run the checker: a parent tree whose
            # install fails leaves the subtraction without a subtrahend and
            # biases the result TOWARD false breakage (observed: ultracite's
            # self tree failed its install and 23 artifact findings survived
            # the subtraction that peer alone could not cancel).
            ok_a, why_a = _ts_eligible(repo_dir, ref_a)
            ok_b, why_b = _ts_eligible(repo_dir, ref_b)
            if not (ok_a and ok_b):
                ineligible_reason = "self: %s; peer: %s" % (why_a or "ok", why_b or "ok")

        cmd = [sys.executable, moire, "replay", ref_a, ref_b, "--json"]
        if args.checker and not ineligible_reason:
            cmd += ["--checker", args.checker]
        try:
            proc = subprocess.Popen(cmd, cwd=repo_dir, stdout=subprocess.PIPE,
                                    stderr=subprocess.PIPE)
            sout, serr = proc.communicate(timeout=args.replay_timeout)
            rc = proc.returncode
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.communicate()
            # Its own rung, not "refused": a timeout says the pair was too
            # expensive to evaluate on this machine, which is a fact about
            # the corpus (monorepos materialise three full trees) and not a
            # bad invocation. Conflating them would hide a systematic drop.
            rec["stage"] = "replay_timeout"
            rec["error"] = "exceeded --replay-timeout %ds" % args.replay_timeout
            append_jsonl(out, rec)
            log("[%d] %s #%s+#%s  replay_timeout" % (n, p["repo"], p["a"], p["b"]))
            continue
        if rc != 0:
            # `moire replay` exits 0 for every pair it can evaluate, so a
            # nonzero here is a refusal (bad argument, unusable environment)
            # and is a harness bug, not a property of the pair.
            rec["stage"] = "replay_refused"
            rec["error"] = "rc=%d %s" % (rc, serr.decode("utf-8", "replace").strip()[:200])
            append_jsonl(out, rec)
            log("[%d] %s #%s+#%s  REPLAY REFUSED rc=%d" % (n, p["repo"], p["a"], p["b"], rc))
            continue
        try:
            record = json.loads(sout.decode("utf-8", "replace"))
        except ValueError as ex:
            rec["stage"] = "replay_unparsable"
            rec["error"] = str(ex)
            append_jsonl(out, rec)
            continue

        rec["replay"] = record
        rec["stage"] = classify_stage(record)
        if ineligible_reason and rec["stage"] == "evaluated":
            # The replay ran without the tier's checker (see above), so a
            # clean verdict here says only "textually clean" - the semantic
            # question was never asked. Without this override, a TS repo
            # that happens to contain .py files would count as evaluated on
            # the strength of the BUILTIN checker reading those.
            rec["stage"] = "not_checker_eligible"
            rec["error"] = ineligible_reason
        append_jsonl(out, rec)
        sem = record.get("semantic") or {}
        log("[%d] %s #%s+#%s  %s%s" %
            (n, p["repo"], p["a"], p["b"], rec["stage"],
             "  BREAKAGE=%d" % len(sem.get("new_breakage") or [])
             if sem.get("new_breakage") else ""))
    log("replayed %d pairs this run; results at %s" % (n, out))
    return 0


def classify_stage(record):
    """The pre-registered attrition ladder, applied to one replay record.

    candidate -> fetchable -> merge-base found -> textually clean ->
    checker-eligible. Each pair stops at exactly one rung, and the rung is
    stored rather than recomputed at read time so the table cannot drift
    from the records it summarises.
    """
    if record.get("verdict") == "error":
        if not record.get("merge_base"):
            return "no_merge_base"
        return "replay_error"
    if not record.get("merge_base"):
        return "no_merge_base"
    if record.get("verdict") == "conflict":
        return "textual_conflict"
    sem = record.get("semantic") or {}
    if not sem:
        return "no_semantic_pass"
    if not sem.get("performed"):
        return "not_checker_eligible"
    return "evaluated"


# -------------------------------------------------------------------- report

def _log_binom_cdf(k, n, p):
    """log-space P(X <= k) for X ~ Binomial(n, p); exact via lgamma terms."""
    if p <= 0.0:
        return 0.0
    if p >= 1.0:
        return 0.0 if k >= n else float("-inf")
    from math import lgamma, log, exp
    total = 0.0
    for i in range(0, k + 1):
        lg = (lgamma(n + 1) - lgamma(i + 1) - lgamma(n - i + 1)
              + i * log(p) + (n - i) * log(1.0 - p))
        total += exp(lg)
    return min(total, 1.0)


def clopper_pearson(k, n, alpha=0.05):
    """Exact (Clopper-Pearson) two-sided interval for k successes in n trials.

    Bisection on the exact binomial CDF - no scipy, per the harness's
    stdlib-only rule. Good to ~1e-6, which is far inside what n<=1000 can
    resolve anyway.
    """
    if n == 0:
        return (0.0, 1.0)
    if k == 0:
        lo = 0.0
    else:
        f = lambda p: 1.0 - _log_binom_cdf(k - 1, n, p)   # P(X >= k)
        a, b = 0.0, k / float(n)
        for _ in range(50):
            m = (a + b) / 2.0
            if f(m) < alpha / 2.0:
                a = m
            else:
                b = m
        lo = (a + b) / 2.0
    if k == n:
        hi = 1.0
    else:
        g = lambda p: _log_binom_cdf(k, n, p)              # P(X <= k)
        a, b = k / float(n), 1.0
        for _ in range(50):
            m = (a + b) / 2.0
            if g(m) < alpha / 2.0:
                b = m
            else:
                a = m
        hi = (a + b) / 2.0
    return (lo, hi)


def cmd_report(args):
    results = read_jsonl(os.path.join(args.cache, args.out))
    if not results:
        log("no results; run `run` first")
        return 1

    # The ladder must start where the pairs did, not where this run did: a
    # `run --limit 20` attempts 20 of however many were constructed, and a
    # table whose first row was "20" would silently rebase the denominator.
    constructed = None
    mpath = os.path.join(args.cache, args.pairs + ".manifest.json")
    if os.path.exists(mpath):
        try:
            with open(mpath) as f:
                constructed = (json.load(f).get("counts") or {}).get("pairs_after_sampling")
        except (ValueError, OSError):
            constructed = None

    stages = OrderedDict([
        ("pairs_constructed", constructed if constructed is not None else 0),
        ("pairs_attempted", 0),
        ("repo_unavailable", 0),
        ("head_unfetchable", 0),
        ("replay_timeout", 0),
        ("replay_refused", 0),
        ("replay_unparsable", 0),
        ("replay_error", 0),
        ("no_merge_base", 0),
        ("textual_conflict", 0),
        ("no_semantic_pass", 0),
        ("not_checker_eligible", 0),
        ("evaluated", 0),
    ])
    textual = {"intra": [0, 0], "cross": [0, 0]}   # [conflicting, decided]
    hits = []
    nondet = 0
    for r in results:
        stages["pairs_attempted"] += 1
        st = r.get("stage") or "replay_error"
        if st not in stages:
            stages[st] = 0
        stages[st] += 1
        rep = r.get("replay") or {}
        verdict = rep.get("verdict")
        if verdict in ("clean", "conflict"):
            kind = r.get("kind") or "cross"
            if kind in textual:
                textual[kind][1] += 1
                if verdict == "conflict":
                    textual[kind][0] += 1
        sem = rep.get("semantic") or {}
        if sem.get("nondeterministic_discarded"):
            nondet += len(sem["nondeterministic_discarded"])
        if st == "evaluated" and (sem.get("new_breakage") or []):
            hits.append(r)

    clean_evaluated = stages["evaluated"]

    # Amendment A1.2: per-tier rates are primary; the pooled rate decides
    # nothing. Tally evaluated pairs and hits per tier here so the report
    # can print each tier with its own exact interval.
    by_tier = {}
    for r in results:
        if (r.get("stage") or "") != "evaluated":
            continue
        t = r.get("tier") or "unknown"
        ev, h = by_tier.get(t, (0, 0))
        sem_r = (r.get("replay") or {}).get("semantic") or {}
        by_tier[t] = (ev + 1, h + (1 if (sem_r.get("new_breakage") or []) else 0))

    lines = []
    lines.append("ATTRITION  (every drop counted; PHASE1-PREREGISTRATION.md)")
    lines.append("")
    for k, v in stages.items():
        lines.append("  %-24s %6d" % (k, v))
    lines.append("")
    lines.append("  Reading the ladder: pairs_constructed is what `pairs` built,")
    lines.append("  pairs_attempted is what this run reached, and `evaluated` is the")
    lines.append("  denominator the semantic rate would use - textually clean,")
    lines.append("  merge-base present, and a checker that read something.")
    if constructed is None:
        lines.append("  (pairs_constructed unavailable: no manifest beside the pairs file)")
    lines.append("")
    lines.append("CALIBRATION  (the run is void if this fails)")
    lines.append("")
    lines.append("  Compared against Xu, Subramanian & Karthik (arXiv:2607.04697),")
    lines.append("  the paper this pair construction replicates.")
    lines.append("")
    lines.append("  %-8s %-22s %-14s %s" % ("kind", "measured", "published", "n"))
    for kind in ("intra", "cross"):
        conf, dec = textual[kind]
        measured = ("%.1f%%" % (100.0 * conf / dec)) if dec else "n/a"
        lines.append("  %-8s %-22s %-14s %d" %
                     (kind, "%s (%d conflicting)" % (measured, conf),
                      "%.1f%%" % PUBLISHED_TEXTUAL[kind], dec))
    lines.append("")
    lines.append("  n is the number of pairs that REACHED the oracle - both heads")
    lines.append("  fetched and a merge base found. Xu et al.'s denominator is all")
    lines.append("  co-active pairs, so heavy attrition above makes these two")
    lines.append("  populations differ, and that is itself a reason a rate can")
    lines.append("  diverge without the pair construction being wrong.")
    lines.append("")
    lines.append("  The pre-registration says 'gross divergence means our pair")
    lines.append("  construction is wrong' and deliberately does not quantify")
    lines.append("  'gross'. This harness therefore does not invent a threshold and")
    lines.append("  does not decide the gate: it prints the comparison and requires")
    lines.append("  --calibration-passed before it will release any semantic number.")
    lines.append("")
    if nondet:
        lines.append("  nondeterministic findings discarded (3x merged-tree rule): %d" % nondet)
        lines.append("")

    lines.append("SEMANTIC RESULT")
    lines.append("")
    reasons = []
    if clean_evaluated < PREREG_MIN_CLEAN_PAIRS:
        reasons.append("only %d evaluated pairs; the pre-registration requires >= %d"
                       % (clean_evaluated, PREREG_MIN_CLEAN_PAIRS))
    if not args.calibration_passed:
        reasons.append("calibration not affirmed (pass --calibration-passed once the "
                       "comparison above has been reviewed)")
    if not args.sensitivity_passed:
        reasons.append("sensitivity not affirmed (amendment A1.1: run "
                       "MOIRE_BIN=<the recorded binary> bash tests/benchmark_recall.sh, "
                       "and pass --sensitivity-passed only if it exits 0 at its floor; "
                       "the binary's sha256 is in the results manifest)")
    if not args.audited:
        reasons.append("audit not affirmed (every hit must be classified by hand; "
                       "pass --audited once the audit table is filled in)")
    if reasons:
        lines.append("  WITHHELD. This run cannot produce the Phase 1 number:")
        for r in reasons:
            lines.append("    - %s" % r)
        lines.append("")
        lines.append("  %d pair(s) reported breakage and are listed below for audit."
                     % len(hits))
        lines.append("  An unaudited breakage count is NOT a base rate: the audit")
        lines.append("  exists to separate true collisions from relocated pre-existing")
        lines.append("  breakage, checker artifacts and environment artifacts, and")
        lines.append("  only the true-collision count feeds the decision rule.")
    else:
        for t in sorted(by_tier):
            ev, h = by_tier[t]
            lo, hi = clopper_pearson(h, ev)
            lines.append("  tier %-11s %d of %d evaluated pairs reported breakage "
                         "(%.2f%%, 95%% CI %.2f%%-%.2f%%)"
                         % (t, h, ev, (100.0 * h / ev if ev else 0.0),
                            100.0 * lo, 100.0 * hi))
        rate = 100.0 * len(hits) / clean_evaluated if clean_evaluated else 0.0
        lines.append("  pooled          %d of %d (%.2f%%) - reported for "
                     "completeness; it decides nothing (amendment A1.2)"
                     % (len(hits), clean_evaluated, rate))
        lines.append("  These are REPORTED rates. The decision rule in")
        lines.append("  PHASE1-PREREGISTRATION.md is defined on the AUDITED")
        lines.append("  true-collision rate per tier; take it from the audit column.")
    lines.append("")
    prov_path = os.path.join(args.cache, args.out + ".manifest.json")
    if os.path.exists(prov_path):
        try:
            with open(prov_path) as fh:
                _prov = json.load(fh)
            for b in _prov.get("moire_binaries") or []:
                lines.append("  replayed by moire sha256 %s%s" %
                             (b.get("sha256", "?")[:16],
                              (" (repo HEAD %s)" % b["repo_head"][:12]) if b.get("repo_head") else ""))
            lines.append("")
        except Exception:
            pass

    lines.append("AUDIT TABLE  (%d hit(s))" % len(hits))
    lines.append("")
    if not hits:
        lines.append("  no reported breakage")
    for r in hits:
        rep = r["replay"]
        sem = rep.get("semantic") or {}
        lines.append("  %s  #%s + #%s  [%s, %s]" %
                     (r["repo"], r["a"], r["b"], r.get("kind"), r.get("tier")))
        lines.append("    finding_id      : %s" % rep.get("finding_id"))
        lines.append("    self/peer/merged: %s / %s / %s broken" %
                     (sem.get("self_broken"), sem.get("peer_broken"),
                      sem.get("merged_broken")))
        renames = sem.get("renames") or {}
        lines.append("    renames seen    : self=%d peer=%d" %
                     (len(renames.get("self") or []), len(renames.get("peer") or [])))
        lines.append("    classification  : UNCLASSIFIED  <- true collision | relocated "
                     "pre-existing | checker artifact | environment artifact")
        for item in (sem.get("new_breakage") or [])[:10]:
            lines.append("      %s" % (item,))
        lines.append("    repro:")
        lines.append("      git clone --bare --filter=blob:none https://github.com/%s.git r.git"
                     % r["repo"])
        lines.append("      git -C r.git fetch origin +refs/pull/%s/head:refs/moire/pr-%s "
                     "+refs/pull/%s/head:refs/moire/pr-%s && "
                     "(cd r.git && moire replay refs/moire/pr-%s refs/moire/pr-%s)"
                     % (r["a"], r["a"], r["b"], r["b"], r["a"], r["b"]))
        lines.append("")

    text = "\n".join(lines)
    if args.json:
        sys.stdout.write(json.dumps({
            "attrition": stages,
            "calibration": {k: {"conflicting": textual[k][0], "decided": textual[k][1],
                                "measured_pct": (100.0 * textual[k][0] / textual[k][1])
                                if textual[k][1] else None,
                                "published_pct": PUBLISHED_TEXTUAL[k]}
                            for k in textual},
            "nondeterministic_discarded": nondet,
            "evaluated_pairs": clean_evaluated,
            "reported_breakage_pairs": len(hits),
            "semantic_rate_released": not reasons,
            "withheld_because": reasons,
        }, indent=2) + "\n")
    else:
        sys.stdout.write(text + "\n")
    return 0


# ---------------------------------------------------------------------- main

def main(argv):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--cache", default=DEFAULT_CACHE,
                    help="directory for all cached data (default: ./cache)")
    sub = ap.add_subparsers(dest="cmd")

    for name, fn, choices in (
            ("fetch-prs", cmd_fetch_prs, ["pull_request", "all_pull_request"]),
            ("fetch-repos", cmd_fetch_repos, ["repository", "all_repository"])):
        p = sub.add_parser(name, help="cache a corpus table locally (resumable)")
        p.add_argument("--config", default=choices[0], choices=choices)
        p.add_argument("--limit", type=int, default=0, help="stop after N rows (0 = all)")
        p.add_argument("--page-size", type=int, default=100,
                       help="rows per API request (the API caps this at 100)")
        p.add_argument("--delay", type=float, default=0.4,
                       help="seconds to pause between requests (rate-limit pacing)")
        p.set_defaults(func=fn)

    p = sub.add_parser("pairs", help="construct co-active pairs from the cache")
    p.add_argument("--prs", default="pull_request.jsonl",
                   help="cached PR table (as written by fetch-prs)")
    p.add_argument("--repos", default="repository.jsonl",
                   help="cached repository table, for tier/language")
    p.add_argument("--tier", default="python",
                   choices=["python", "typescript", "any"])
    p.add_argument("--require-language", action="store_true",
                   help="drop repos whose language is unknown, rather than keeping them")
    p.add_argument("--sample", type=int, default=0, help="keep N pairs (0 = all)")
    p.add_argument("--max-pairs-per-repo", type=int, default=0,
                   help="cap one repo's contribution (0 = uncapped)")
    p.add_argument("--seed", type=int, default=20260812,
                   help="sampling seed, recorded in the manifest")
    p.add_argument("--out", default="pairs.jsonl")
    p.set_defaults(func=cmd_pairs)

    p = sub.add_parser("run", help="replay pairs through `moire replay`")
    p.add_argument("--pairs", default="pairs.jsonl")
    p.add_argument("--out", default="results.jsonl")
    p.add_argument("--limit", type=int, default=0, help="replay at most N new pairs")
    p.add_argument("--checker", default=None,
                   help="passed straight to `moire replay --checker` (tier 2)")
    p.add_argument("--moire", default=os.path.join(
        os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))),
        "bin", "moire"))
    p.add_argument("--clone-timeout", type=int, default=900)
    p.add_argument("--fetch-timeout", type=int, default=300)
    p.add_argument("--replay-timeout", type=int, default=900)
    p.set_defaults(func=cmd_run)

    p = sub.add_parser("report", help="attrition table, calibration, audit table")
    p.add_argument("--out", default="results.jsonl")
    p.add_argument("--pairs", default="pairs.jsonl",
                   help="the pairs file whose manifest supplies pairs_constructed")
    p.add_argument("--json", action="store_true")
    p.add_argument("--calibration-passed", action="store_true",
                   help="affirm that the calibration comparison was reviewed and passed")
    p.add_argument("--sensitivity-passed", action="store_true",
                   help="affirm that tests/benchmark_recall.sh passed at its floor "
                        "with MOIRE_BIN pointing at the exact binary that replayed "
                        "the corpus (PHASE1-PREREGISTRATION.md, amendment A1.1)")
    p.add_argument("--audited", action="store_true",
                   help="affirm that every hit in the audit table has been classified")
    p.set_defaults(func=cmd_report)

    args = ap.parse_args(argv[1:])
    if not getattr(args, "func", None):
        ap.print_help()
        return 2
    if not os.path.isdir(args.cache):
        os.makedirs(args.cache)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
