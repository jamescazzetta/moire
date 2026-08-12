#!/bin/bash

# test_verify.sh - Verify `moire verify`'s semantic path (V1-V36)
#
# `moire check` is textual only and is covered by tests/test_oracle.sh.
# `moire verify` additionally materialises self/peer/merged trees and runs a
# checker over each, reporting new_breakage = broken(merged) - broken(self) -
# broken(peer). This suite is that path's only coverage, including:
#   - the headline "clean merge that breaks something" claim (V1-V5)
#   - external-checker findings not exploded into characters (V6-V7)
#   - the semantic pass now running under a textual conflict, builtin-ast
#     only, with conflict-path exclusion (V8-V10)
#   - self checked once per `verify` call, not once per peer (V11)
#   - --link, for non-Python checkers that need a dependency directory (V12-V14)
#   - `report`/`report --study` surfacing the semantic dimension (V15-V16)
#   - no DeprecationWarning noise on Python >= 3.12 (V17)
#   - doctor's new [warn] level for a missing dependency dir (V18)
#   - the checker never claiming "semantic ok" about a tree it could not
#     read, and such a record staying out of the base rate (V19-V20, V23)
#   - per-repo checker/link from `git config`, and doctor catching an
#     inapplicable default checker at setup time (V21-V22, V24)
#   - `report`'s rates being over distinct pair-states and its finding counts
#     over distinct finding_ids, never over observations (V25-V28, V30)
#   - a finding computed from a cached peer snapshot being re-derived against
#     the peer's current state before it is emitted (V29)
#   - the two reproduced false-BROKEN classes: a peer's `git mv` relocating
#     self's own pre-existing breakage (V31-V33) and a peer-installed entry
#     missing from the merged tree's borrowed directory (V34-V35)
#   - names bound by top-level compound statements (V36)
#
# Exit 0 only if all cases pass; else exit 1 with failure count.

set -u

# Resolve paths relative to this script's own location, not the caller's cwd,
# so the suite runs the same from any working directory.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

# Counters
PASSED=0
FAILED=0
SKIPPED=0

# Global state
TMPDIR_ROOT=""
GIT_PROG=""
MOIRE_BIN="${MOIRE_BIN:-$REPO_ROOT/bin/moire}"

# Cleanup function. Every fixture directory this suite creates is nested
# under TMPDIR_ROOT (see new_case_dir), so any worktree `moire verify`
# registers as a sibling of a fixture's repo/ lands inside this boundary too
# -- a single `rm -rf` here removes it, even if a test's own per-function
# cleanup is skipped by an early `return` on failure. An earlier suite in
# this project shipped a fixture whose worktrees lived OUTSIDE this
# boundary and orphaned 13-24 of them per run; this suite does not repeat
# that mistake.
cleanup() {
    if [ -n "$TMPDIR_ROOT" ] && [ -d "$TMPDIR_ROOT" ]; then
        rm -rf "$TMPDIR_ROOT"
    fi
}
trap cleanup EXIT

# Find git >= 2.38
find_git() {
    local candidate prog

    # 1. Check MOIRE_GIT env var
    if [ -n "${MOIRE_GIT:-}" ] && [ -x "$MOIRE_GIT" ]; then
        if git_version_ge "$MOIRE_GIT" 2 38; then
            echo "$MOIRE_GIT"
            return 0
        fi
    fi

    # 2. Try /opt/homebrew/bin/git
    if [ -x "/opt/homebrew/bin/git" ]; then
        if git_version_ge "/opt/homebrew/bin/git" 2 38; then
            echo "/opt/homebrew/bin/git"
            return 0
        fi
    fi

    # 3. Try git from PATH
    if prog=$(command -v git 2>/dev/null); then
        if git_version_ge "$prog" 2 38; then
            echo "$prog"
            return 0
        fi
    fi

    return 1
}

# Check if git version >= major.minor
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

# Setup deterministic git environment
setup_git_env() {
    export GIT_AUTHOR_NAME="Test Author"
    export GIT_AUTHOR_EMAIL="test@example.com"
    export GIT_AUTHOR_DATE="2020-01-01T00:00:00+00:00"
    export GIT_COMMITTER_NAME="Test Committer"
    export GIT_COMMITTER_EMAIL="test@example.com"
    export GIT_COMMITTER_DATE="2020-01-01T00:00:00+00:00"
}

# Run a git command in a repo
git_in() {
    local repo="$1"
    shift
    (cd "$repo" && "$GIT_PROG" "$@")
}

# Report test result
report_result() {
    local num="$1" name="$2" status="$3" msg="${4:-}"
    local line

    line="$status $num $name"
    if [ -n "$msg" ]; then
        line="$line ($msg)"
    fi
    echo "$line"

    case "$status" in
        PASS) ((PASSED++)) ;;
        FAIL) ((FAILED++)) ;;
        SKIP) ((SKIPPED++)) ;;
    esac
}

# Extract a field from JSON output using python3 (supports nested keys like 'self.agent_id')
json_get() {
    local json="$1" field="$2" index="${3:-0}"
    python3 -c "
import json, sys
try:
    data = json.loads('''$json''')
    if isinstance(data, list):
        data = data[$index]
    # Handle nested keys like 'self.agent_id'
    keys = '$field'.split('.')
    for key in keys:
        if isinstance(data, dict):
            data = data.get(key, '')
        else:
            data = ''
            break
    if data == '' or data is None:
        sys.exit(1)
    print(data)
except:
    sys.exit(1)
" 2>/dev/null
}

# Check if a field exists in JSON (supports nested keys)
json_has() {
    local json="$1" field="$2" index="${3:-0}"
    python3 -c "
import json, sys
try:
    data = json.loads('''$json''')
    if isinstance(data, list):
        data = data[$index]
    # Handle nested keys
    keys = '$field'.split('.')
    for key in keys[:-1]:
        if isinstance(data, dict):
            data = data.get(key, {})
        else:
            print('no')
            sys.exit(0)
    print('yes' if (isinstance(data, dict) and keys[-1] in data) else 'no')
except:
    print('error')
" 2>/dev/null
}

# Count records in JSON array
json_count() {
    local json="$1"
    python3 -c "
import json, sys
try:
    data = json.loads('''$json''')
    if isinstance(data, list):
        print(len(data))
    else:
        print(1)
except:
    print(0)
" 2>/dev/null
}

# Get boolean value from JSON (supports nested keys like 'self.agent_id')
json_bool() {
    local json="$1" field="$2" index="${3:-0}"
    python3 -c "
import json, sys
try:
    data = json.loads('''$json''')
    if isinstance(data, list):
        data = data[$index]
    # Handle nested keys
    keys = '$field'.split('.')
    for key in keys:
        if isinstance(data, dict):
            data = data.get(key, False)
        else:
            data = False
            break
    print('true' if data else 'false')
except:
    print('error')
" 2>/dev/null
}

# A fixture directory nested one level inside TMPDIR_ROOT (see cleanup()
# above for why). Every repo/, peer/, peer1/, peer2/... this suite creates
# lives under one of these.
new_case_dir() {
    local label="$1"
    mktemp -d "$TMPDIR_ROOT/${label}.XXXXXX"
}

# Run `moire verify --json` from $1 with extra args $2..., dropping stderr.
run_verify_json() {
    local repo="$1"
    shift
    (cd "$repo" && MOIRE_GIT="$GIT_PROG" "$MOIRE_BIN" verify --json "$@" 2>/dev/null)
}

# Run `moire verify` (human output) from $1 with extra args $2..., dropping stderr.
run_verify_human() {
    local repo="$1"
    shift
    (cd "$repo" && MOIRE_GIT="$GIT_PROG" "$MOIRE_BIN" verify "$@" 2>/dev/null)
}

# git_in wrapper for the common "init a repo with a base commit" prologue.
init_repo() {
    local repo="$1"
    git_in "$repo" init >/dev/null 2>&1
    git_in "$repo" config user.name "Test"
    git_in "$repo" config user.email "test@example.com"
}

# === FIXTURE BUILDERS ===
# Each takes a repo dir (not yet created) and leaves branch_a checked out,
# with branch_b as a plain ref (not yet a worktree - callers add that).

# V1: disjoint edits to different files, no cross-module reference at all.
fixture_v1() {
    local repo="$1"
    init_repo "$repo"
    printf 'x = 1\n' > "$repo/a.py"
    printf 'y = 2\n' > "$repo/b.py"
    git_in "$repo" add -A
    git_in "$repo" commit -qm base >/dev/null 2>&1
    local base; base=$(git_in "$repo" rev-parse HEAD)

    git_in "$repo" checkout -q -b branch_a >/dev/null 2>&1
    printf 'x = 11\n' > "$repo/a.py"
    git_in "$repo" commit -qam "self: edit a.py" >/dev/null 2>&1

    git_in "$repo" checkout -q "$base" >/dev/null 2>&1
    git_in "$repo" checkout -q -b branch_b >/dev/null 2>&1
    printf 'y = 22\n' > "$repo/b.py"
    git_in "$repo" commit -qam "peer: edit b.py" >/dev/null 2>&1

    git_in "$repo" checkout -q branch_a >/dev/null 2>&1
}

# V2: the canonical case. Self renames a function in lib.py and updates its
# OWN callers; peer adds a brand-new file that imports the old name. File
# sets are disjoint (lib.py/main.py vs peer_caller.py) so the textual merge
# is clean, but the merged tree is semantically broken: peer_caller.py
# imports a name self just deleted.
fixture_v2() {
    local repo="$1"
    init_repo "$repo"
    printf 'def old_name():\n    return 1\n' > "$repo/lib.py"
    printf 'from lib import old_name\nold_name()\n' > "$repo/main.py"
    git_in "$repo" add -A
    git_in "$repo" commit -qm base >/dev/null 2>&1
    local base; base=$(git_in "$repo" rev-parse HEAD)

    git_in "$repo" checkout -q -b branch_a >/dev/null 2>&1
    printf 'def new_name():\n    return 1\n' > "$repo/lib.py"
    printf 'from lib import new_name\nnew_name()\n' > "$repo/main.py"
    git_in "$repo" commit -qam "self: rename old_name -> new_name, update caller" >/dev/null 2>&1

    git_in "$repo" checkout -q "$base" >/dev/null 2>&1
    git_in "$repo" checkout -q -b branch_b >/dev/null 2>&1
    printf 'from lib import old_name\nold_name()\n' > "$repo/peer_caller.py"
    git_in "$repo" add -A
    git_in "$repo" commit -qam "peer: add new caller of old_name" >/dev/null 2>&1

    git_in "$repo" checkout -q branch_a >/dev/null 2>&1
}

# V3: self's OWN branch introduces a broken import in a self-owned file
# (self.py), disjoint from whatever peer does. self_broken already contains
# it, so it must cancel out of new_breakage even though merged_broken > 0.
fixture_v3() {
    local repo="$1"
    init_repo "$repo"
    printf 'def something():\n    return 1\n' > "$repo/lib.py"
    git_in "$repo" add -A
    git_in "$repo" commit -qm base >/dev/null 2>&1
    local base; base=$(git_in "$repo" rev-parse HEAD)

    git_in "$repo" checkout -q -b branch_a >/dev/null 2>&1
    printf 'from lib import missing_fn\nmissing_fn()\n' > "$repo/self_extra.py"
    git_in "$repo" add -A
    git_in "$repo" commit -qam "self: introduces its own broken import" >/dev/null 2>&1

    git_in "$repo" checkout -q "$base" >/dev/null 2>&1
    git_in "$repo" checkout -q -b branch_b >/dev/null 2>&1
    printf 'z = 3\n' > "$repo/peer_extra.py"
    git_in "$repo" add -A
    git_in "$repo" commit -qam "peer: unrelated disjoint file" >/dev/null 2>&1

    git_in "$repo" checkout -q branch_a >/dev/null 2>&1
}

# V4: mirror of V3 - peer's OWN branch introduces the broken import.
fixture_v4() {
    local repo="$1"
    init_repo "$repo"
    printf 'def something():\n    return 1\n' > "$repo/lib.py"
    git_in "$repo" add -A
    git_in "$repo" commit -qm base >/dev/null 2>&1
    local base; base=$(git_in "$repo" rev-parse HEAD)

    git_in "$repo" checkout -q -b branch_a >/dev/null 2>&1
    printf 'z = 3\n' > "$repo/self_extra.py"
    git_in "$repo" add -A
    git_in "$repo" commit -qam "self: unrelated disjoint file" >/dev/null 2>&1

    git_in "$repo" checkout -q "$base" >/dev/null 2>&1
    git_in "$repo" checkout -q -b branch_b >/dev/null 2>&1
    printf 'from lib import missing_fn2\nmissing_fn2()\n' > "$repo/peer_extra.py"
    git_in "$repo" add -A
    git_in "$repo" commit -qam "peer: introduces its own broken import" >/dev/null 2>&1

    git_in "$repo" checkout -q branch_a >/dev/null 2>&1
}

# V6/V7: external-checker fixture. Each branch adds a file the OTHER branch
# lacks (a_only.txt / b_only.txt); a checker that only fires when BOTH exist
# therefore fires in the merged tree only, never in self's or peer's own
# tree (each has just one of the two).
fixture_v6() {
    local repo="$1"
    init_repo "$repo"
    printf 'base\n' > "$repo/README.txt"
    git_in "$repo" add -A
    git_in "$repo" commit -qm base >/dev/null 2>&1
    local base; base=$(git_in "$repo" rev-parse HEAD)

    git_in "$repo" checkout -q -b branch_a >/dev/null 2>&1
    printf 'only in self\n' > "$repo/a_only.txt"
    git_in "$repo" add -A
    git_in "$repo" commit -qam "self: adds a_only.txt" >/dev/null 2>&1

    git_in "$repo" checkout -q "$base" >/dev/null 2>&1
    git_in "$repo" checkout -q -b branch_b >/dev/null 2>&1
    printf 'only in peer\n' > "$repo/b_only.txt"
    git_in "$repo" add -A
    git_in "$repo" commit -qam "peer: adds b_only.txt" >/dev/null 2>&1

    git_in "$repo" checkout -q branch_a >/dev/null 2>&1
}

# V8/V9: a genuine textual conflict on shared.py (both sides edit the same
# line of a docstring differently - markers land INSIDE the triple-quoted
# string, so the merged shared.py stays valid, parseable Python) PLUS a
# disjoint cross-module break: self renames lib.py's function and updates
# its own caller (main.py); peer adds caller.py importing the old name.
# Neither shared.py nor either party's own tree carries the cross-module
# break - only the merged tree does.
fixture_v8() {
    local repo="$1"
    init_repo "$repo"
    printf 'def old_name():\n    return 1\n' > "$repo/lib.py"
    printf 'from lib import old_name\nold_name()\n' > "$repo/main.py"
    printf 'line1\n' > "$repo/shared.py"
    git_in "$repo" add -A
    git_in "$repo" commit -qm base >/dev/null 2>&1
    local base; base=$(git_in "$repo" rev-parse HEAD)

    git_in "$repo" checkout -q -b branch_a >/dev/null 2>&1
    printf 'def new_name():\n    return 1\n' > "$repo/lib.py"
    printf 'from lib import new_name\nnew_name()\n' > "$repo/main.py"
    printf 'line1 A\n' > "$repo/shared.py"
    git_in "$repo" commit -qam "self: rename + conflicting shared.py edit" >/dev/null 2>&1

    git_in "$repo" checkout -q "$base" >/dev/null 2>&1
    git_in "$repo" checkout -q -b branch_b >/dev/null 2>&1
    printf 'from lib import old_name\nold_name()\n' > "$repo/caller.py"
    printf 'line1 B\n' > "$repo/shared.py"
    git_in "$repo" add -A
    git_in "$repo" commit -qam "peer: add caller.py + conflicting shared.py edit" >/dev/null 2>&1

    git_in "$repo" checkout -q branch_a >/dev/null 2>&1
}

# V10: the excluded-breakage case. shared.py has an import statement that
# survives untouched by either side (so it stays parseable post-merge), but
# a docstring line just above it conflicts (same trick as V8/V9), making
# shared.py itself one of conflict_paths. Self (via a change confined to
# lib.py, never touching shared.py) renames the function shared.py imports;
# self ALSO adds the import to shared.py so the break exists ONLY in the
# merged tree, never in self's or peer's own tree - the only reason it does
# not survive into new_breakage is the conflict-path exclusion, not V3/V4's
# already-broken cancellation.
fixture_v10() {
    local repo="$1"
    init_repo "$repo"
    printf 'def old_name():\n    return 1\n' > "$repo/lib.py"
    printf 'DOC = """\nline1\n"""\n' > "$repo/shared.py"
    git_in "$repo" add -A
    git_in "$repo" commit -qm base >/dev/null 2>&1
    local base; base=$(git_in "$repo" rev-parse HEAD)

    git_in "$repo" checkout -q -b branch_a >/dev/null 2>&1
    printf 'DOC = """\nline1 A\n"""\nfrom lib import old_name\nold_name()\n' > "$repo/shared.py"
    git_in "$repo" commit -qam "self: doc edit A + adds import of old_name" >/dev/null 2>&1

    git_in "$repo" checkout -q "$base" >/dev/null 2>&1
    git_in "$repo" checkout -q -b branch_b >/dev/null 2>&1
    printf 'def new_name():\n    return 1\n' > "$repo/lib.py"
    printf 'DOC = """\nline1 B\n"""\n' > "$repo/shared.py"
    git_in "$repo" commit -qam "peer: rename old_name -> new_name + doc edit B" >/dev/null 2>&1

    git_in "$repo" checkout -q branch_a >/dev/null 2>&1
}

# V11: self has an unrelated, always-present broken import (orphan.py) so
# self_broken is nonzero for every peer. peer1 triggers V2-style new
# breakage; peer2 is fully unrelated (empty new_breakage). Used to compare
# a two-peer run against each peer run solo.
fixture_v11() {
    local repo="$1"
    init_repo "$repo"
    printf 'def old_name():\n    return 1\n' > "$repo/lib.py"
    git_in "$repo" add -A
    git_in "$repo" commit -qm base >/dev/null 2>&1
    local base; base=$(git_in "$repo" rev-parse HEAD)

    git_in "$repo" checkout -q -b branch_a >/dev/null 2>&1
    printf 'def new_name():\n    return 1\n' > "$repo/lib.py"
    printf 'from lib import new_name\nnew_name()\n' > "$repo/self_caller.py"
    printf 'from lib import ghost_fn\nghost_fn()\n' > "$repo/orphan.py"
    git_in "$repo" add -A
    git_in "$repo" commit -qam "self: rename + own caller + pre-existing broken orphan" >/dev/null 2>&1

    git_in "$repo" checkout -q "$base" >/dev/null 2>&1
    git_in "$repo" checkout -q -b branch_b1 >/dev/null 2>&1
    printf 'from lib import old_name\nold_name()\n' > "$repo/peer1_caller.py"
    git_in "$repo" add -A
    git_in "$repo" commit -qam "peer1: add caller of old_name" >/dev/null 2>&1

    git_in "$repo" checkout -q "$base" >/dev/null 2>&1
    git_in "$repo" checkout -q -b branch_b2 >/dev/null 2>&1
    printf 'x = 1\n' > "$repo/peer2_extra.py"
    git_in "$repo" add -A
    git_in "$repo" commit -qam "peer2: unrelated" >/dev/null 2>&1

    git_in "$repo" checkout -q branch_a >/dev/null 2>&1
}

# V12/V13/V14: a plain disjoint-edit clean merge (verdict doesn't matter to
# --link itself); the interesting part is a gitignored deps/ directory
# created directly in the worktree after the repo is built.
fixture_v12() {
    local repo="$1"
    init_repo "$repo"
    printf 'a\n' > "$repo/a.txt"
    printf 'b\n' > "$repo/b.txt"
    printf 'deps/\n' > "$repo/.gitignore"
    git_in "$repo" add -A
    git_in "$repo" commit -qm base >/dev/null 2>&1
    local base; base=$(git_in "$repo" rev-parse HEAD)

    git_in "$repo" checkout -q -b branch_a >/dev/null 2>&1
    printf 'a self\n' > "$repo/a.txt"
    git_in "$repo" commit -qam "self edit a.txt" >/dev/null 2>&1

    git_in "$repo" checkout -q "$base" >/dev/null 2>&1
    git_in "$repo" checkout -q -b branch_b >/dev/null 2>&1
    printf 'b peer\n' > "$repo/b.txt"
    git_in "$repo" commit -qam "peer edit b.txt" >/dev/null 2>&1

    git_in "$repo" checkout -q branch_a >/dev/null 2>&1
}

# V18: a trivial repo with a gitignored deps/ directory, built AFTER the
# peer worktree exists so the peer worktree never gets it (git worktree add
# only checks out tracked files).
fixture_v18() {
    local repo="$1"
    init_repo "$repo"
    printf 'a\n' > "$repo/a.txt"
    printf 'deps/\n' > "$repo/.gitignore"
    git_in "$repo" add -A
    git_in "$repo" commit -qm base >/dev/null 2>&1
}

# V19/V23: fixture_v2's shape in a language the builtin checker cannot read.
# Self renames validateSession -> validateSessionV2 and updates its own
# importer; peer adds src/service.ts importing the OLD name. File sets are
# disjoint, so the textual merge is clean and the merged tree is genuinely
# broken - but builtin-ast reads only Python, so it examines nothing. This
# is the one state whose "no findings" means "no check", and reporting it
# as "semantic ok" is the defect V19 pins.
fixture_v19() {
    local repo="$1"
    init_repo "$repo"
    mkdir -p "$repo/src"
    printf 'export function validateSession(token: string): boolean {\n  return token.length > 0;\n}\n' > "$repo/src/auth.ts"
    printf 'import { validateSession } from "./auth";\nexport const ok = validateSession("x");\n' > "$repo/src/main.ts"
    printf '{"name":"ts-repro"}\n' > "$repo/package.json"
    git_in "$repo" add -A
    git_in "$repo" commit -qm base >/dev/null 2>&1
    local base; base=$(git_in "$repo" rev-parse HEAD)

    git_in "$repo" checkout -q -b branch_a >/dev/null 2>&1
    printf 'export function validateSessionV2(token: string): boolean {\n  return token.length > 0;\n}\n' > "$repo/src/auth.ts"
    printf 'import { validateSessionV2 } from "./auth";\nexport const ok = validateSessionV2("x");\n' > "$repo/src/main.ts"
    git_in "$repo" commit -qam "self: rename validateSession -> validateSessionV2" >/dev/null 2>&1

    git_in "$repo" checkout -q "$base" >/dev/null 2>&1
    git_in "$repo" checkout -q -b branch_b >/dev/null 2>&1
    printf 'import { validateSession } from "./auth";\nexport function service(t: string) { return validateSession(t); }\n' > "$repo/src/service.ts"
    git_in "$repo" add -A
    git_in "$repo" commit -qm "peer: add src/service.ts importing validateSession" >/dev/null 2>&1

    git_in "$repo" checkout -q branch_a >/dev/null 2>&1
}

# === TEST CASES ===

# ---- Core semantics: the headline "clean merge that breaks something"
# ---- claim, which README.md asserts tests/ covers and which, before this
# ---- suite, it did not.

test_v1_clean_disjoint() {
    local num=1 name="clean-disjoint-nothing-broken"
    local test_dir; test_dir=$(new_case_dir "v$num")
    trap "rm -rf '$test_dir'" RETURN
    local repo="$test_dir/repo"
    mkdir -p "$repo"
    fixture_v1 "$repo" >/dev/null 2>&1

    if ! git_in "$repo" worktree add -q "$test_dir/peer" branch_b >/dev/null 2>&1; then
        report_result $num "$name" "SKIP" "could not add peer worktree"
        return
    fi

    local json rc
    json=$(run_verify_json "$repo")
    rc=$?
    if [ "$rc" -ne 0 ]; then
        report_result $num "$name" "FAIL" "moire verify exited $rc"
        return
    fi

    local verdict; verdict=$(json_get "$json" "verdict" 0)
    local nb_empty
    nb_empty=$(python3 -c "
import json
r = json.loads('''$json''')[0]
print('yes' if r['semantic']['new_breakage'] == [] else 'no')
" 2>/dev/null)

    if [ "$verdict" = "clean" ] && [ "$nb_empty" = "yes" ]; then
        report_result $num "$name" "PASS"
    else
        report_result $num "$name" "FAIL" "verdict=$verdict new_breakage_empty=$nb_empty"
    fi
}

test_v2_canonical_case() {
    local num=2 name="canonical-rename-vs-new-importer"
    local test_dir; test_dir=$(new_case_dir "v$num")
    trap "rm -rf '$test_dir'" RETURN
    local repo="$test_dir/repo"
    mkdir -p "$repo"
    fixture_v2 "$repo" >/dev/null 2>&1

    if ! git_in "$repo" worktree add -q "$test_dir/peer" branch_b >/dev/null 2>&1; then
        report_result $num "$name" "SKIP" "could not add peer worktree"
        return
    fi

    local json rc
    json=$(run_verify_json "$repo")
    rc=$?
    if [ "$rc" -ne 0 ]; then
        report_result $num "$name" "FAIL" "moire verify exited $rc"
        return
    fi

    local verdict; verdict=$(json_get "$json" "verdict" 0)
    local summary
    summary=$(python3 -c "
import json
r = json.loads('''$json''')[0]
nb = r['semantic']['new_breakage']
if len(nb) != 1:
    print('BADCOUNT', len(nb))
else:
    entry = nb[0]
    path = entry[0] if isinstance(entry, list) else entry
    print('OK' if path == 'peer_caller.py' else 'BADPATH', path)
" 2>/dev/null)
    local status detail
    read -r status detail <<<"$summary"

    if [ "$verdict" = "clean" ] && [ "$status" = "OK" ]; then
        report_result $num "$name" "PASS"
    else
        report_result $num "$name" "FAIL" "verdict=$verdict new_breakage_check=$status $detail"
    fi
}

test_v3_self_preexisting_cancels() {
    local num=3 name="self-preexisting-breakage-cancels"
    local test_dir; test_dir=$(new_case_dir "v$num")
    trap "rm -rf '$test_dir'" RETURN
    local repo="$test_dir/repo"
    mkdir -p "$repo"
    fixture_v3 "$repo" >/dev/null 2>&1

    if ! git_in "$repo" worktree add -q "$test_dir/peer" branch_b >/dev/null 2>&1; then
        report_result $num "$name" "SKIP" "could not add peer worktree"
        return
    fi

    local json rc
    json=$(run_verify_json "$repo")
    rc=$?
    if [ "$rc" -ne 0 ]; then
        report_result $num "$name" "FAIL" "moire verify exited $rc"
        return
    fi

    local summary
    summary=$(python3 -c "
import json
r = json.loads('''$json''')[0]
sem = r['semantic']
print(r['verdict'], sem['merged_broken'], len(sem['new_breakage']))
" 2>/dev/null)
    local verdict merged_broken nb_len
    read -r verdict merged_broken nb_len <<<"$summary"

    if [ "$verdict" = "clean" ] && [ "$merged_broken" -gt 0 ] && [ "$nb_len" -eq 0 ]; then
        report_result $num "$name" "PASS"
    else
        report_result $num "$name" "FAIL" "verdict=$verdict merged_broken=$merged_broken new_breakage_len=$nb_len"
    fi
}

test_v4_peer_preexisting_cancels() {
    local num=4 name="peer-preexisting-breakage-cancels"
    local test_dir; test_dir=$(new_case_dir "v$num")
    trap "rm -rf '$test_dir'" RETURN
    local repo="$test_dir/repo"
    mkdir -p "$repo"
    fixture_v4 "$repo" >/dev/null 2>&1

    if ! git_in "$repo" worktree add -q "$test_dir/peer" branch_b >/dev/null 2>&1; then
        report_result $num "$name" "SKIP" "could not add peer worktree"
        return
    fi

    local json rc
    json=$(run_verify_json "$repo")
    rc=$?
    if [ "$rc" -ne 0 ]; then
        report_result $num "$name" "FAIL" "moire verify exited $rc"
        return
    fi

    local summary
    summary=$(python3 -c "
import json
r = json.loads('''$json''')[0]
sem = r['semantic']
print(r['verdict'], sem['merged_broken'], len(sem['new_breakage']))
" 2>/dev/null)
    local verdict merged_broken nb_len
    read -r verdict merged_broken nb_len <<<"$summary"

    if [ "$verdict" = "clean" ] && [ "$merged_broken" -gt 0 ] && [ "$nb_len" -eq 0 ]; then
        report_result $num "$name" "PASS"
    else
        report_result $num "$name" "FAIL" "verdict=$verdict merged_broken=$merged_broken new_breakage_len=$nb_len"
    fi
}

test_v5_warn_only_exit_zero() {
    local num=5 name="warn-only-exit-zero-even-when-broken"
    local test_dir; test_dir=$(new_case_dir "v$num")
    trap "rm -rf '$test_dir'" RETURN
    local repo="$test_dir/repo"
    mkdir -p "$repo"
    # Reuse V2's fixture: it reliably produces non-empty new_breakage.
    fixture_v2 "$repo" >/dev/null 2>&1

    if ! git_in "$repo" worktree add -q "$test_dir/peer" branch_b >/dev/null 2>&1; then
        report_result $num "$name" "SKIP" "could not add peer worktree"
        return
    fi

    local json rc
    json=$(cd "$repo" && MOIRE_GIT="$GIT_PROG" "$MOIRE_BIN" verify --json 2>/dev/null)
    rc=$?

    local nb_len
    nb_len=$(python3 -c "
import json
r = json.loads('''$json''')[0]
print(len(r['semantic']['new_breakage']))
" 2>/dev/null)

    if [ "$rc" -eq 0 ] && [ "${nb_len:-0}" -gt 0 ]; then
        report_result $num "$name" "PASS"
    else
        report_result $num "$name" "FAIL" "exit=$rc new_breakage_len=${nb_len:-?} (expected exit 0 with breakage present)"
    fi
}

# ---- A2: external-checker findings must not be exploded into characters.

test_v6_v7_external_checker_whole_string() {
    local num=6 name="external-checker-finding-is-whole-string"
    local test_dir; test_dir=$(new_case_dir "v$num")
    trap "rm -rf '$test_dir'" RETURN
    local repo="$test_dir/repo"
    mkdir -p "$repo"
    fixture_v6 "$repo" >/dev/null 2>&1

    if ! git_in "$repo" worktree add -q "$test_dir/peer" branch_b >/dev/null 2>&1; then
        report_result $num "$name" "SKIP" "could not add peer worktree"
        report_result 7 "finding-path-not-truncated-to-one-char" "SKIP" "could not add peer worktree"
        return
    fi

    # Only fires when BOTH a_only.txt and b_only.txt are present, i.e. only
    # in the merged tree - see fixture_v6.
    local checker='[ -f a_only.txt ] && [ -f b_only.txt ] && echo "src/x.ts(4,1): error TS2551: no such export" || true'
    local json rc
    json=$(run_verify_json "$repo" --checker "$checker")
    rc=$?
    if [ "$rc" -ne 0 ]; then
        report_result $num "$name" "FAIL" "moire verify exited $rc"
        report_result 7 "finding-path-not-truncated-to-one-char" "FAIL" "moire verify exited $rc"
        return
    fi

    local self_wt peer_wt
    self_wt=$(cd "$repo" && pwd -P)
    peer_wt=$(cd "$test_dir/peer" && pwd -P)

    # The checker string itself (echoed diagnostic line) contains double
    # quotes, which come back escaped inside the JSON's "checker" field.
    # Embedding that raw text into a python triple-quoted string (as
    # json_get/json_has do, and as most other cases here do) corrupts it:
    # python's own string-literal parsing consumes the backslash before
    # json.loads ever sees it. Route through a file instead, same as
    # test_study.sh's test_004/006/007 do for their more complex cases.
    local json_file="$test_dir/v6.json"
    printf '%s' "$json" > "$json_file"

    # V6: the logged entry is one whole string of length > 1, not an
    # exploded list of single characters.
    local summary
    summary=$(python3 -c "
import json
r = json.load(open('$json_file'))[0]
nb = r['semantic']['new_breakage']
if len(nb) != 1:
    print('BADCOUNT', len(nb), '')
else:
    entry = nb[0]
    print('OK' if (isinstance(entry, str) and len(entry) > 1) else 'BAD', len(nb), type(entry).__name__)
" 2>/dev/null)
    local status count kind
    read -r status count kind <<<"$summary"

    if [ "$status" = "OK" ]; then
        report_result $num "$name" "PASS"
    else
        report_result $num "$name" "FAIL" "new_breakage=$count entries, entry type=$kind (expected 1 string)"
    fi

    # V7: finding_id must be non-null and computed from the WHOLE line, not
    # its first character. Recompute the expected id with the same
    # algorithm as compute_finding_id() in bin/moire and compare.
    local fid; fid=$(python3 -c "
import json
r = json.load(open('$json_file'))[0]
print(r.get('finding_id') or '')
" 2>/dev/null)
    local expected
    expected=$(python3 -c "
import hashlib
self_wt, peer_wt = sorted(('$self_wt', '$peer_wt'))
line = 'src/x.ts(4,1): error TS2551: no such export'
h = hashlib.sha1()
for part in (self_wt, peer_wt, line):
    h.update(part.encode('utf-8'))
    h.update(b'\x00')
print(h.hexdigest()[:12])
" 2>/dev/null)

    if [ -n "$fid" ] && [ "$fid" = "$expected" ]; then
        report_result 7 "finding-path-not-truncated-to-one-char" "PASS"
    else
        report_result 7 "finding-path-not-truncated-to-one-char" "FAIL" \
            "finding_id=$fid expected(from whole line)=$expected"
    fi
}

# ---- A4: semantic pass runs under a textual conflict, builtin-ast only.

test_v8_builtin_runs_under_conflict() {
    local num=8 name="builtin-checker-runs-under-textual-conflict"
    local test_dir; test_dir=$(new_case_dir "v$num")
    trap "rm -rf '$test_dir'" RETURN
    local repo="$test_dir/repo"
    mkdir -p "$repo"
    fixture_v8 "$repo" >/dev/null 2>&1

    if ! git_in "$repo" worktree add -q "$test_dir/peer" branch_b >/dev/null 2>&1; then
        report_result $num "$name" "SKIP" "could not add peer worktree"
        return
    fi

    local json rc
    json=$(run_verify_json "$repo")
    rc=$?
    if [ "$rc" -ne 0 ]; then
        report_result $num "$name" "FAIL" "moire verify exited $rc"
        return
    fi

    local summary
    summary=$(python3 -c "
import json
r = json.loads('''$json''')[0]
verdict = r['verdict']
sem = r['semantic']
is_dict = isinstance(sem, dict)
under = sem.get('under_conflict') if is_dict else None
nb = sem.get('new_breakage') if is_dict else []
names_caller = any((x[0] if isinstance(x, list) else x) == 'caller.py' for x in (nb or []))
print(verdict, is_dict, under, names_caller)
" 2>/dev/null)
    local verdict is_dict under names_caller
    read -r verdict is_dict under names_caller <<<"$summary"

    local human
    human=$(run_verify_human "$repo")
    local has_conflict_block has_broken_block
    has_conflict_block=no; echo "$human" | grep -q "^CONFLICT with" && has_conflict_block=yes
    has_broken_block=no; echo "$human" | grep -q "^BROKEN " && has_broken_block=yes

    if [ "$verdict" = "conflict" ] && [ "$is_dict" = "True" ] && [ "$under" = "True" ] \
       && [ "$names_caller" = "True" ] && [ "$has_conflict_block" = "yes" ] && [ "$has_broken_block" = "yes" ]; then
        report_result $num "$name" "PASS"
    else
        report_result $num "$name" "FAIL" \
            "verdict=$verdict semantic_is_dict=$is_dict under_conflict=$under names_caller=$names_caller CONFLICT_block=$has_conflict_block BROKEN_block=$has_broken_block"
    fi
}

test_v9_external_checker_refuses_under_conflict() {
    local num=9 name="external-checker-refuses-under-conflict"
    local test_dir; test_dir=$(new_case_dir "v$num")
    trap "rm -rf '$test_dir'" RETURN
    local repo="$test_dir/repo"
    mkdir -p "$repo"
    fixture_v8 "$repo" >/dev/null 2>&1

    if ! git_in "$repo" worktree add -q "$test_dir/peer" branch_b >/dev/null 2>&1; then
        report_result $num "$name" "SKIP" "could not add peer worktree"
        return
    fi

    local json rc
    json=$(run_verify_json "$repo" --checker 'echo something')
    rc=$?
    if [ "$rc" -ne 0 ]; then
        report_result $num "$name" "FAIL" "moire verify exited $rc"
        return
    fi

    local verdict sem_is_null conflict_count
    verdict=$(json_get "$json" "verdict" 0)
    sem_is_null=$(python3 -c "
import json
r = json.loads('''$json''')[0]
print('yes' if r['semantic'] is None else 'no')
" 2>/dev/null)
    conflict_count=$(python3 -c "
import json
r = json.loads('''$json''')[0]
print(len(r['conflict_paths']))
" 2>/dev/null)

    local human
    human=$(run_verify_human "$repo" --checker 'echo something')
    local says_not_attempted names_count
    says_not_attempted=no
    echo "$human" | grep -q "semantic check not attempted" && says_not_attempted=yes
    names_count=no
    echo "$human" | grep -q "$conflict_count conflicting path" && names_count=yes

    if [ "$verdict" = "conflict" ] && [ "$sem_is_null" = "yes" ] \
       && [ "$says_not_attempted" = "yes" ] && [ "$names_count" = "yes" ]; then
        report_result $num "$name" "PASS"
    else
        report_result $num "$name" "FAIL" \
            "verdict=$verdict semantic_null=$sem_is_null says_not_attempted=$says_not_attempted names_count=$names_count"
    fi
}

test_v10_conflict_paths_excluded() {
    local num=10 name="breakage-on-conflicting-path-excluded"
    local test_dir; test_dir=$(new_case_dir "v$num")
    trap "rm -rf '$test_dir'" RETURN
    local repo="$test_dir/repo"
    mkdir -p "$repo"
    fixture_v10 "$repo" >/dev/null 2>&1

    if ! git_in "$repo" worktree add -q "$test_dir/peer" branch_b >/dev/null 2>&1; then
        report_result $num "$name" "SKIP" "could not add peer worktree"
        return
    fi

    local json rc
    json=$(run_verify_json "$repo")
    rc=$?
    if [ "$rc" -ne 0 ]; then
        report_result $num "$name" "FAIL" "moire verify exited $rc"
        return
    fi

    local summary
    summary=$(python3 -c "
import json
r = json.loads('''$json''')[0]
verdict = r['verdict']
cp = set(r['conflict_paths'])
sem = r['semantic'] or {}
nb = sem.get('new_breakage') or []
excluded = sem.get('excluded_conflict_paths', 0)
leaked = [x for x in nb if (x[0] if isinstance(x, list) else x) in cp]
print(verdict, excluded, len(leaked))
" 2>/dev/null)
    local verdict excluded leaked
    read -r verdict excluded leaked <<<"$summary"

    if [ "$verdict" = "conflict" ] && [ "${excluded:-0}" -ge 1 ] && [ "${leaked:-1}" -eq 0 ]; then
        report_result $num "$name" "PASS"
    else
        report_result $num "$name" "FAIL" "verdict=$verdict excluded_conflict_paths=$excluded leaked_into_new_breakage=$leaked"
    fi
}

# ---- A5: self is checked once per `verify` call, not once per peer.

test_v11_self_checked_once_across_peers() {
    local num=11 name="self-broken-identical-across-two-peers"
    local test_dir; test_dir=$(new_case_dir "v$num")
    trap "rm -rf '$test_dir'" RETURN
    local repo="$test_dir/repo"
    mkdir -p "$repo"
    fixture_v11 "$repo" >/dev/null 2>&1

    if ! git_in "$repo" worktree add -q "$test_dir/peer1" branch_b1 >/dev/null 2>&1; then
        report_result $num "$name" "SKIP" "could not add peer1 worktree"
        return
    fi
    if ! git_in "$repo" worktree add -q "$test_dir/peer2" branch_b2 >/dev/null 2>&1; then
        report_result $num "$name" "SKIP" "could not add peer2 worktree"
        return
    fi

    local peer1_wt peer2_wt
    peer1_wt=$(cd "$test_dir/peer1" && pwd -P)
    peer2_wt=$(cd "$test_dir/peer2" && pwd -P)

    local together_file="$test_dir/together.json"
    local solo1_file="$test_dir/solo1.json"
    local solo2_file="$test_dir/solo2.json"

    if ! (cd "$repo" && MOIRE_GIT="$GIT_PROG" "$MOIRE_BIN" verify --peers "$peer1_wt,$peer2_wt" --json) >"$together_file" 2>/dev/null; then
        report_result $num "$name" "FAIL" "two-peer verify failed"
        return
    fi
    if ! (cd "$repo" && MOIRE_GIT="$GIT_PROG" "$MOIRE_BIN" verify --peers "$peer1_wt" --json) >"$solo1_file" 2>/dev/null; then
        report_result $num "$name" "FAIL" "solo peer1 verify failed"
        return
    fi
    if ! (cd "$repo" && MOIRE_GIT="$GIT_PROG" "$MOIRE_BIN" verify --peers "$peer2_wt" --json) >"$solo2_file" 2>/dev/null; then
        report_result $num "$name" "FAIL" "solo peer2 verify failed"
        return
    fi

    local summary
    summary=$(python3 -c "
import json

def norm(r):
    r = dict(r)
    for k in ('ts', 'check_id', 'duration_ms', 'cached'):
        r.pop(k, None)
    if isinstance(r.get('semantic'), dict):
        r['semantic'] = dict(r['semantic'])
        # self is materialised/checked once per verify call and memoised
        # (that IS the behaviour this case pins): whichever peer is
        # processed first in the two-peer run pays the cost and the other
        # gets 0, whereas each solo run always pays fresh. That timing
        # split is the point of the optimisation, not a substantive output
        # - exclude both duration fields, keep everything else byte-equal.
        r['semantic'].pop('duration_ms', None)
        r['semantic'].pop('self_duration_ms', None)
    return r

together = json.load(open('$together_file'))
solo1 = json.load(open('$solo1_file'))
solo2 = json.load(open('$solo2_file'))

peer1_wt = '$peer1_wt'
peer2_wt = '$peer2_wt'

t1 = next((r for r in together if r['peer']['worktree'] == peer1_wt), None)
t2 = next((r for r in together if r['peer']['worktree'] == peer2_wt), None)

if t1 is None or t2 is None or len(solo1) != 1 or len(solo2) != 1:
    print('FAIL', 'missing-records')
else:
    same_self_broken = t1['semantic']['self_broken'] == t2['semantic']['self_broken']
    match1 = norm(t1) == norm(solo1[0])
    match2 = norm(t2) == norm(solo2[0])
    if same_self_broken and match1 and match2:
        print('PASS', t1['semantic']['self_broken'])
    else:
        print('FAIL', 'same_self_broken=%s match1=%s match2=%s' % (same_self_broken, match1, match2))
" 2>/dev/null)
    local status detail
    read -r status detail <<<"$summary"

    if [ "$status" = "PASS" ]; then
        report_result $num "$name" "PASS" "self_broken=$detail in both peer records"
    else
        report_result $num "$name" "FAIL" "$detail"
    fi
}

# ---- A6: --link.

test_v12_link_names_a_directory() {
    local num=12 name="link-makes-gitignored-dir-visible-to-checker"
    local test_dir; test_dir=$(new_case_dir "v$num")
    trap "rm -rf '$test_dir'" RETURN
    local repo="$test_dir/repo"
    mkdir -p "$repo"
    fixture_v12 "$repo" >/dev/null 2>&1

    if ! git_in "$repo" worktree add -q "$test_dir/peer" branch_b >/dev/null 2>&1; then
        report_result $num "$name" "SKIP" "could not add peer worktree"
        return
    fi

    mkdir -p "$repo/deps"
    echo marker > "$repo/deps/MARKER"

    # Silent on success (marker visible), one line of output when absent -
    # directly observable via semantic.self_broken (0 vs 1), since
    # new_breakage necessarily cancels self vs merged here (both draw from
    # the same worktree as --link's source - see link_directories in
    # bin/moire).
    local checker='test -f deps/MARKER || echo absent'

    local json_without json_with rc
    json_without=$(run_verify_json "$repo" --checker "$checker")
    rc=$?
    if [ "$rc" -ne 0 ]; then
        report_result $num "$name" "FAIL" "moire verify (no --link) exited $rc"
        return
    fi
    json_with=$(run_verify_json "$repo" --checker "$checker" --link deps)
    rc=$?
    if [ "$rc" -ne 0 ]; then
        report_result $num "$name" "FAIL" "moire verify (--link deps) exited $rc"
        return
    fi

    local self_broken_without self_broken_with linked_has_deps
    self_broken_without=$(json_get "$json_without" "semantic.self_broken" 0)
    self_broken_with=$(json_get "$json_with" "semantic.self_broken" 0)
    # "linked" is per-tree: {"self": [...], "peer": [...], "merged": [...]}
    # (asymmetric on purpose - the peer tree draws from the peer's own
    # worktree, which never got a deps/ here). self_broken's flip from 1 to
    # 0 is driven by the self tree, so that is the one we check.
    linked_has_deps=$(python3 -c "
import json
r = json.loads('''$json_with''')[0]
print('yes' if 'deps' in (r['semantic'].get('linked') or {}).get('self', []) else 'no')
" 2>/dev/null)

    if [ "$self_broken_without" = "1" ] && [ "$self_broken_with" = "0" ] && [ "$linked_has_deps" = "yes" ]; then
        report_result $num "$name" "PASS"
    else
        report_result $num "$name" "FAIL" \
            "self_broken without --link=$self_broken_without with --link=$self_broken_with linked_has_deps=$linked_has_deps"
    fi
}

test_v13_link_path_traversal_rejected() {
    local num=13 name="link-path-traversal-rejected"
    local test_dir; test_dir=$(new_case_dir "v$num")
    trap "rm -rf '$test_dir'" RETURN
    local repo="$test_dir/repo"
    mkdir -p "$repo"
    fixture_v12 "$repo" >/dev/null 2>&1

    if ! git_in "$repo" worktree add -q "$test_dir/peer" branch_b >/dev/null 2>&1; then
        report_result $num "$name" "SKIP" "could not add peer worktree"
        return
    fi

    # Establish a baseline log-record count with one legitimate run first.
    (cd "$repo" && MOIRE_GIT="$GIT_PROG" "$MOIRE_BIN" verify --json >/dev/null 2>&1)
    local log_dir="$repo/.git/moire/log"
    local before after1 after2
    before=$(find "$log_dir" -type f 2>/dev/null | wc -l | tr -d ' ')

    local err1 rc1
    err1=$(cd "$repo" && MOIRE_GIT="$GIT_PROG" "$MOIRE_BIN" verify --link ../evil 2>&1 >/dev/null)
    rc1=$?
    after1=$(find "$log_dir" -type f 2>/dev/null | wc -l | tr -d ' ')

    local err2 rc2
    err2=$(cd "$repo" && MOIRE_GIT="$GIT_PROG" "$MOIRE_BIN" verify --link a/b 2>&1 >/dev/null)
    rc2=$?
    after2=$(find "$log_dir" -type f 2>/dev/null | wc -l | tr -d ' ')

    if [ "$rc1" -eq 2 ] && [ -n "$err1" ] && [ "$after1" = "$before" ] \
       && [ "$rc2" -eq 2 ] && [ -n "$err2" ] && [ "$after2" = "$before" ]; then
        report_result $num "$name" "PASS"
    else
        report_result $num "$name" "FAIL" \
            "../evil: exit=$rc1 stderr_nonempty=$([ -n "$err1" ] && echo yes || echo no) log_unchanged=$([ "$after1" = "$before" ] && echo yes || echo no); a/b: exit=$rc2 stderr_nonempty=$([ -n "$err2" ] && echo yes || echo no) log_unchanged=$([ "$after2" = "$before" ] && echo yes || echo no)"
    fi
}

test_v14_link_missing_directory_skipped() {
    local num=14 name="link-missing-directory-skipped-silently"
    local test_dir; test_dir=$(new_case_dir "v$num")
    trap "rm -rf '$test_dir'" RETURN
    local repo="$test_dir/repo"
    mkdir -p "$repo"
    fixture_v12 "$repo" >/dev/null 2>&1

    if ! git_in "$repo" worktree add -q "$test_dir/peer" branch_b >/dev/null 2>&1; then
        report_result $num "$name" "SKIP" "could not add peer worktree"
        return
    fi

    local json rc
    json=$(run_verify_json "$repo" --link nonexistent_xyz)
    rc=$?

    local linked_has_it
    linked_has_it=$(python3 -c "
import json
r = json.loads('''$json''')[0]
linked = r['semantic'].get('linked') or {}
everywhere = set(linked.get('self', [])) | set(linked.get('peer', [])) | set(linked.get('merged', []))
print('yes' if 'nonexistent_xyz' in everywhere else 'no')
" 2>/dev/null)

    if [ "$rc" -eq 0 ] && [ "$linked_has_it" = "no" ]; then
        report_result $num "$name" "PASS"
    else
        report_result $num "$name" "FAIL" "exit=$rc linked_contains_missing_dir=$linked_has_it"
    fi
}

# ---- A3: `report` surfaces the semantic dimension.

test_v15_report_semantic_fields() {
    local num=15 name="report-json-includes-semantic-fields"
    local test_dir; test_dir=$(new_case_dir "v$num")
    trap "rm -rf '$test_dir'" RETURN
    local repo="$test_dir/repo"
    mkdir -p "$repo"
    fixture_v2 "$repo" >/dev/null 2>&1

    if ! git_in "$repo" worktree add -q "$test_dir/peer" branch_b >/dev/null 2>&1; then
        report_result $num "$name" "SKIP" "could not add peer worktree"
        return
    fi

    if ! (cd "$repo" && MOIRE_GIT="$GIT_PROG" "$MOIRE_BIN" verify --json >/dev/null 2>&1); then
        report_result $num "$name" "SKIP" "moire verify failed"
        return
    fi

    local report_json
    report_json=$(cd "$repo" && MOIRE_GIT="$GIT_PROG" "$MOIRE_BIN" report --json 2>/dev/null)
    if [ -z "$report_json" ]; then
        report_result $num "$name" "FAIL" "moire report --json produced no output"
        return
    fi

    local has_pairs has_breakages has_rate has_skipped
    has_pairs=$(json_has "$report_json" "semantic_pair_states_performed" 0)
    has_breakages=$(json_has "$report_json" "broken_pair_states" 0)
    has_rate=$(json_has "$report_json" "semantic_rate" 0)
    has_skipped=$(json_has "$report_json" "skipped_semantic_checks" 0)

    # This fixture's only record is verdict=="clean" with real semantic
    # breakage: textual_rate (conflicting pair-states / pair-states) must be
    # 0.0, proving it is not inflated by the semantic finding.
    local summary
    summary=$(python3 -c "
import json
d = json.loads('''$report_json''')
print(d.get('textual_rate'), d.get('broken_pair_states'))
" 2>/dev/null)
    local textual_rate broken_pair_states
    read -r textual_rate broken_pair_states <<<"$summary"

    if [ "$has_pairs" = "yes" ] && [ "$has_breakages" = "yes" ] && [ "$has_rate" = "yes" ] \
       && [ "$has_skipped" = "yes" ] && [ "${broken_pair_states:-0}" -ge 1 ] && [ "$textual_rate" = "0.0" ]; then
        report_result $num "$name" "PASS"
    else
        report_result $num "$name" "FAIL" \
            "has_fields(pairs=$has_pairs breakages=$has_breakages rate=$has_rate skipped=$has_skipped) broken_pair_states=$broken_pair_states textual_rate=$textual_rate"
    fi
}

test_v16_report_skipped_semantic_checks() {
    local num=16 name="report-skipped-semantic-checks-both-modes"
    local test_dir; test_dir=$(new_case_dir "v$num")
    trap "rm -rf '$test_dir'" RETURN
    local repo="$test_dir/repo"
    mkdir -p "$repo"
    fixture_v8 "$repo" >/dev/null 2>&1

    if ! git_in "$repo" worktree add -q "$test_dir/peer" branch_b >/dev/null 2>&1; then
        report_result $num "$name" "SKIP" "could not add peer worktree"
        return
    fi

    if ! (cd "$repo" && MOIRE_GIT="$GIT_PROG" "$MOIRE_BIN" verify --checker 'echo something' --json >/dev/null 2>&1); then
        report_result $num "$name" "SKIP" "moire verify failed"
        return
    fi

    local plain study
    plain=$(cd "$repo" && MOIRE_GIT="$GIT_PROG" "$MOIRE_BIN" report --json 2>/dev/null)
    study=$(cd "$repo" && MOIRE_GIT="$GIT_PROG" "$MOIRE_BIN" report --study --json 2>/dev/null)

    local plain_skipped study_skipped
    plain_skipped=$(json_get "$plain" "skipped_semantic_checks" 0)
    study_skipped=$(json_get "$study" "skipped_semantic_checks" 0)

    if [ -n "$plain_skipped" ] && [ "$plain_skipped" -ge 1 ] \
       && [ -n "$study_skipped" ] && [ "$study_skipped" -ge 1 ]; then
        report_result $num "$name" "PASS"
    else
        report_result $num "$name" "FAIL" "report.skipped_semantic_checks=$plain_skipped report_study.skipped_semantic_checks=$study_skipped"
    fi
}

# ---- A1: no deprecation noise.

test_v17_no_deprecation_warning() {
    local num=17 name="no-deprecationwarning-under-python-3.12-plus"
    local pyver pymaj pymin
    pyver=$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null)
    pymaj=$(echo "$pyver" | cut -d. -f1)
    pymin=$(echo "$pyver" | cut -d. -f2)
    if [ -z "$pyver" ] || [ "$pymaj" -lt 3 ] || { [ "$pymaj" -eq 3 ] && [ "$pymin" -lt 12 ]; }; then
        report_result $num "$name" "SKIP" "local python3 is $pyver, < 3.12; datetime.utcnow() only warns there"
        return
    fi

    local test_dir; test_dir=$(new_case_dir "v$num")
    trap "rm -rf '$test_dir'" RETURN
    local repo="$test_dir/repo"
    mkdir -p "$repo"
    fixture_v1 "$repo" >/dev/null 2>&1

    local out rc
    out=$(cd "$repo" && MOIRE_GIT="$GIT_PROG" python3 -W error::DeprecationWarning "$MOIRE_BIN" verify 2>&1)
    rc=$?

    if [ "$rc" -eq 0 ] && ! echo "$out" | grep -q "DeprecationWarning"; then
        report_result $num "$name" "PASS"
    else
        report_result $num "$name" "FAIL" "exit=$rc output=$(echo "$out" | tr '\n' ' ' | head -c 200)"
    fi
}

# ---- A8: doctor's new [warn] level.

test_v18_doctor_warn_missing_dep_dir() {
    local num=18 name="doctor-warns-on-missing-dependency-dir"
    local test_dir; test_dir=$(new_case_dir "v$num")
    trap "rm -rf '$test_dir'" RETURN
    local repo="$test_dir/repo"
    mkdir -p "$repo"
    fixture_v18 "$repo" >/dev/null 2>&1

    if ! git_in "$repo" worktree add -q "$test_dir/peer" -b branch_b >/dev/null 2>&1; then
        report_result $num "$name" "SKIP" "could not add peer worktree"
        return
    fi

    local out_before rc_before
    out_before=$(cd "$repo" && MOIRE_GIT="$GIT_PROG" "$MOIRE_BIN" doctor 2>&1)
    rc_before=$?

    mkdir -p "$repo/deps"
    echo marker > "$repo/deps/MARKER"

    local out_after rc_after
    out_after=$(cd "$repo" && MOIRE_GIT="$GIT_PROG" "$MOIRE_BIN" doctor 2>&1)
    rc_after=$?

    local peer_real main_real
    peer_real=$(cd "$test_dir/peer" && pwd -P)
    main_real=$(cd "$repo" && pwd -P)
    # One warn line per linked worktree, naming that worktree in the label
    # and the missing directory name(s) plus the main worktree in the
    # detail: "[warn] dependency dirs missing in <peer> - deps (present and
    # git-ignored in <main>)". Together the line names the exact missing
    # path (peer worktree + "deps"), just not as one concatenated string.
    local warn_line
    warn_line=$(echo "$out_after" | grep '^\[warn\] dependency dirs missing in')

    local had_warn_before names_peer names_name names_main
    had_warn_before=no
    echo "$out_before" | grep -q '^\[warn\] dependency dirs missing in' && had_warn_before=yes
    names_peer=no
    echo "$warn_line" | grep -qF "$peer_real" && names_peer=yes
    names_name=no
    echo "$warn_line" | grep -qF "deps" && names_name=yes
    names_main=no
    echo "$warn_line" | grep -qF "$main_real" && names_main=yes

    if [ "$had_warn_before" = "no" ] && [ -n "$warn_line" ] && [ "$names_peer" = "yes" ] \
       && [ "$names_name" = "yes" ] && [ "$names_main" = "yes" ] && [ "$rc_after" = "$rc_before" ]; then
        report_result $num "$name" "PASS"
    else
        report_result $num "$name" "FAIL" \
            "had_warn_before=$had_warn_before warn_line_present=$([ -n "$warn_line" ] && echo yes || echo no) names_peer=$names_peer names_dirname=$names_name names_main=$names_main exit_before=$rc_before exit_after=$rc_after"
    fi
}

# ---- A9: the checker must never claim "semantic ok" about a tree it did
# ---- not read, and a vacuous record must not enter the Phase 1 base rate.

test_v19_ts_repro_no_semantic_claim() {
    local num=19 name="ts-repro-no-semantic-claim"
    local test_dir; test_dir=$(new_case_dir "v$num")
    trap "rm -rf '$test_dir'" RETURN
    local repo="$test_dir/repo"
    mkdir -p "$repo"
    fixture_v19 "$repo" >/dev/null 2>&1

    if ! git_in "$repo" worktree add -q "$test_dir/peer" branch_b >/dev/null 2>&1; then
        report_result $num "$name" "SKIP" "could not add peer worktree"
        return
    fi

    local json rc
    json=$(run_verify_json "$repo")
    rc=$?
    if [ "$rc" -ne 0 ]; then
        report_result $num "$name" "FAIL" "moire verify --json exited $rc"
        return
    fi

    local human hrc
    human=$(run_verify_human "$repo")
    hrc=$?

    # The string an LLM must be unable to extract from a tree nothing read.
    local claims_ok says_unperformed says_not_verified
    claims_ok=no
    echo "$human" | grep -q "semantic ok" && claims_ok=yes
    says_unperformed=no
    echo "$human" | grep -q "no semantic check was performed" && says_unperformed=yes
    says_not_verified=no
    echo "$human" | grep -q "NOT semantically verified" && says_not_verified=yes

    local summary
    summary=$(python3 -c "
import json
r = json.loads('''$json''')[0]
sem = r['semantic'] or {}
cov = (sem.get('coverage') or {}).get('merged') or {}
print(r['verdict'], sem.get('performed'), cov.get('examined'), cov.get('total'), r.get('finding_id'))
" 2>/dev/null)
    local verdict performed examined total fid
    read -r verdict performed examined total fid <<<"$summary"

    if [ "$rc" -eq 0 ] && [ "$hrc" -eq 0 ] && [ "$verdict" = "clean" ] \
       && [ "$claims_ok" = "no" ] && [ "$says_unperformed" = "yes" ] \
       && [ "$says_not_verified" = "yes" ] && [ "$performed" = "False" ] \
       && [ "${examined:-1}" -eq 0 ] && [ "${total:-0}" -ge 3 ] && [ "$fid" = "None" ]; then
        report_result $num "$name" "PASS"
    else
        report_result $num "$name" "FAIL" \
            "exit=$rc/$hrc verdict=$verdict says_semantic_ok=$claims_ok says_unperformed=$says_unperformed says_not_verified=$says_not_verified performed=$performed merged_examined=$examined merged_total=$total finding_id=$fid"
    fi
}

test_v20_python_repo_coverage_reported() {
    local num=20 name="python-repo-coverage-reported"
    local test_dir; test_dir=$(new_case_dir "v$num")
    trap "rm -rf '$test_dir'" RETURN

    # Part A - the canonical BROKEN case (fixture_v2): coverage is recorded
    # and the fix did not perturb detection. Its human output is the BROKEN
    # block, which by design never contains "semantic ok", so the clean-line
    # coverage suffix is asserted in part B instead.
    local broken_repo="$test_dir/broken_repo"
    mkdir -p "$broken_repo"
    fixture_v2 "$broken_repo" >/dev/null 2>&1
    if ! git_in "$broken_repo" worktree add -q "$test_dir/broken_peer" branch_b >/dev/null 2>&1; then
        report_result $num "$name" "SKIP" "could not add peer worktree for the broken repo"
        return
    fi

    local json rc
    json=$(run_verify_json "$broken_repo")
    rc=$?
    if [ "$rc" -ne 0 ]; then
        report_result $num "$name" "FAIL" "moire verify --json exited $rc"
        return
    fi

    local summary
    summary=$(python3 -c "
import json
r = json.loads('''$json''')[0]
sem = r['semantic'] or {}
cov = (sem.get('coverage') or {}).get('merged') or {}
nb = sem.get('new_breakage') or []
names = [(x[0] if isinstance(x, list) else x) for x in nb]
print(sem.get('performed'), cov.get('examined'), 'peer_caller.py' in names)
" 2>/dev/null)
    local performed examined names_peer_caller
    read -r performed examined names_peer_caller <<<"$summary"

    # Part B - a clean Python merge (fixture_v1): "semantic ok" survives and
    # now carries the scope it was always implicitly claiming.
    local clean_repo="$test_dir/clean_repo"
    mkdir -p "$clean_repo"
    fixture_v1 "$clean_repo" >/dev/null 2>&1
    if ! git_in "$clean_repo" worktree add -q "$test_dir/clean_peer" branch_b >/dev/null 2>&1; then
        report_result $num "$name" "SKIP" "could not add peer worktree for the clean repo"
        return
    fi

    local human hrc
    human=$(run_verify_human "$clean_repo")
    hrc=$?
    local says_ok says_examined says_python_only
    says_ok=no
    echo "$human" | grep -q "semantic ok" && says_ok=yes
    says_examined=no
    echo "$human" | grep -q "examined" && says_examined=yes
    says_python_only=no
    echo "$human" | grep -q "python only" && says_python_only=yes

    if [ "$performed" = "True" ] && [ "${examined:-0}" -ge 2 ] \
       && [ "$names_peer_caller" = "True" ] && [ "$hrc" -eq 0 ] \
       && [ "$says_ok" = "yes" ] && [ "$says_examined" = "yes" ] \
       && [ "$says_python_only" = "yes" ]; then
        report_result $num "$name" "PASS"
    else
        report_result $num "$name" "FAIL" \
            "performed=$performed merged_examined=$examined names_peer_caller=$names_peer_caller clean_exit=$hrc says_semantic_ok=$says_ok says_examined=$says_examined says_python_only=$says_python_only"
    fi
}

test_v21_git_config_checker_used_and_flag_wins() {
    local num=21 name="git-config-checker-used-and-flag-wins"
    local test_dir; test_dir=$(new_case_dir "v$num")
    trap "rm -rf '$test_dir'" RETURN
    local repo="$test_dir/repo"
    mkdir -p "$repo"
    fixture_v6 "$repo" >/dev/null 2>&1

    if ! git_in "$repo" worktree add -q "$test_dir/peer" branch_b >/dev/null 2>&1; then
        report_result $num "$name" "SKIP" "could not add peer worktree"
        return
    fi

    git_in "$repo" config moire.checker 'echo cfg-finding' >/dev/null 2>&1

    # No --checker: the config value is what runs. The identical line in all
    # three trees cancels, so new_breakage == [] - which is itself proof the
    # set difference still works through a config-sourced checker.
    local cfg_json flag_json rc
    cfg_json=$(run_verify_json "$repo")
    rc=$?
    if [ "$rc" -ne 0 ]; then
        report_result $num "$name" "FAIL" "moire verify (config checker) exited $rc"
        return
    fi
    flag_json=$(run_verify_json "$repo" --checker 'echo flag-finding')
    rc=$?
    if [ "$rc" -ne 0 ]; then
        report_result $num "$name" "FAIL" "moire verify (--checker) exited $rc"
        return
    fi

    local cfg_summary
    cfg_summary=$(python3 -c "
import json
sem = json.loads('''$cfg_json''')[0]['semantic'] or {}
print(sem.get('checker_source'), sem.get('new_breakage') == [], repr(sem.get('checker')))
" 2>/dev/null)
    local cfg_source cfg_nb_empty cfg_checker
    read -r cfg_source cfg_nb_empty cfg_checker <<<"$cfg_summary"

    local flag_summary
    flag_summary=$(python3 -c "
import json
sem = json.loads('''$flag_json''')[0]['semantic'] or {}
print(sem.get('checker_source'), repr(sem.get('checker')))
" 2>/dev/null)
    local flag_source flag_checker
    read -r flag_source flag_checker <<<"$flag_summary"

    # A repo with neither flag nor config still records "default".
    local plain_repo="$test_dir/plain_repo"
    mkdir -p "$plain_repo"
    fixture_v6 "$plain_repo" >/dev/null 2>&1
    if ! git_in "$plain_repo" worktree add -q "$test_dir/plain_peer" branch_b >/dev/null 2>&1; then
        report_result $num "$name" "SKIP" "could not add peer worktree for the unconfigured repo"
        return
    fi
    local plain_source
    plain_source=$(json_get "$(run_verify_json "$plain_repo")" "semantic.checker_source" 0)

    if [ "$cfg_source" = "config" ] && [ "$cfg_checker" = "'echo cfg-finding'" ] \
       && [ "$cfg_nb_empty" = "True" ] && [ "$flag_source" = "flag" ] \
       && [ "$flag_checker" = "'echo flag-finding'" ] && [ "$plain_source" = "default" ]; then
        report_result $num "$name" "PASS"
    else
        report_result $num "$name" "FAIL" \
            "config run: source=$cfg_source checker=$cfg_checker new_breakage_empty=$cfg_nb_empty; flag run: source=$flag_source checker=$flag_checker; unconfigured run: source=$plain_source"
    fi
}

test_v22_git_config_link_and_invalid_link_refused() {
    local num=22 name="git-config-link-and-invalid-link-refused"
    local test_dir; test_dir=$(new_case_dir "v$num")
    trap "rm -rf '$test_dir'" RETURN
    local repo="$test_dir/repo"
    mkdir -p "$repo"
    fixture_v12 "$repo" >/dev/null 2>&1

    if ! git_in "$repo" worktree add -q "$test_dir/peer" branch_b >/dev/null 2>&1; then
        report_result $num "$name" "SKIP" "could not add peer worktree"
        return
    fi

    mkdir -p "$repo/deps"
    echo marker > "$repo/deps/MARKER"

    # Same checker and same observable as V12, but the link comes from
    # `git config moire.link` with NO --link flag: self_broken flips to 0 and
    # the name appears in semantic.linked.self, exactly as the flag does.
    git_in "$repo" config moire.link deps >/dev/null 2>&1
    local checker='test -f deps/MARKER || echo absent'

    local json rc
    json=$(run_verify_json "$repo" --checker "$checker")
    rc=$?
    if [ "$rc" -ne 0 ]; then
        report_result $num "$name" "FAIL" "moire verify (config link) exited $rc"
        return
    fi

    local self_broken linked_has_deps
    self_broken=$(python3 -c "
import json
print(json.loads('''$json''')[0]['semantic']['self_broken'])
" 2>/dev/null)
    linked_has_deps=$(python3 -c "
import json
r = json.loads('''$json''')[0]
print('yes' if 'deps' in (r['semantic'].get('linked') or {}).get('self', []) else 'no')
" 2>/dev/null)

    # An invalid config link must refuse with 2 before writing any log -
    # the same shape as V13's flag refusal.
    git_in "$repo" config --unset-all moire.link >/dev/null 2>&1
    git_in "$repo" config moire.link '../evil' >/dev/null 2>&1

    local log_dir="$repo/.git/moire/log"
    local before after err rc_bad
    before=$(find "$log_dir" -type f 2>/dev/null | wc -l | tr -d ' ')
    err=$(cd "$repo" && MOIRE_GIT="$GIT_PROG" "$MOIRE_BIN" verify --checker "$checker" 2>&1 >/dev/null)
    rc_bad=$?
    after=$(find "$log_dir" -type f 2>/dev/null | wc -l | tr -d ' ')

    local names_key
    names_key=no
    echo "$err" | grep -q "moire.link" && names_key=yes

    if [ "$self_broken" = "0" ] && [ "$linked_has_deps" = "yes" ] && [ "$rc_bad" -eq 2 ] \
       && [ -n "$err" ] && [ "$names_key" = "yes" ] && [ "$after" = "$before" ]; then
        report_result $num "$name" "PASS"
    else
        report_result $num "$name" "FAIL" \
            "config link: self_broken=$self_broken linked_has_deps=$linked_has_deps; invalid: exit=$rc_bad stderr_names_moire.link=$names_key log_unchanged=$([ "$after" = "$before" ] && echo yes || echo no)"
    fi
}

test_v23_report_excludes_unperformed() {
    local num=23 name="report-excludes-unperformed"
    local test_dir; test_dir=$(new_case_dir "v$num")
    trap "rm -rf '$test_dir'" RETURN

    local ts_repo="$test_dir/ts_repo"
    mkdir -p "$ts_repo"
    fixture_v19 "$ts_repo" >/dev/null 2>&1
    if ! git_in "$ts_repo" worktree add -q "$test_dir/ts_peer" branch_b >/dev/null 2>&1; then
        report_result $num "$name" "SKIP" "could not add peer worktree for the TS repo"
        return
    fi
    if ! (cd "$ts_repo" && MOIRE_GIT="$GIT_PROG" "$MOIRE_BIN" verify --json >/dev/null 2>&1); then
        report_result $num "$name" "SKIP" "moire verify failed on the TS repo"
        return
    fi

    local ts_report ts_study ts_human
    ts_report=$(cd "$ts_repo" && MOIRE_GIT="$GIT_PROG" "$MOIRE_BIN" report --json 2>/dev/null)
    ts_study=$(cd "$ts_repo" && MOIRE_GIT="$GIT_PROG" "$MOIRE_BIN" report --study --json 2>/dev/null)
    ts_human=$(cd "$ts_repo" && MOIRE_GIT="$GIT_PROG" "$MOIRE_BIN" report 2>/dev/null)

    local summary
    summary=$(python3 -c "
import json
d = json.loads('''$ts_report''')
s = json.loads('''$ts_study''')
print(d.get('unperformed_semantic_checks'), d.get('semantic_pair_states_performed'),
      d.get('semantic_rate'), s.get('unperformed_semantic_checks'))
" 2>/dev/null)
    local unperformed pairs rate study_unperformed
    read -r unperformed pairs rate study_unperformed <<<"$summary"

    local human_na
    human_na=no
    echo "$ts_human" | grep -q "semantic rate (clean pair-states that break) : n/a" && human_na=yes

    # A performed record still counts: the exclusion is targeted, not blanket.
    local py_repo="$test_dir/py_repo"
    mkdir -p "$py_repo"
    fixture_v2 "$py_repo" >/dev/null 2>&1
    if ! git_in "$py_repo" worktree add -q "$test_dir/py_peer" branch_b >/dev/null 2>&1; then
        report_result $num "$name" "SKIP" "could not add peer worktree for the Python repo"
        return
    fi
    if ! (cd "$py_repo" && MOIRE_GIT="$GIT_PROG" "$MOIRE_BIN" verify --json >/dev/null 2>&1); then
        report_result $num "$name" "SKIP" "moire verify failed on the Python repo"
        return
    fi
    local py_report py_pairs
    py_report=$(cd "$py_repo" && MOIRE_GIT="$GIT_PROG" "$MOIRE_BIN" report --json 2>/dev/null)
    py_pairs=$(json_get "$py_report" "semantic_pair_states_performed" 0)

    if [ "${unperformed:-0}" -ge 1 ] && [ "${pairs:-1}" -eq 0 ] && [ "$rate" = "None" ] \
       && [ "$human_na" = "yes" ] && [ "${study_unperformed:-0}" -ge 1 ] \
       && [ -n "$py_pairs" ] && [ "$py_pairs" -ge 1 ]; then
        report_result $num "$name" "PASS"
    else
        report_result $num "$name" "FAIL" \
            "ts: unperformed=$unperformed semantic_pair_states=$pairs semantic_rate=$rate human_na=$human_na study_unperformed=$study_unperformed; python: semantic_pair_states=$py_pairs"
    fi
}

test_v24_doctor_checker_applicability() {
    local num=24 name="doctor-checker-applicability"
    local test_dir; test_dir=$(new_case_dir "v$num")
    trap "rm -rf '$test_dir'" RETURN

    # A repo with no tracked .py files and no configured checker: warn.
    local repo="$test_dir/repo"
    mkdir -p "$repo"
    fixture_v18 "$repo" >/dev/null 2>&1

    local out_warn rc_warn
    out_warn=$(cd "$repo" && MOIRE_GIT="$GIT_PROG" "$MOIRE_BIN" doctor 2>&1)
    rc_warn=$?

    local warn_line names_no_py
    warn_line=$(echo "$out_warn" | grep '^\[warn\] verify checker')
    names_no_py=no
    echo "$warn_line" | grep -qF "no .py files" && names_no_py=yes

    # Configuring a checker resolves it, and [warn] never moved the exit code.
    git_in "$repo" config moire.checker 'x' >/dev/null 2>&1
    local out_cfg rc_cfg cfg_line
    out_cfg=$(cd "$repo" && MOIRE_GIT="$GIT_PROG" "$MOIRE_BIN" doctor 2>&1)
    rc_cfg=$?
    cfg_line=$(echo "$out_cfg" | grep '^\[ok\] verify checker configured')

    # A Python repo needs no configuration: the default applies.
    local py_repo="$test_dir/py_repo"
    mkdir -p "$py_repo"
    fixture_v2 "$py_repo" >/dev/null 2>&1
    local py_line
    py_line=$(cd "$py_repo" && MOIRE_GIT="$GIT_PROG" "$MOIRE_BIN" doctor 2>&1 |
              grep '^\[ok\] verify checker - builtin-ast (default) applies')

    if [ -n "$warn_line" ] && [ "$names_no_py" = "yes" ] && [ -n "$cfg_line" ] \
       && [ -n "$py_line" ] && [ "$rc_cfg" = "$rc_warn" ]; then
        report_result $num "$name" "PASS"
    else
        report_result $num "$name" "FAIL" \
            "warn_line_present=$([ -n "$warn_line" ] && echo yes || echo no) names_no_py=$names_no_py ok_configured_line=$([ -n "$cfg_line" ] && echo yes || echo no) python_default_line=$([ -n "$py_line" ] && echo yes || echo no) exit_warn=$rc_warn exit_configured=$rc_cfg"
    fi
}

# ---- A4: the metric the kill criterion is defined on. `report`'s rates are
# ---- over distinct PAIR-STATES (self_tree, peer_tree) and its finding counts
# ---- over distinct finding_ids - never over observations, of which a hook
# ---- firing on every write produces arbitrarily many for one collision.

# Run `moire verify --json` from $1 with the peer cache disabled, so a case
# that deliberately changes a peer's working tree between runs observes the
# change instead of a cache hit.
run_verify_uncached() {
    local repo="$1"
    shift
    (cd "$repo" && MOIRE_CACHE_TTL=0 MOIRE_GIT="$GIT_PROG" "$MOIRE_BIN" verify --json "$@" 2>/dev/null)
}

test_v25_report_counts_pair_states_not_observations() {
    local num=25 name="report-pair-states-not-observations"
    local test_dir; test_dir=$(new_case_dir "v$num")
    trap "rm -rf '$test_dir'" RETURN
    local repo="$test_dir/repo"
    mkdir -p "$repo"
    fixture_v2 "$repo" >/dev/null 2>&1

    if ! git_in "$repo" worktree add -q "$test_dir/peer" branch_b >/dev/null 2>&1; then
        report_result $num "$name" "SKIP" "could not add peer worktree"
        return
    fi

    # One collision, observed five times - exactly what a per-write hook does.
    local i
    for i in 1 2 3 4 5; do
        if ! run_verify_uncached "$repo" >/dev/null; then
            report_result $num "$name" "SKIP" "moire verify failed on run $i"
            return
        fi
    done

    local rj
    rj=$(cd "$repo" && MOIRE_GIT="$GIT_PROG" "$MOIRE_BIN" report --json 2>/dev/null)
    local states broken sem_findings raw_records rate
    states=$(json_get "$rj" "pair_states_evaluated" 0)
    broken=$(json_get "$rj" "broken_pair_states" 0)
    sem_findings=$(json_get "$rj" "distinct_findings.semantic" 0)
    raw_records=$(json_get "$rj" "observations.pair_records" 0)
    rate=$(json_get "$rj" "semantic_rate" 0)

    # 5 observations, 1 pair-state, 1 distinct finding. The raw count is still
    # reported - it is what the log contains - but no rate is over it.
    if [ "$states" = "1" ] && [ "$broken" = "1" ] && [ "$sem_findings" = "1" ] \
       && [ "$raw_records" = "5" ]; then
        report_result $num "$name" "PASS"
    else
        report_result $num "$name" "FAIL" \
            "pair_states=$states broken=$broken distinct_semantic=$sem_findings raw_pair_records=$raw_records semantic_rate=$rate"
    fi
}

test_v26_report_distinguishes_pair_states() {
    local num=26 name="report-second-pair-state-moves-the-rate"
    local test_dir; test_dir=$(new_case_dir "v$num")
    trap "rm -rf '$test_dir'" RETURN
    local repo="$test_dir/repo"
    mkdir -p "$repo"
    fixture_v2 "$repo" >/dev/null 2>&1

    local peer="$test_dir/peer"
    if ! git_in "$repo" worktree add -q "$peer" branch_b >/dev/null 2>&1; then
        report_result $num "$name" "SKIP" "could not add peer worktree"
        return
    fi

    local i
    for i in 1 2 3; do
        if ! run_verify_uncached "$repo" >/dev/null; then
            report_result $num "$name" "SKIP" "moire verify failed on run $i"
            return
        fi
    done

    # The peer withdraws the collision in its working tree: same worktree
    # pair, genuinely different observed content - a SECOND pair-state, and
    # this one is not broken.
    printf 'from lib import new_name\nnew_name()\n' > "$peer/peer_caller.py"
    if ! run_verify_uncached "$repo" >/dev/null; then
        report_result $num "$name" "SKIP" "moire verify failed after the peer's fix"
        return
    fi

    local rj
    rj=$(cd "$repo" && MOIRE_GIT="$GIT_PROG" "$MOIRE_BIN" report --json 2>/dev/null)
    local states broken rate raw_records raw_breakage
    states=$(json_get "$rj" "semantic_pair_states_performed" 0)
    broken=$(json_get "$rj" "broken_pair_states" 0)
    rate=$(json_get "$rj" "semantic_rate" 0)
    raw_records=$(json_get "$rj" "observations.semantic_records" 0)
    raw_breakage=$(json_get "$rj" "observations.breakage_records" 0)

    # 4 observations, 3 of them of the broken state: an observation rate would
    # say 75%. The pair-state rate is 1 of 2.
    if [ "$states" = "2" ] && [ "$broken" = "1" ] && [ "$rate" = "0.5" ] \
       && [ "$raw_records" = "4" ] && [ "$raw_breakage" = "3" ]; then
        report_result $num "$name" "PASS"
    else
        report_result $num "$name" "FAIL" \
            "pair_states=$states broken=$broken rate=$rate raw_semantic=$raw_records raw_breakage=$raw_breakage"
    fi
}

test_v27_finding_id_distinguishes_breakages_in_one_file() {
    local num=27 name="finding-id-distinct-per-breakage-not-per-path"
    local test_dir; test_dir=$(new_case_dir "v$num")
    trap "rm -rf '$test_dir'" RETURN
    local repo="$test_dir/repo"
    mkdir -p "$repo"
    # fixture_v2 with TWO names in the base library, both of which self's
    # rename removes: the peer can then import either one and produce a
    # breakage that exists in the merged tree and in neither parent - the
    # only shape in which two distinct breakages can share one path.
    init_repo "$repo"
    printf 'def old_name():\n    return 1\n\n\ndef other_name():\n    return 2\n' > "$repo/lib.py"
    printf 'from lib import old_name\nold_name()\n' > "$repo/main.py"
    git_in "$repo" add -A
    git_in "$repo" commit -qm base >/dev/null 2>&1
    local base; base=$(git_in "$repo" rev-parse HEAD)
    git_in "$repo" checkout -q -b branch_a >/dev/null 2>&1
    printf 'def new_name():\n    return 1\n' > "$repo/lib.py"
    printf 'from lib import new_name\nnew_name()\n' > "$repo/main.py"
    git_in "$repo" commit -qam "self: rename both names away" >/dev/null 2>&1
    git_in "$repo" checkout -q "$base" >/dev/null 2>&1
    git_in "$repo" checkout -q -b branch_b >/dev/null 2>&1
    printf 'from lib import old_name\nold_name()\n' > "$repo/peer_caller.py"
    git_in "$repo" add -A
    git_in "$repo" commit -qm "peer: add caller of old_name" >/dev/null 2>&1
    git_in "$repo" checkout -q branch_a >/dev/null 2>&1

    local peer="$test_dir/peer"
    if ! git_in "$repo" worktree add -q "$peer" branch_b >/dev/null 2>&1; then
        report_result $num "$name" "SKIP" "could not add peer worktree"
        return
    fi

    local json1 fid1
    json1=$(run_verify_uncached "$repo")
    fid1=$(json_get "$json1" "finding_id" 0)

    # Same file, same worktree pair, DIFFERENT missing name. Keying the id on
    # the contested path alone made these one finding; they are two.
    printf 'from lib import other_name\nother_name()\n' > "$peer/peer_caller.py"
    local json2 fid2
    json2=$(run_verify_uncached "$repo")
    fid2=$(json_get "$json2" "finding_id" 0)

    local nb1 nb2
    nb1=$(python3 -c "
import json
print(json.loads('''$json1''')[0]['semantic']['new_breakage'])" 2>/dev/null)
    nb2=$(python3 -c "
import json
print(json.loads('''$json2''')[0]['semantic']['new_breakage'])" 2>/dev/null)

    local rj distinct
    rj=$(cd "$repo" && MOIRE_GIT="$GIT_PROG" "$MOIRE_BIN" report --json 2>/dev/null)
    distinct=$(json_get "$rj" "distinct_findings.semantic" 0)

    if [ -n "$fid1" ] && [ -n "$fid2" ] && [ "$fid1" != "$fid2" ] && [ "$distinct" = "2" ]; then
        report_result $num "$name" "PASS"
    else
        report_result $num "$name" "FAIL" \
            "fid1=$fid1 ($nb1) fid2=$fid2 ($nb2) distinct_semantic=$distinct"
    fi
}

test_v28_semantic_finding_id_symmetric() {
    local num=28 name="semantic-finding-id-same-from-either-side"
    local test_dir; test_dir=$(new_case_dir "v$num")
    trap "rm -rf '$test_dir'" RETURN
    local repo="$test_dir/repo"
    mkdir -p "$repo"
    fixture_v2 "$repo" >/dev/null 2>&1

    local peer="$test_dir/peer"
    if ! git_in "$repo" worktree add -q "$peer" branch_b >/dev/null 2>&1; then
        report_result $num "$name" "SKIP" "could not add peer worktree"
        return
    fi

    local fid_self fid_peer
    fid_self=$(json_get "$(run_verify_uncached "$repo")" "finding_id" 0)
    fid_peer=$(json_get "$(run_verify_uncached "$peer")" "finding_id" 0)

    if [ -n "$fid_self" ] && [ "$fid_self" = "$fid_peer" ]; then
        report_result $num "$name" "PASS"
    else
        report_result $num "$name" "FAIL" "self=$fid_self peer=$fid_peer"
    fi
}

test_v30_pre_v2_records_ignored_not_fatal() {
    local num=30 name="pre-v2-records-counted-and-set-aside"
    local test_dir; test_dir=$(new_case_dir "v$num")
    trap "rm -rf '$test_dir'" RETURN
    local repo="$test_dir/repo"
    mkdir -p "$repo"
    fixture_v2 "$repo" >/dev/null 2>&1

    if ! git_in "$repo" worktree add -q "$test_dir/peer" branch_b >/dev/null 2>&1; then
        report_result $num "$name" "SKIP" "could not add peer worktree"
        return
    fi
    if ! run_verify_uncached "$repo" >/dev/null; then
        report_result $num "$name" "SKIP" "moire verify failed"
        return
    fi

    # Rewrite the shard as a record of the shape 0.10.0 wrote: same fields,
    # "v": 1, and a finding_id computed the old path-only way. `report` must
    # count it as ignored rather than mixing an incomparable record into a
    # rate - and must not crash on it.
    python3 - "$repo/.git/moire/log" <<'PY'
import glob, json, os, sys
for p in sorted(glob.glob(os.path.join(sys.argv[1], "*.json"))):
    with open(p) as f:
        arr = json.load(f)
    for r in arr:
        r["v"] = 1
    with open(p, "w") as f:
        json.dump(arr, f)
PY

    local rj rc human
    rj=$(cd "$repo" && MOIRE_GIT="$GIT_PROG" "$MOIRE_BIN" report --json 2>/dev/null)
    rc=$?
    human=$(cd "$repo" && MOIRE_GIT="$GIT_PROG" "$MOIRE_BIN" report 2>/dev/null)

    local ignored states sem_findings
    ignored=$(json_get "$rj" "pre_v2_records_ignored" 0)
    states=$(json_get "$rj" "pair_states_evaluated" 0)
    sem_findings=$(json_get "$rj" "distinct_findings.semantic" 0)

    local human_names_it=no
    echo "$human" | grep -q "pre-v2 records ignored            : 1" && human_names_it=yes

    if [ "$rc" -eq 0 ] && [ "$ignored" = "1" ] && [ "$states" = "0" ] \
       && [ "$sem_findings" = "0" ] && [ "$human_names_it" = "yes" ]; then
        report_result $num "$name" "PASS"
    else
        report_result $num "$name" "FAIL" \
            "exit=$rc ignored=$ignored pair_states=$states distinct_semantic=$sem_findings human_line=$human_names_it"
    fi
}

# ---- A5: a finding computed from a cached peer snapshot is re-derived
# ---- against the peer's state right now before it is emitted. Stale-clean is
# ---- accepted (bounded by the TTL, self-correcting); stale-FINDING is not -
# ---- it is the one mode where moire is confidently wrong in the direction of
# ---- a warning.

test_v29_cached_finding_recomputed() {
    local num=29 name="cached-finding-recomputed-before-emit"
    local test_dir; test_dir=$(new_case_dir "v$num")
    trap "rm -rf '$test_dir'" RETURN
    local repo="$test_dir/repo"
    mkdir -p "$repo"
    init_repo "$repo"
    printf 'line1\n' > "$repo/shared.txt"
    git_in "$repo" add -A
    git_in "$repo" commit -qm base >/dev/null 2>&1
    local base; base=$(git_in "$repo" rev-parse HEAD)
    git_in "$repo" checkout -q -b branch_a >/dev/null 2>&1
    printf 'line1 self\n' > "$repo/shared.txt"
    git_in "$repo" commit -qam "self edits shared.txt" >/dev/null 2>&1
    git_in "$repo" checkout -q "$base" >/dev/null 2>&1
    git_in "$repo" checkout -q -b branch_b >/dev/null 2>&1
    git_in "$repo" checkout -q branch_a >/dev/null 2>&1

    local peer="$test_dir/peer"
    if ! git_in "$repo" worktree add -q "$peer" branch_b >/dev/null 2>&1; then
        report_result $num "$name" "SKIP" "could not add peer worktree"
        return
    fi

    # The peer's collision is UNCOMMITTED: it touches neither HEAD nor the
    # index, which is exactly the state the snapshot cache cannot see change.
    printf 'line1 peer\n' > "$peer/shared.txt"

    local run_check
    run_check() {
        (cd "$repo" && MOIRE_CACHE_TTL=60 MOIRE_GIT="$GIT_PROG" "$MOIRE_BIN" check --json 2>/dev/null)
    }

    local j1 v1
    j1=$(run_check); v1=$(json_get "$j1" "verdict" 0)
    local j2 v2 cached2 recomputed2
    j2=$(run_check)
    v2=$(json_get "$j2" "verdict" 0)
    cached2=$(json_bool "$j2" "cached.peer" 0)
    recomputed2=$(json_bool "$j2" "cached.peer_recomputed" 0)

    # The peer withdraws its edit in the working tree only. HEAD and the index
    # are untouched, so the cache entry still looks valid and within TTL.
    printf 'line1\n' > "$peer/shared.txt"

    local j3 v3 cached3 recomputed3
    j3=$(run_check)
    v3=$(json_get "$j3" "verdict" 0)
    cached3=$(json_bool "$j3" "cached.peer" 0)
    recomputed3=$(json_bool "$j3" "cached.peer_recomputed" 0)

    if [ "$v1" = "conflict" ] && [ "$v2" = "conflict" ] && [ "$cached2" = "true" ] \
       && [ "$recomputed2" = "true" ] && [ "$v3" = "clean" ] && [ "$cached3" = "true" ] \
       && [ "$recomputed3" = "true" ]; then
        report_result $num "$name" "PASS"
    else
        report_result $num "$name" "FAIL" \
            "first=$v1; second=$v2 (cached=$cached2 recomputed=$recomputed2); after peer reverted=$v3 (cached=$cached3 recomputed=$recomputed3)"
    fi
}

# ---- A6: the two reproduced false-BROKEN classes. Both fire on completely
# ---- ordinary agent behaviour - a `git mv`, and installing a dependency -
# ---- and both report one party's own state, or an artifact of where a
# ---- borrowed directory came from, as a collision the pair created.

# base: src/y.py holds a VALID import. peer: `git mv src/y.py src/z.py`.
# self: the same file, with an import that resolves nowhere - self's own
# problem, and nobody else's.
#
# The trap this fixture exists to avoid: put the breakage in the BASE and the
# peer carries it too, so it cancels through peer_broken and the bug does not
# reproduce at all. It must belong to self alone.
fixture_rename() {
    local repo="$1"
    init_repo "$repo"
    mkdir -p "$repo/src"
    printf 'def real_thing():\n    return 1\n' > "$repo/src/lib.py"
    printf 'from src.lib import real_thing\nreal_thing()\n' > "$repo/src/y.py"
    : > "$repo/src/__init__.py"
    git_in "$repo" add -A
    git_in "$repo" commit -qm base >/dev/null 2>&1
    local base; base=$(git_in "$repo" rev-parse HEAD)

    git_in "$repo" checkout -q "$base" >/dev/null 2>&1
    git_in "$repo" checkout -q -b branch_b >/dev/null 2>&1
    git_in "$repo" mv src/y.py src/z.py >/dev/null 2>&1
    git_in "$repo" commit -qm "peer: git mv src/y.py src/z.py" >/dev/null 2>&1

    git_in "$repo" checkout -q "$base" >/dev/null 2>&1
    git_in "$repo" checkout -q -b branch_a >/dev/null 2>&1
    printf 'from src.lib import does_not_exist\ndoes_not_exist()\n' > "$repo/src/y.py"
    git_in "$repo" commit -qam "self: its own broken import in src/y.py" >/dev/null 2>&1
}

test_v31_rename_relocated_breakage_cancels() {
    local num=31 name="peer-rename-does-not-relocate-self-s-own-breakage"
    local test_dir; test_dir=$(new_case_dir "v$num")
    trap "rm -rf '$test_dir'" RETURN
    local repo="$test_dir/repo"
    mkdir -p "$repo"
    fixture_rename "$repo" >/dev/null 2>&1

    if ! git_in "$repo" worktree add -q "$test_dir/peer" branch_b >/dev/null 2>&1; then
        report_result $num "$name" "SKIP" "could not add peer worktree"
        return
    fi

    # GROUND TRUTH, computed without moire: merge the two branches with git's
    # own merge-tree, materialise the result, and confirm the broken import IS
    # there, at the renamed path. Silence is only correct if the tool saw the
    # breakage and attributed it to self - not if it missed it.
    local gt_tree gt_dir gt_present=no
    gt_tree=$(git_in "$repo" merge-tree --write-tree branch_a branch_b 2>/dev/null | head -1)
    gt_dir="$test_dir/ground_truth"
    mkdir -p "$gt_dir"
    if [ -n "$gt_tree" ]; then
        (cd "$repo" && "$GIT_PROG" archive "$gt_tree" | tar -x -C "$gt_dir") >/dev/null 2>&1
        [ -f "$gt_dir/src/z.py" ] && grep -q "does_not_exist" "$gt_dir/src/z.py" && gt_present=yes
    fi

    local json
    json=$(run_verify_uncached "$repo")
    local summary
    summary=$(python3 -c "
import json
s = json.loads('''$json''')[0]['semantic']
print('yes' if s['new_breakage'] == [] else 'no',
      'yes' if (s.get('renames') or {}).get('self') == [['src/y.py', 'src/z.py']] else 'no',
      s['self_broken'], s['peer_broken'], s['merged_broken'],
      (s.get('canonicalised') or {}).get('self'))
" 2>/dev/null)
    local nb_empty rename_recorded self_broken peer_broken merged_broken canon
    read -r nb_empty rename_recorded self_broken peer_broken merged_broken canon <<<"$summary"

    if [ "$gt_present" = "yes" ] && [ "$nb_empty" = "yes" ] && [ "$rename_recorded" = "yes" ] \
       && [ "$self_broken" = "1" ] && [ "$peer_broken" = "0" ] && [ "$merged_broken" = "1" ] \
       && [ "$canon" = "1" ]; then
        report_result $num "$name" "PASS"
    else
        report_result $num "$name" "FAIL" \
            "ground_truth_breakage_in_merged_tree=$gt_present new_breakage_empty=$nb_empty renames.self=$rename_recorded self=$self_broken peer=$peer_broken merged=$merged_broken canonicalised.self=$canon"
    fi
}

test_v32_rename_canonicalises_external_findings() {
    local num=32 name="peer-rename-cancels-external-checker-findings-too"
    local test_dir; test_dir=$(new_case_dir "v$num")
    trap "rm -rf '$test_dir'" RETURN
    local repo="$test_dir/repo"
    mkdir -p "$repo"

    init_repo "$repo"
    mkdir -p "$repo/src"
    printf 'ok\n' > "$repo/src/y.txt"
    git_in "$repo" add -A
    git_in "$repo" commit -qm base >/dev/null 2>&1
    local base; base=$(git_in "$repo" rev-parse HEAD)

    git_in "$repo" checkout -q -b branch_b >/dev/null 2>&1
    git_in "$repo" mv src/y.txt src/z.txt >/dev/null 2>&1
    git_in "$repo" commit -qm "peer: git mv src/y.txt src/z.txt" >/dev/null 2>&1

    git_in "$repo" checkout -q "$base" >/dev/null 2>&1
    git_in "$repo" checkout -q -b branch_a >/dev/null 2>&1
    printf 'BAD 1\nBAD 2\nBAD 3\nBAD 4\nBAD 5\n' > "$repo/src/y.txt"
    git_in "$repo" commit -qam "self: five of its own findings in src/y.txt" >/dev/null 2>&1

    if ! git_in "$repo" worktree add -q "$test_dir/peer" branch_b >/dev/null 2>&1; then
        report_result $num "$name" "SKIP" "could not add peer worktree"
        return
    fi

    # A path-prefixed external checker, the shape the --checker contract asks
    # for: "<path>:<line>: <message>". Five findings, all in one file, all
    # self's own - and the merged tree spells that file's path differently.
    local checker="$test_dir/checker.sh"
    cat > "$checker" <<'CHK'
#!/bin/sh
for f in src/*.txt; do
  [ -f "$f" ] || continue
  grep -n 'BAD' "$f" | while IFS=: read -r n _rest; do
    echo "$f:$n: bad marker"
  done
done
CHK
    chmod +x "$checker"

    local json
    json=$(run_verify_uncached "$repo" --checker "$checker")
    local summary
    summary=$(python3 -c "
import json
s = json.loads('''$json''')[0]['semantic']
print('yes' if s['new_breakage'] == [] else 'no',
      (s.get('canonicalised') or {}).get('self'), s['self_broken'], s['merged_broken'])
" 2>/dev/null)
    local nb_empty canon self_broken merged_broken
    read -r nb_empty canon self_broken merged_broken <<<"$summary"

    if [ "$nb_empty" = "yes" ] && [ "$canon" = "5" ] && [ "$self_broken" = "5" ] \
       && [ "$merged_broken" = "5" ]; then
        report_result $num "$name" "PASS"
    else
        report_result $num "$name" "FAIL" \
            "new_breakage_empty=$nb_empty canonicalised.self=$canon self_broken=$self_broken merged_broken=$merged_broken"
    fi
}

test_v33_rename_true_positive_still_reported() {
    local num=33 name="rename-canonicalisation-does-not-swallow-a-real-collision"
    local test_dir; test_dir=$(new_case_dir "v$num")
    trap "rm -rf '$test_dir'" RETURN
    local repo="$test_dir/repo"
    mkdir -p "$repo"

    # The peer renames a file AND removes a name; self adds a brand-new file
    # that references that name. Disjoint file sets, clean textual merge, and
    # a genuine collision that must survive canonicalisation.
    init_repo "$repo"
    mkdir -p "$repo/src"
    : > "$repo/src/__init__.py"
    printf 'def used_name():\n    return 1\n' > "$repo/src/lib.py"
    printf 'x = 1\n' > "$repo/src/y.py"
    git_in "$repo" add -A
    git_in "$repo" commit -qm base >/dev/null 2>&1
    local base; base=$(git_in "$repo" rev-parse HEAD)

    git_in "$repo" checkout -q -b branch_b >/dev/null 2>&1
    git_in "$repo" mv src/y.py src/z.py >/dev/null 2>&1
    printf 'def renamed_name():\n    return 1\n' > "$repo/src/lib.py"
    git_in "$repo" commit -qam "peer: git mv, and rename used_name away" >/dev/null 2>&1

    git_in "$repo" checkout -q "$base" >/dev/null 2>&1
    git_in "$repo" checkout -q -b branch_a >/dev/null 2>&1
    printf 'from src.lib import used_name\nused_name()\n' > "$repo/src/new_caller.py"
    git_in "$repo" add -A
    git_in "$repo" commit -qm "self: new file calling used_name" >/dev/null 2>&1

    if ! git_in "$repo" worktree add -q "$test_dir/peer" branch_b >/dev/null 2>&1; then
        report_result $num "$name" "SKIP" "could not add peer worktree"
        return
    fi

    local json human
    json=$(run_verify_uncached "$repo")
    human=$(cd "$repo" && MOIRE_CACHE_TTL=0 MOIRE_GIT="$GIT_PROG" "$MOIRE_BIN" verify 2>/dev/null)

    local summary
    summary=$(python3 -c "
import json
s = json.loads('''$json''')[0]['semantic']
nb = s['new_breakage']
# The rename shows up in the SELF->merged map: self is the side that still
# spells the file src/y.py, the peer already renamed it.
print('yes' if nb == [['src/new_caller.py', 'src.lib', 'used_name']] else 'no',
      'yes' if (s.get('renames') or {}).get('self') == [['src/y.py', 'src/z.py']] else 'no',
      s['self_broken'], s['peer_broken'])
" 2>/dev/null)
    local nb_right rename_seen self_broken peer_broken
    read -r nb_right rename_seen self_broken peer_broken <<<"$summary"

    local broken_line=no
    echo "$human" | grep -q '^BROKEN' && broken_line=yes

    if [ "$nb_right" = "yes" ] && [ "$rename_seen" = "yes" ] && [ "$self_broken" = "0" ] \
       && [ "$peer_broken" = "0" ] && [ "$broken_line" = "yes" ]; then
        report_result $num "$name" "PASS"
    else
        report_result $num "$name" "FAIL" \
            "new_breakage_is_the_real_one=$nb_right rename_recorded=$rename_seen self=$self_broken peer=$peer_broken printed_BROKEN=$broken_line"
    fi
}

# The peer installs something into its own linked directory and commits code
# that uses it. The merged tree has the peer's code and (before this fix)
# self's directory, so the checker cannot resolve the entry - reported as
# breakage the pair created, which it is not.
fixture_link_union() {
    local repo="$1"
    init_repo "$repo"
    mkdir -p "$repo/src"
    printf 'deps/\n' > "$repo/.gitignore"
    printf 'import a\n' > "$repo/src/app.py"
    git_in "$repo" add -A
    git_in "$repo" commit -qm base >/dev/null 2>&1
    local base; base=$(git_in "$repo" rev-parse HEAD)

    git_in "$repo" checkout -q -b branch_b >/dev/null 2>&1
    printf 'import b\n' > "$repo/src/newfeature.py"
    git_in "$repo" add -A
    git_in "$repo" commit -qm "peer: add src/newfeature.py using b" >/dev/null 2>&1

    git_in "$repo" checkout -q "$base" >/dev/null 2>&1
    git_in "$repo" checkout -q -b branch_a >/dev/null 2>&1
    printf 'import a\n# self edits its own file\n' > "$repo/src/app.py"
    git_in "$repo" commit -qam "self: edit src/app.py" >/dev/null 2>&1
}

# A stand-in for a real toolchain, with zero package-manager knowledge in it:
# every `import X` at the top of a src file must have a matching deps/X entry
# in the tree the checker was given.
write_deps_checker() {
    local path="$1"
    cat > "$path" <<'CHK'
#!/bin/sh
for f in src/*.py; do
  [ -f "$f" ] || continue
  grep -o '^import [A-Za-z_][A-Za-z0-9_]*' "$f" | awk '{print $2}' | while read -r m; do
    [ -d "deps/$m" ] || echo "$f: cannot resolve module $m"
  done
done
CHK
    chmod +x "$path"
}

test_v34_link_union_covers_peer_added_entry() {
    local num=34 name="merged-tree-links-the-union-of-both-worktrees"
    local test_dir; test_dir=$(new_case_dir "v$num")
    trap "rm -rf '$test_dir'" RETURN
    local repo="$test_dir/repo"
    mkdir -p "$repo"
    fixture_link_union "$repo" >/dev/null 2>&1

    local peer="$test_dir/peer"
    if ! git_in "$repo" worktree add -q "$peer" branch_b >/dev/null 2>&1; then
        report_result $num "$name" "SKIP" "could not add peer worktree"
        return
    fi

    # self has only `a`; the peer installed `b` alongside it.
    mkdir -p "$repo/deps/a" "$peer/deps/a" "$peer/deps/b"
    : > "$repo/deps/a/entry"; : > "$peer/deps/a/entry"; : > "$peer/deps/b/entry"

    local checker="$test_dir/checker.sh"
    write_deps_checker "$checker"

    local json human
    json=$(run_verify_uncached "$repo" --checker "$checker" --link deps)
    human=$(cd "$repo" && MOIRE_CACHE_TTL=0 MOIRE_GIT="$GIT_PROG" "$MOIRE_BIN" verify \
            --checker "$checker" --link deps 2>/dev/null)

    local summary
    summary=$(python3 -c "
import json
s = json.loads('''$json''')[0]['semantic']
m = (s.get('linked') or {}).get('merged') or {}
d = m.get('deps') or {}
print('yes' if s['new_breakage'] == [] else 'no', d.get('mode'),
      'yes' if d.get('from_peer') == ['b'] else 'no', d.get('peer_only_count'))
" 2>/dev/null)
    local nb_empty mode from_peer peer_only
    read -r nb_empty mode from_peer peer_only <<<"$summary"

    local says_union=no
    echo "$human" | grep -q "linked directory 'deps'" && says_union=yes

    if [ "$nb_empty" = "yes" ] && [ "$mode" = "union" ] && [ "$from_peer" = "yes" ] \
       && [ "$peer_only" = "1" ] && [ "$says_union" = "yes" ]; then
        report_result $num "$name" "PASS"
    else
        report_result $num "$name" "FAIL" \
            "new_breakage_empty=$nb_empty mode=$mode from_peer_is_b=$from_peer peer_only_count=$peer_only human_names_it=$says_union"
    fi
}

test_v35_link_union_both_present_prefers_self() {
    local num=35 name="union-prefers-self-for-both-present-entries"
    local test_dir; test_dir=$(new_case_dir "v$num")
    trap "rm -rf '$test_dir'" RETURN
    local repo="$test_dir/repo"
    mkdir -p "$repo"
    fixture_link_union "$repo" >/dev/null 2>&1

    local peer="$test_dir/peer"
    if ! git_in "$repo" worktree add -q "$peer" branch_b >/dev/null 2>&1; then
        report_result $num "$name" "SKIP" "could not add peer worktree"
        return
    fi

    # Both worktrees have deps/a, with DIFFERENT content, and the peer also
    # has deps/b. The checker reports the content of deps/a it can see, so
    # whose copy the merged tree used is directly observable: if it used
    # self's, merged's finding is identical to self's and cancels.
    mkdir -p "$repo/deps/a" "$peer/deps/a" "$peer/deps/b"
    printf 'self copy\n' > "$repo/deps/a/VERSION"
    printf 'peer copy\n' > "$peer/deps/a/VERSION"
    : > "$peer/deps/b/entry"

    local checker="$test_dir/checker.sh"
    cat > "$checker" <<'CHK'
#!/bin/sh
echo "deps/a/VERSION: $(cat deps/a/VERSION 2>/dev/null || echo missing)"
CHK
    chmod +x "$checker"

    local json rc
    json=$(run_verify_uncached "$repo" --checker "$checker" --link deps)
    rc=$?

    local summary
    summary=$(python3 -c "
import json
s = json.loads('''$json''')[0]['semantic']
d = ((s.get('linked') or {}).get('merged') or {}).get('deps') or {}
print('yes' if s['new_breakage'] == [] else 'no', d.get('mode'), s['merged_broken'])
" 2>/dev/null)
    local nb_empty mode merged_broken
    read -r nb_empty mode merged_broken <<<"$summary"

    # And with no divergence in the entry SETS (both have exactly deps/a,
    # still different content) there is no union to build: self's directory is
    # linked whole, exactly as before.
    rm -rf "$peer/deps/b"
    local json2 mode2
    json2=$(run_verify_uncached "$repo" --checker "$checker" --link deps)
    mode2=$(python3 -c "
import json
s = json.loads('''$json2''')[0]['semantic']
print((((s.get('linked') or {}).get('merged') or {}).get('deps') or {}).get('mode'))
" 2>/dev/null)

    if [ "$rc" -eq 0 ] && [ "$nb_empty" = "yes" ] && [ "$mode" = "union" ] \
       && [ "$merged_broken" = "1" ] && [ "$mode2" = "self" ]; then
        report_result $num "$name" "PASS"
    else
        report_result $num "$name" "FAIL" \
            "exit=$rc new_breakage_empty=$nb_empty mode=$mode merged_broken=$merged_broken mode_without_divergence=$mode2"
    fi
}

test_v36_toplevel_compound_statements_bind_names() {
    local num=36 name="builtin-ast-sees-names-bound-in-top-level-for-while-with"
    local test_dir; test_dir=$(new_case_dir "v$num")
    trap "rm -rf '$test_dir'" RETURN
    local repo="$test_dir/repo"
    mkdir -p "$repo"

    # Self adds an importer of a module that does not exist on its side; the
    # peer adds that module, binding every name inside a top-level compound
    # statement. Only the MERGED tree has both, so nothing cancels: a checker
    # that cannot see a name bound by `for`/`while`/`with` reports the merged
    # pair as newly broken over three names that are really there.
    init_repo "$repo"
    printf 'x = 1\n' > "$repo/other.py"
    git_in "$repo" add -A
    git_in "$repo" commit -qm base >/dev/null 2>&1
    local base; base=$(git_in "$repo" rev-parse HEAD)

    git_in "$repo" checkout -q -b branch_a >/dev/null 2>&1
    printf 'from newmod import FROM_FOR, FROM_WHILE, FROM_WITH\nprint(FROM_FOR, FROM_WHILE, FROM_WITH)\n' > "$repo/self_caller.py"
    git_in "$repo" add -A
    git_in "$repo" commit -qm "self: new importer of a module it does not have" >/dev/null 2>&1

    git_in "$repo" checkout -q "$base" >/dev/null 2>&1
    git_in "$repo" checkout -q -b branch_b >/dev/null 2>&1
    printf 'import io\n\nfor _i in (1,):\n    FROM_FOR = 1\n\nwhile True:\n    FROM_WHILE = 2\n    break\n\nwith io.StringIO() as _f:\n    FROM_WITH = 3\n' > "$repo/newmod.py"
    git_in "$repo" add -A
    git_in "$repo" commit -qm "peer: add newmod.py binding names in compound statements" >/dev/null 2>&1
    git_in "$repo" checkout -q branch_a >/dev/null 2>&1

    if ! git_in "$repo" worktree add -q "$test_dir/peer" branch_b >/dev/null 2>&1; then
        report_result $num "$name" "SKIP" "could not add peer worktree"
        return
    fi

    local json
    json=$(run_verify_uncached "$repo")
    local summary
    summary=$(python3 -c "
import json
s = json.loads('''$json''')[0]['semantic']
print('yes' if s['new_breakage'] == [] else 'no', s['merged_broken'], s['peer_broken'])
" 2>/dev/null)
    local nb_empty merged_broken peer_broken
    read -r nb_empty merged_broken peer_broken <<<"$summary"

    if [ "$nb_empty" = "yes" ] && [ "$merged_broken" = "0" ] && [ "$peer_broken" = "0" ]; then
        report_result $num "$name" "PASS"
    else
        report_result $num "$name" "FAIL" \
            "new_breakage_empty=$nb_empty merged_broken=$merged_broken peer_broken=$peer_broken"
    fi
}

# === MAIN ===

main() {
    # Check if bin/moire exists and is executable
    if [ ! -x "$MOIRE_BIN" ]; then
        echo "SKIP: bin/moire not present"
        exit 0
    fi

    # Find suitable git
    if ! GIT_PROG=$(find_git); then
        echo "SKIP: git >= 2.38 required"
        exit 0
    fi

    # Setup environment
    setup_git_env
    TMPDIR_ROOT=$(mktemp -d)

    # Run all test cases
    test_v1_clean_disjoint
    test_v2_canonical_case
    test_v3_self_preexisting_cancels
    test_v4_peer_preexisting_cancels
    test_v5_warn_only_exit_zero
    test_v6_v7_external_checker_whole_string
    test_v8_builtin_runs_under_conflict
    test_v9_external_checker_refuses_under_conflict
    test_v10_conflict_paths_excluded
    test_v11_self_checked_once_across_peers
    test_v12_link_names_a_directory
    test_v13_link_path_traversal_rejected
    test_v14_link_missing_directory_skipped
    test_v15_report_semantic_fields
    test_v16_report_skipped_semantic_checks
    test_v17_no_deprecation_warning
    test_v18_doctor_warn_missing_dep_dir
    test_v19_ts_repro_no_semantic_claim
    test_v20_python_repo_coverage_reported
    test_v21_git_config_checker_used_and_flag_wins
    test_v22_git_config_link_and_invalid_link_refused
    test_v23_report_excludes_unperformed
    test_v24_doctor_checker_applicability
    test_v25_report_counts_pair_states_not_observations
    test_v26_report_distinguishes_pair_states
    test_v27_finding_id_distinguishes_breakages_in_one_file
    test_v28_semantic_finding_id_symmetric
    test_v30_pre_v2_records_ignored_not_fatal
    test_v29_cached_finding_recomputed
    test_v31_rename_relocated_breakage_cancels
    test_v32_rename_canonicalises_external_findings
    test_v33_rename_true_positive_still_reported
    test_v34_link_union_covers_peer_added_entry
    test_v35_link_union_both_present_prefers_self
    test_v36_toplevel_compound_statements_bind_names

    # Print summary
    local total=$((PASSED + FAILED + SKIPPED))
    echo ""
    echo "Summary: $total cases, $PASSED passed, $FAILED failed, $SKIPPED skipped"

    if [ "$FAILED" -gt 0 ]; then
        exit 1
    fi
    exit 0
}

main "$@"
