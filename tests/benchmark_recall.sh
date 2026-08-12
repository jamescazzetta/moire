#!/bin/bash

# tests/benchmark_recall.sh - how much of a real collision does the checker see?
#
# The other suites ask whether the mechanism behaves as specified. This one
# asks a different question, the one a user actually has: of the textually
# clean merges that genuinely do not work, how many does `moire` report?
#
# The answer is only worth anything if the grading is independent of the thing
# being graded, so nothing here consults moire's opinion about whether a case
# is broken. For every case the harness materialises the same three trees moire
# would (self, peer, and git's own speculative merge of the two, from
# `git merge-tree --write-tree`), then IMPORTS EVERY MODULE IN EACH TREE WITH
# THE REAL PYTHON INTERPRETER and records what the interpreter says. Ground
# truth for a case is
#
#     interpreter_errors(merged) - interpreter_errors(self) - interpreter_errors(peer)
#
# - the same subtraction moire performs, computed by CPython rather than by an
# AST approximation of it. A case "breaks" when that difference is non-empty:
# the merge introduces an import the interpreter refuses to perform, and
# neither branch on its own did.
#
# Findings are keyed by the interpreter's own error text with the tree's
# temporary path stripped, not by the file that raised it. That makes the key
# invariant under a file rename, which is deliberate: a peer's `git mv` must
# not manufacture ground-truth breakage out of a parent's pre-existing error.
# It is NOT invariant under a DIRECTORY rename, because there the module's own
# dotted name changes and so does CPython's message ("No module named
# 'pkg.util'" becomes "No module named 'core.util'"). No case here renames a
# directory it also carries pre-existing breakage in; that equivalence is
# moire's pre-registered rename control, asserted in tests/test_verify.sh
# V31-V33 and V44, and this harness has no independent standard for it.
#
# What is scored:
#
#   recall     positive cases (ground truth non-empty) that moire reported
#   false pos  negative cases (ground truth empty) that moire reported anyway
#
# A case whose ground truth does not match its declared role is a broken
# FIXTURE and fails the run loudly - that check is what keeps the cases honest
# without ever asking moire what the answer is.
#
# Run it against any build of the tool:
#
#   bash tests/benchmark_recall.sh
#   git show febc36b:bin/moire > /tmp/moire-old && chmod +x /tmp/moire-old
#   MOIRE_BIN=/tmp/moire-old bash tests/benchmark_recall.sh
#
# Exit 0 when no negative case was reported and recall is at least
# RECALL_FLOOR below; exit 1 otherwise. The floor is a regression gate, not a
# target: an older binary scoring under it is the point of running it there.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
MOIRE_BIN="${MOIRE_BIN:-$REPO_ROOT/bin/moire}"

# Recall the current checker achieves. One of the eight positives is out of
# reach of an import-name resolver by construction - a changed signature is not
# a name that stopped resolving - so this is 7 and not 8.
RECALL_FLOOR=7

TMPDIR_ROOT=""
GIT_PROG=""
PROBE=""

CAUGHT=0
MISSED=0
FALSE_POS=0
TRUE_NEG=0
BROKEN_FIXTURES=0

cleanup() {
    if [ -n "$TMPDIR_ROOT" ] && [ -d "$TMPDIR_ROOT" ]; then
        rm -rf "$TMPDIR_ROOT"
    fi
}
trap cleanup EXIT

git_version_ge() {
    local prog="$1" major="$2" minor="$3"
    local line version v_maj v_min
    line=$("$prog" --version 2>/dev/null | head -1) || return 1
    version=$(echo "$line" | grep -oE '[0-9]+\.[0-9]+' | head -1) || return 1
    v_maj=$(echo "$version" | cut -d. -f1)
    v_min=$(echo "$version" | cut -d. -f2)
    [ "$v_maj" -gt "$major" ] && return 0
    [ "$v_maj" -eq "$major" ] && [ "$v_min" -ge "$minor" ] && return 0
    return 1
}

find_git() {
    local prog
    if [ -n "${MOIRE_GIT:-}" ] && [ -x "$MOIRE_GIT" ] && git_version_ge "$MOIRE_GIT" 2 38; then
        echo "$MOIRE_GIT"; return 0
    fi
    if [ -x "/opt/homebrew/bin/git" ] && git_version_ge "/opt/homebrew/bin/git" 2 38; then
        echo "/opt/homebrew/bin/git"; return 0
    fi
    if prog=$(command -v git 2>/dev/null) && git_version_ge "$prog" 2 38; then
        echo "$prog"; return 0
    fi
    return 1
}

git_in() {
    local repo="$1"; shift
    (cd "$repo" && "$GIT_PROG" "$@")
}

init_repo() {
    local repo="$1"
    mkdir -p "$repo"
    git_in "$repo" init -q >/dev/null 2>&1
    git_in "$repo" config user.name "Benchmark"
    git_in "$repo" config user.email "benchmark@example.com"
    git_in "$repo" config commit.gpgsign false
}

commit_all() {
    local repo="$1" msg="$2"
    git_in "$repo" add -A >/dev/null 2>&1
    git_in "$repo" commit -q -m "$msg" >/dev/null 2>&1
}

# The ground-truth probe: import every module of a tree in its own interpreter
# process and collect what CPython says. Written out once per run.
write_probe() {
    PROBE="$TMPDIR_ROOT/ground_truth.py"
    cat > "$PROBE" <<'PYEOF'
"""Independent ground truth: what does CPython say about these three trees?

Imports every module of each tree in a FRESH interpreter process (so one
failure cannot mask or cause another, and no module's side effects leak into
the next), keys each failure by the interpreter's final traceback line with
the tree's own temporary path stripped, and prints

    merged_failures - self_failures - peer_failures

one key per line after a count. Knows nothing about moire.
"""
import os
import subprocess
import sys

SKIP_DIRS = (".git", "__pycache__")


def modules(root):
    found = set()
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        for name in filenames:
            if not name.endswith(".py"):
                continue
            rel = os.path.relpath(os.path.join(dirpath, name), root)
            parts = rel[:-3].split(os.sep)
            if parts and parts[-1] == "__init__":
                parts = parts[:-1]
            if not parts:
                continue
            ok = True
            for part in parts:
                if not part.isidentifier():
                    ok = False
            if ok:
                found.add(".".join(parts))
    return sorted(found)


def failures(root):
    env = dict(os.environ)
    env["PYTHONPATH"] = root
    env["PYTHONDONTWRITEBYTECODE"] = "1"
    keys = set()
    for mod in modules(root):
        proc = subprocess.Popen(
            [sys.executable, "-c",
             "import importlib, sys; importlib.import_module(sys.argv[1])", mod],
            cwd=root, env=env,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        _out, err = proc.communicate()
        if proc.returncode == 0:
            continue
        text = err.decode("utf-8", "replace")
        text = text.replace(root + os.sep, "").replace(root, "")
        lines = [ln.strip() for ln in text.split("\n") if ln.strip()]
        keys.add(lines[-1] if lines else "exit %d" % proc.returncode)
    return keys


def main():
    self_dir, peer_dir, merged_dir = sys.argv[1], sys.argv[2], sys.argv[3]
    new = failures(merged_dir) - failures(self_dir) - failures(peer_dir)
    ordered = sorted(new)
    sys.stdout.write("%d\n" % len(ordered))
    for key in ordered:
        sys.stdout.write("%s\n" % key)


main()
PYEOF
}

# ---------------------------------------------------------------- the cases
#
# Every fixture leaves branch `self` and branch `peer` off one base commit,
# and every one of them merges CLEANLY in git's eyes - a case that conflicts
# textually is not a case about semantics and the harness rejects it.

# P1: peer deletes a module and stops importing it; self adds a file that
# imports it. The README's own metaphor, and the failure this benchmark exists
# for.
case_module_deleted() {
    local repo="$1"
    mkdir -p "$repo/pkg"
    : > "$repo/pkg/__init__.py"
    printf 'def helper():\n    return 1\n' > "$repo/pkg/util.py"
    printf 'from pkg.util import helper\n\nVALUE = helper()\n' > "$repo/pkg/main.py"
    commit_all "$repo" base
    git_in "$repo" branch peer >/dev/null 2>&1
    git_in "$repo" checkout -q -b self >/dev/null 2>&1
    printf 'from pkg.util import helper\n\nRESULT = helper()\n' > "$repo/pkg/newfeature.py"
    commit_all "$repo" "self: new feature that uses helper"
    git_in "$repo" checkout -q peer >/dev/null 2>&1
    git_in "$repo" rm -q "pkg/util.py" >/dev/null 2>&1
    printf 'VALUE = 1\n' > "$repo/pkg/main.py"
    commit_all "$repo" "peer: drop util and its last caller"
    git_in "$repo" checkout -q self >/dev/null 2>&1
}

# P2: the same, by `git mv` rather than deletion - the module is still in the
# tree, under another name, with peer's own callers updated.
case_module_moved() {
    local repo="$1"
    mkdir -p "$repo/pkg"
    : > "$repo/pkg/__init__.py"
    printf 'def helper():\n    return 1\n' > "$repo/pkg/util.py"
    printf 'from pkg.util import helper\n\nVALUE = helper()\n' > "$repo/pkg/main.py"
    commit_all "$repo" base
    git_in "$repo" branch peer >/dev/null 2>&1
    git_in "$repo" checkout -q -b self >/dev/null 2>&1
    printf 'from pkg.util import helper\n\nRESULT = helper()\n' > "$repo/pkg/newfeature.py"
    commit_all "$repo" "self: new feature that uses helper"
    git_in "$repo" checkout -q peer >/dev/null 2>&1
    mkdir -p "$repo/pkg/helpers"
    : > "$repo/pkg/helpers/__init__.py"
    git_in "$repo" mv "pkg/util.py" "pkg/helpers/util.py" >/dev/null 2>&1
    printf 'from pkg.helpers.util import helper\n\nVALUE = helper()\n' > "$repo/pkg/main.py"
    commit_all "$repo" "peer: move util under helpers/"
    git_in "$repo" checkout -q self >/dev/null 2>&1
}

# P3: peer renames the whole package directory. Nothing self wrote changed;
# everything self imports did.
case_package_moved() {
    local repo="$1"
    mkdir -p "$repo/pkg"
    : > "$repo/pkg/__init__.py"
    printf 'def helper():\n    return 1\n' > "$repo/pkg/util.py"
    printf 'from pkg.util import helper\n\nVALUE = helper()\n' > "$repo/app.py"
    commit_all "$repo" base
    git_in "$repo" branch peer >/dev/null 2>&1
    git_in "$repo" checkout -q -b self >/dev/null 2>&1
    printf 'from pkg.util import helper\n\nRESULT = helper()\n' > "$repo/tool.py"
    commit_all "$repo" "self: new tool that uses helper"
    git_in "$repo" checkout -q peer >/dev/null 2>&1
    git_in "$repo" mv "pkg" "core" >/dev/null 2>&1
    printf 'from core.util import helper\n\nVALUE = helper()\n' > "$repo/app.py"
    commit_all "$repo" "peer: rename pkg -> core"
    git_in "$repo" checkout -q self >/dev/null 2>&1
}

# P4: the same deletion reached through `import util` rather than
# `from util import ...` - a whole-module import names no member at all.
case_plain_import_deleted() {
    local repo="$1"
    printf 'def helper():\n    return 1\n' > "$repo/util.py"
    printf 'import util\n\nVALUE = util.helper()\n' > "$repo/main.py"
    commit_all "$repo" base
    git_in "$repo" branch peer >/dev/null 2>&1
    git_in "$repo" checkout -q -b self >/dev/null 2>&1
    printf 'import util\n\nRESULT = util.helper()\n' > "$repo/newfeature.py"
    commit_all "$repo" "self: new feature that uses util"
    git_in "$repo" checkout -q peer >/dev/null 2>&1
    git_in "$repo" rm -q "util.py" >/dev/null 2>&1
    printf 'VALUE = 1\n' > "$repo/main.py"
    commit_all "$repo" "peer: drop util and its last caller"
    git_in "$repo" checkout -q self >/dev/null 2>&1
}

# P5: the module survives, the name does not.
case_name_removed() {
    local repo="$1"
    mkdir -p "$repo/pkg"
    : > "$repo/pkg/__init__.py"
    printf 'def helper():\n    return 1\n\n\ndef other():\n    return 2\n' > "$repo/pkg/util.py"
    printf 'from pkg.util import other\n\nVALUE = other()\n' > "$repo/pkg/main.py"
    commit_all "$repo" base
    git_in "$repo" branch peer >/dev/null 2>&1
    git_in "$repo" checkout -q -b self >/dev/null 2>&1
    printf 'from pkg.util import helper\n\nRESULT = helper()\n' > "$repo/pkg/newfeature.py"
    commit_all "$repo" "self: new feature that uses helper"
    git_in "$repo" checkout -q peer >/dev/null 2>&1
    printf 'def other():\n    return 2\n' > "$repo/pkg/util.py"
    commit_all "$repo" "peer: drop the unused helper"
    git_in "$repo" checkout -q self >/dev/null 2>&1
}

# P6: the mirror direction - SELF renames a name and updates its own callers,
# PEER writes a new caller of the old one.
case_name_renamed() {
    local repo="$1"
    printf 'def old_name():\n    return 1\n' > "$repo/lib.py"
    printf 'from lib import old_name\n\nVALUE = old_name()\n' > "$repo/main.py"
    commit_all "$repo" base
    git_in "$repo" branch peer >/dev/null 2>&1
    git_in "$repo" checkout -q -b self >/dev/null 2>&1
    printf 'def new_name():\n    return 1\n' > "$repo/lib.py"
    printf 'from lib import new_name\n\nVALUE = new_name()\n' > "$repo/main.py"
    commit_all "$repo" "self: rename old_name -> new_name"
    git_in "$repo" checkout -q peer >/dev/null 2>&1
    printf 'from lib import old_name\n\nRESULT = old_name()\n' > "$repo/peer_caller.py"
    commit_all "$repo" "peer: new caller of old_name"
    git_in "$repo" checkout -q self >/dev/null 2>&1
}

# P7: the name still resolves; the call no longer does. Out of reach of an
# import-name resolver, and here so that the score says so out loud.
case_signature_changed() {
    local repo="$1"
    mkdir -p "$repo/pkg"
    : > "$repo/pkg/__init__.py"
    printf 'def helper(a):\n    return a\n' > "$repo/pkg/util.py"
    printf 'from pkg.util import helper\n\nVALUE = helper(1)\n' > "$repo/pkg/main.py"
    commit_all "$repo" base
    git_in "$repo" branch peer >/dev/null 2>&1
    git_in "$repo" checkout -q -b self >/dev/null 2>&1
    printf 'from pkg.util import helper\n\nRESULT = helper(1)\n' > "$repo/pkg/newfeature.py"
    commit_all "$repo" "self: new caller of helper"
    git_in "$repo" checkout -q peer >/dev/null 2>&1
    printf 'def helper(a, b):\n    return a + b\n' > "$repo/pkg/util.py"
    printf 'from pkg.util import helper\n\nVALUE = helper(1, 2)\n' > "$repo/pkg/main.py"
    commit_all "$repo" "peer: helper takes a second argument"
    git_in "$repo" checkout -q self >/dev/null 2>&1
}

# P8: the deleted module reached by a RELATIVE import, which is how a package's
# own modules usually refer to each other.
case_relative_import_deleted() {
    local repo="$1"
    mkdir -p "$repo/pkg"
    : > "$repo/pkg/__init__.py"
    printf 'def helper():\n    return 1\n' > "$repo/pkg/util.py"
    printf 'from .util import helper\n\nVALUE = helper()\n' > "$repo/pkg/main.py"
    commit_all "$repo" base
    git_in "$repo" branch peer >/dev/null 2>&1
    git_in "$repo" checkout -q -b self >/dev/null 2>&1
    printf 'from .util import helper\n\nRESULT = helper()\n' > "$repo/pkg/newfeature.py"
    commit_all "$repo" "self: new feature that uses helper"
    git_in "$repo" checkout -q peer >/dev/null 2>&1
    git_in "$repo" rm -q "pkg/util.py" >/dev/null 2>&1
    printf 'VALUE = 1\n' > "$repo/pkg/main.py"
    commit_all "$repo" "peer: drop util and its last caller"
    git_in "$repo" checkout -q self >/dev/null 2>&1
}

# N1: both sides add files importing modules that are not in the tree and
# never will be. Unresolvable in all three trees, so it must cancel - this is
# the case that decides whether recording absent modules costs false positives.
case_thirdparty_both_sides() {
    local repo="$1"
    printf 'VALUE = 1\n' > "$repo/app.py"
    commit_all "$repo" base
    git_in "$repo" branch peer >/dev/null 2>&1
    git_in "$repo" checkout -q -b self >/dev/null 2>&1
    printf 'import os\nimport moire_absent_dep\nfrom json import loads\nfrom moire_absent_dep import thing\n\nVALUE = (os, loads, thing)\n' > "$repo/self_mod.py"
    commit_all "$repo" "self: new module with third-party imports"
    git_in "$repo" checkout -q peer >/dev/null 2>&1
    printf 'import sys\nfrom moire_absent_dep import other\n\nVALUE = (sys, other)\n' > "$repo/peer_mod.py"
    commit_all "$repo" "peer: new module with third-party imports"
    git_in "$repo" checkout -q self >/dev/null 2>&1
}

# N2: only self adds the absent dependency, and peer touches something else.
case_thirdparty_one_side() {
    local repo="$1"
    printf 'VALUE = 1\n' > "$repo/app.py"
    commit_all "$repo" base
    git_in "$repo" branch peer >/dev/null 2>&1
    git_in "$repo" checkout -q -b self >/dev/null 2>&1
    printf 'import moire_absent_dep.util\nfrom moire_absent_dep.client import Client\n\nVALUE = Client\n' > "$repo/client.py"
    commit_all "$repo" "self: new client on an uninstalled dependency"
    git_in "$repo" checkout -q peer >/dev/null 2>&1
    printf 'VALUE = 2\n' > "$repo/app.py"
    commit_all "$repo" "peer: unrelated edit"
    git_in "$repo" checkout -q self >/dev/null 2>&1
}

# N3: peer `git mv`s two files that already carried breakage - one an absent
# module, one an absent name. Both must follow the rename into the merged
# tree's namespace and cancel there.
case_rename_carries_breakage() {
    local repo="$1"
    mkdir -p "$repo/tools"
    : > "$repo/tools/__init__.py"
    printf 'def kept():\n    return 1\n' > "$repo/lib.py"
    printf 'import os\nfrom lib import gone\n\nVALUE = (os, gone)\n' > "$repo/tools/report.py"
    printf 'from moire_absent_dep import chart\n\nVALUE = chart\n' > "$repo/tools/chart.py"
    commit_all "$repo" base
    git_in "$repo" branch peer >/dev/null 2>&1
    git_in "$repo" checkout -q -b self >/dev/null 2>&1
    printf 'def kept():\n    return 1\n\n\ndef added():\n    return 2\n' > "$repo/lib.py"
    commit_all "$repo" "self: add a function to lib"
    git_in "$repo" checkout -q peer >/dev/null 2>&1
    git_in "$repo" mv "tools/report.py" "tools/reporting.py" >/dev/null 2>&1
    git_in "$repo" mv "tools/chart.py" "tools/charting.py" >/dev/null 2>&1
    commit_all "$repo" "peer: rename the tools modules"
    git_in "$repo" checkout -q self >/dev/null 2>&1
}

# N4: self arrives already broken. Its own problem, not a collision.
case_self_preexisting_breakage() {
    local repo="$1"
    printf 'def something():\n    return 1\n' > "$repo/lib.py"
    commit_all "$repo" base
    git_in "$repo" branch peer >/dev/null 2>&1
    git_in "$repo" checkout -q -b self >/dev/null 2>&1
    printf 'from lib import missing_fn\n\nVALUE = missing_fn()\n' > "$repo/self_extra.py"
    commit_all "$repo" "self: import a name that does not exist"
    git_in "$repo" checkout -q peer >/dev/null 2>&1
    printf 'VALUE = 3\n' > "$repo/peer_extra.py"
    commit_all "$repo" "peer: unrelated file"
    git_in "$repo" checkout -q self >/dev/null 2>&1
}

# N5: self depends on a name only PEER supplies. Self alone is broken; the
# merge is the thing that works, and it must not be reported.
case_peer_supplies_name() {
    local repo="$1"
    printf 'def base_fn():\n    return 1\n' > "$repo/lib.py"
    commit_all "$repo" base
    git_in "$repo" branch peer >/dev/null 2>&1
    git_in "$repo" checkout -q -b self >/dev/null 2>&1
    printf 'from lib import peer_helper\n\nRESULT = peer_helper()\n' > "$repo/caller.py"
    commit_all "$repo" "self: call the helper peer is adding"
    git_in "$repo" checkout -q peer >/dev/null 2>&1
    printf 'def base_fn():\n    return 1\n\n\ndef peer_helper():\n    return 2\n' > "$repo/lib.py"
    commit_all "$repo" "peer: add peer_helper"
    git_in "$repo" checkout -q self >/dev/null 2>&1
}

# N6: peer deletes a module AND every importer of it, and self never touched
# it. A deletion is not by itself a finding.
case_deleted_with_importers() {
    local repo="$1"
    mkdir -p "$repo/pkg"
    : > "$repo/pkg/__init__.py"
    printf 'def helper():\n    return 1\n' > "$repo/pkg/util.py"
    printf 'from pkg.util import helper\n\nVALUE = helper()\n' > "$repo/pkg/main.py"
    commit_all "$repo" base
    git_in "$repo" branch peer >/dev/null 2>&1
    git_in "$repo" checkout -q -b self >/dev/null 2>&1
    printf 'VALUE = 1\n' > "$repo/app.py"
    commit_all "$repo" "self: unrelated new file"
    git_in "$repo" checkout -q peer >/dev/null 2>&1
    git_in "$repo" rm -q "pkg/util.py" >/dev/null 2>&1
    printf 'VALUE = 1\n' > "$repo/pkg/main.py"
    commit_all "$repo" "peer: drop util and every caller of it"
    git_in "$repo" checkout -q self >/dev/null 2>&1
}

# ------------------------------------------------------------------ scoring

# run_case <role: positive|negative> <name> <builder>
run_case() {
    local role="$1" name="$2" builder="$3"
    local dir repo merged rc gt_out gt_n json moire_n verdict result

    dir=$(mktemp -d "$TMPDIR_ROOT/case.XXXXXX")
    repo="$dir/repo"
    init_repo "$repo"
    "$builder" "$repo"

    # git's own oracle, not moire's: a case must be textually clean or it is
    # not a case about semantics at all.
    merged=$(git_in "$repo" merge-tree --write-tree self peer 2>/dev/null | head -1)
    rc=$?
    if [ $rc -ne 0 ] || [ -z "$merged" ]; then
        printf '%-11s %-28s FIXTURE-BROKEN (textual conflict)\n' "[$role]" "$name"
        BROKEN_FIXTURES=$((BROKEN_FIXTURES + 1))
        return
    fi

    mkdir -p "$dir/self" "$dir/peer" "$dir/merged"
    git_in "$repo" archive "$(git_in "$repo" rev-parse self^{tree})" | tar -x -C "$dir/self"
    git_in "$repo" archive "$(git_in "$repo" rev-parse peer^{tree})" | tar -x -C "$dir/peer"
    git_in "$repo" archive "$merged" | tar -x -C "$dir/merged"

    gt_out=$(python3 "$PROBE" "$dir/self" "$dir/peer" "$dir/merged" 2>/dev/null)
    gt_n=$(echo "$gt_out" | head -1)
    [ -n "$gt_n" ] || gt_n=0

    json=$(cd "$repo" && MOIRE_GIT="$GIT_PROG" "$MOIRE_BIN" replay self peer --json 2>/dev/null)
    moire_n=$(printf '%s' "$json" | python3 -c '
import json, sys
try:
    rec = json.load(sys.stdin)
except Exception:
    print("x")
    sys.exit(0)
sem = rec.get("semantic") or {}
print(len(sem.get("new_breakage") or []))
' 2>/dev/null)
    verdict=$(printf '%s' "$json" | python3 -c '
import json, sys
try:
    print(json.load(sys.stdin).get("verdict"))
except Exception:
    print("x")
' 2>/dev/null)

    # The fixture has to mean what it says it means, and only the interpreter
    # decides that.
    if [ "$role" = "positive" ] && [ "$gt_n" -eq 0 ]; then
        printf '%-11s %-28s FIXTURE-BROKEN (interpreter found no new failure)\n' "[$role]" "$name"
        BROKEN_FIXTURES=$((BROKEN_FIXTURES + 1))
        return
    fi
    if [ "$role" = "negative" ] && [ "$gt_n" -ne 0 ]; then
        printf '%-11s %-28s FIXTURE-BROKEN (interpreter found %s new failure(s):\n%s\n' \
            "[$role]" "$name" "$gt_n" "$(echo "$gt_out" | tail -n +2 | sed 's/^/                 /')"
        BROKEN_FIXTURES=$((BROKEN_FIXTURES + 1))
        return
    fi

    if [ "$moire_n" = "x" ] || [ -z "$moire_n" ]; then
        printf '%-11s %-28s NO-RECORD (moire produced no usable JSON; verdict=%s)\n' \
            "[$role]" "$name" "$verdict"
        moire_n=0
    fi

    if [ "$role" = "positive" ]; then
        if [ "$moire_n" -gt 0 ]; then
            result="CAUGHT"; CAUGHT=$((CAUGHT + 1))
        else
            result="MISSED"; MISSED=$((MISSED + 1))
        fi
    else
        if [ "$moire_n" -gt 0 ]; then
            result="FALSE POSITIVE"; FALSE_POS=$((FALSE_POS + 1))
        else
            result="ok"; TRUE_NEG=$((TRUE_NEG + 1))
        fi
    fi

    printf '%-11s %-28s truth=%-6s moire=%-2s  %s\n' \
        "[$role]" "$name" \
        "$([ "$gt_n" -gt 0 ] && echo BREAKS || echo clean)" "$moire_n" "$result"
}

main() {
    if [ ! -x "$MOIRE_BIN" ] || [ ! -s "$MOIRE_BIN" ]; then
        echo "FAIL: MOIRE_BIN ($MOIRE_BIN) is missing or not executable"
        exit 1
    fi
    if ! GIT_PROG=$(find_git); then
        echo "FAIL: git >= 2.38 is required (merge-tree --write-tree)"
        exit 1
    fi
    if ! command -v python3 >/dev/null 2>&1; then
        echo "FAIL: python3 is required to compute ground truth"
        exit 1
    fi

    export GIT_AUTHOR_NAME="Benchmark" GIT_AUTHOR_EMAIL="benchmark@example.com"
    export GIT_COMMITTER_NAME="Benchmark" GIT_COMMITTER_EMAIL="benchmark@example.com"
    export GIT_AUTHOR_DATE="2020-01-01T00:00:00+00:00"
    export GIT_COMMITTER_DATE="2020-01-01T00:00:00+00:00"
    export GIT_CONFIG_NOSYSTEM=1

    TMPDIR_ROOT=$(mktemp -d)
    write_probe

    echo "benchmark_recall: $MOIRE_BIN"
    echo "ground truth: CPython $(python3 -c 'import sys; print("%d.%d.%d" % sys.version_info[:3])'), one import per module per tree"
    echo ""

    run_case positive module-deleted            case_module_deleted
    run_case positive module-moved-git-mv       case_module_moved
    run_case positive package-moved             case_package_moved
    run_case positive plain-import-deleted      case_plain_import_deleted
    run_case positive name-removed              case_name_removed
    run_case positive name-renamed              case_name_renamed
    run_case positive signature-changed         case_signature_changed
    run_case positive relative-import-deleted   case_relative_import_deleted
    run_case negative thirdparty-both-sides     case_thirdparty_both_sides
    run_case negative thirdparty-one-side       case_thirdparty_one_side
    run_case negative rename-carries-breakage   case_rename_carries_breakage
    run_case negative self-preexisting-breakage case_self_preexisting_breakage
    run_case negative peer-supplies-name        case_peer_supplies_name
    run_case negative deleted-with-importers    case_deleted_with_importers

    local positives=$((CAUGHT + MISSED))
    local negatives=$((TRUE_NEG + FALSE_POS))
    echo ""
    echo "recall:          $CAUGHT of $positives collisions the interpreter confirms"
    echo "false positives: $FALSE_POS of $negatives clean merges reported as broken"
    if [ "$BROKEN_FIXTURES" -gt 0 ]; then
        echo "broken fixtures: $BROKEN_FIXTURES (a case whose ground truth contradicts its role)"
        exit 1
    fi
    if [ "$FALSE_POS" -gt 0 ]; then
        exit 1
    fi
    if [ "$CAUGHT" -lt "$RECALL_FLOOR" ]; then
        echo "below the recorded floor of $RECALL_FLOOR"
        exit 1
    fi
    exit 0
}

main "$@"
