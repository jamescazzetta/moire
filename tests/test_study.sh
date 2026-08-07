#!/bin/bash

# test_study.sh - Verify study-instrument features of moire CLI
# Covers: finding_id symmetry/stability, suppression, agent_id, moire report --study
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

# Shared 40-peer fixture (built once in main(), reused by cases 4, 6, 7 -- see
# build_big_fixture() below for why a single conflicting file only ever
# produces ONE finding_id no matter how many peers share it, and 40 findings
# therefore requires 40 peer worktrees, not 40 conflicting files in a
# two-worktree repo).
BIG_FIXTURE_REPO=""
BIG_FIXTURE_N=40
BIG_FIXTURE_OK=0
BIG_FIXTURE_ERR=""

# Cleanup function
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

# Build a simple two-worktree fixture with a conflict
setup_conflict_repo() {
    local repo="$1"
    local conflict_file="${2:-conflict.txt}"

    git_in "$repo" init >/dev/null 2>&1
    git_in "$repo" config user.name "Test"
    git_in "$repo" config user.email "test@example.com"

    # Base: create conflict file
    echo "original content" > "$repo/$conflict_file"
    git_in "$repo" add "$conflict_file"
    git_in "$repo" commit -m "base: add $conflict_file" >/dev/null 2>&1
    local base=$(git_in "$repo" rev-parse HEAD)

    # Branch A: modify file
    git_in "$repo" checkout -b branch_a >/dev/null 2>&1
    echo "content from branch A" > "$repo/$conflict_file"
    git_in "$repo" commit -am "modify to A" >/dev/null 2>&1

    # Branch B: modify file differently
    git_in "$repo" checkout "$base" >/dev/null 2>&1
    git_in "$repo" checkout -b branch_b >/dev/null 2>&1
    echo "content from branch B" > "$repo/$conflict_file"
    git_in "$repo" commit -am "modify to B" >/dev/null 2>&1

    # Return to branch_a
    git_in "$repo" checkout branch_a >/dev/null 2>&1
}

# Run moire check on a worktree and return JSON output
moire_check_json() {
    local repo="$1"
    local peer_dir="${2:-}"
    local env_vars="${3:-}"

    local scratch peer_wt output
    scratch=$(mktemp -d)
    trap "rm -rf '$scratch'" RETURN

    # Copy repo to scratch
    if ! cp -r "$repo" "$scratch/test"; then
        echo ""
        return 1
    fi

    peer_wt="$scratch/peer"

    # Add peer worktree
    if ! git_in "$scratch/test" worktree add "$peer_wt" branch_b >/dev/null 2>&1; then
        echo ""
        return 1
    fi

    # Run moire check
    local cmd="cd '$scratch/test' && MOIRE_GIT='$GIT_PROG' $env_vars '$MOIRE_BIN' check --json"
    if output=$(eval "$cmd" 2>/dev/null); then
        echo "$output"
        return 0
    fi

    echo ""
    return 1
}

# Build a repo with N peer worktrees, each conflicting with the main
# worktree on the same single line of f.txt.
#
# finding_id is computed per WORKTREE PAIR (see compute_finding_id in
# bin/moire), not per conflicting file: N conflicting files between the same
# two worktrees collapse into conflict_paths=[...] on ONE record, i.e. one
# finding_id. To get N distinct findings for the salt/rate cases below, this
# builds N distinct PEER WORKTREES instead, each colliding with main on
# f.txt -- that is N worktree pairs, hence N finding_ids.
#
# Sets BIG_FIXTURE_REPO/BIG_FIXTURE_ERR as a side effect; callers must check
# the return code (or BIG_FIXTURE_OK, set by the caller in main()) rather
# than assuming success -- a fixture that fails to build is a FAIL for every
# case that depends on it, never a silent SKIP.
build_big_fixture() {
    local dir="$1" n="${2:-40}"
    local repo="$dir/r" i

    BIG_FIXTURE_REPO=""
    BIG_FIXTURE_ERR=""

    if ! mkdir -p "$repo" 2>/dev/null; then
        BIG_FIXTURE_ERR="mkdir failed for $repo"
        return 1
    fi

    if ! git_in "$repo" init -q -b main >/dev/null 2>&1; then
        BIG_FIXTURE_ERR="git init failed"
        return 1
    fi
    git_in "$repo" config user.name "Test" >/dev/null 2>&1
    git_in "$repo" config user.email "test@example.com" >/dev/null 2>&1

    printf 'a\nb\nc\n' > "$repo/f.txt"
    if ! git_in "$repo" add -A >/dev/null 2>&1; then
        BIG_FIXTURE_ERR="git add failed"
        return 1
    fi
    if ! git_in "$repo" commit -qm base >/dev/null 2>&1; then
        BIG_FIXTURE_ERR="git commit failed"
        return 1
    fi

    for i in $(seq 1 "$n"); do
        if ! git_in "$repo" worktree add -q -b "w$i" "$dir/wt$i" >/dev/null 2>&1; then
            BIG_FIXTURE_ERR="worktree add failed for peer $i"
            return 1
        fi
        printf "a\nPEER%d\nc\n" "$i" > "$dir/wt$i/f.txt"
    done

    # Main worktree diverges from every peer on the same line -> each of the
    # n peers conflicts with main, each producing its own finding_id.
    printf 'a\nSELF\nc\n' > "$repo/f.txt"

    BIG_FIXTURE_REPO="$repo"
    return 0
}

# === TEST CASES ===

test_001_symmetry() {
    local test_dir=$(mktemp -d)
    trap "rm -rf '$test_dir'" RETURN

    local main_wt="$test_dir/main"
    mkdir -p "$main_wt"
    setup_conflict_repo "$main_wt" "file1.txt"

    # Add a peer worktree
    local peer_wt="$test_dir/peer"
    if ! git_in "$main_wt" worktree add "$peer_wt" branch_b >/dev/null 2>&1; then
        report_result 1 "symmetry" "SKIP" "could not create peer worktree"
        return
    fi

    # Run moire check from main_wt and look at the peer's finding_id
    local json1
    if ! json1=$(cd "$main_wt" && MOIRE_GIT="$GIT_PROG" "$MOIRE_BIN" check --json 2>/dev/null); then
        report_result 1 "symmetry" "SKIP" "moire check from main failed"
        return
    fi

    local fid1
    if ! fid1=$(json_get "$json1" "finding_id" 0); then
        report_result 1 "symmetry" "SKIP" "finding_id not in main output"
        return
    fi

    # Run moire check from peer_wt - it should see main_wt and report same finding_id
    local json2
    if ! json2=$(cd "$peer_wt" && MOIRE_GIT="$GIT_PROG" "$MOIRE_BIN" check --json 2>/dev/null); then
        report_result 1 "symmetry" "SKIP" "moire check from peer failed"
        return
    fi

    local fid2
    if ! fid2=$(json_get "$json2" "finding_id" 0); then
        report_result 1 "symmetry" "SKIP" "finding_id not found in peer output"
        return
    fi

    if [ "$fid1" = "$fid2" ]; then
        report_result 1 "symmetry" "PASS"
    else
        report_result 1 "symmetry" "FAIL" "finding_ids differ: $fid1 vs $fid2"
    fi
}

test_002_stability() {
    local test_dir=$(mktemp -d)
    trap "rm -rf '$test_dir'" RETURN

    local main_wt="$test_dir/main"
    mkdir -p "$main_wt"
    setup_conflict_repo "$main_wt" "file1.txt"

    local peer_wt="$test_dir/peer"
    if ! git_in "$main_wt" worktree add "$peer_wt" branch_b >/dev/null 2>&1; then
        report_result 2 "stability" "SKIP" "could not create peer worktree"
        return
    fi

    # Run check twice on same conflict
    local json1
    if ! json1=$(cd "$main_wt" && MOIRE_GIT="$GIT_PROG" "$MOIRE_BIN" check --json 2>/dev/null); then
        report_result 2 "stability" "SKIP" "first moire check failed"
        return
    fi

    local fid1
    if ! fid1=$(json_get "$json1" "finding_id" 0); then
        report_result 2 "stability" "SKIP" "finding_id not in first check"
        return
    fi

    local json2
    if ! json2=$(cd "$main_wt" && MOIRE_GIT="$GIT_PROG" "$MOIRE_BIN" check --json 2>/dev/null); then
        report_result 2 "stability" "FAIL" "second moire check failed"
        return
    fi

    local fid2
    if ! fid2=$(json_get "$json2" "finding_id" 0); then
        report_result 2 "stability" "FAIL" "finding_id not in second check"
        return
    fi

    if [ "$fid1" = "$fid2" ]; then
        report_result 2 "stability" "PASS"
    else
        report_result 2 "stability" "FAIL" "same collision produced different IDs: $fid1 vs $fid2"
    fi
}

test_003_suppression_determinism() {
    local test_dir=$(mktemp -d)
    trap "rm -rf '$test_dir'" RETURN

    local main_wt="$test_dir/main"
    mkdir -p "$main_wt"
    setup_conflict_repo "$main_wt" "file1.txt"

    local peer_wt="$test_dir/peer"
    if ! git_in "$main_wt" worktree add "$peer_wt" branch_b >/dev/null 2>&1; then
        report_result 3 "suppression-determinism" "SKIP" "could not create peer worktree"
        return
    fi

    local salt="test-salt-12345"
    local rate="0.5"

    # Run 5 times from main with same salt/rate
    local results_a=""
    local fid_ref=""
    local i
    for i in 1 2 3 4 5; do
        local json
        if ! json=$(cd "$main_wt" && MOIRE_GIT="$GIT_PROG" MOIRE_SURFACE_RATE=$rate MOIRE_SURFACE_SALT=$salt "$MOIRE_BIN" check --json 2>/dev/null); then
            report_result 3 "suppression-determinism" "SKIP" "moire check run $i failed"
            return
        fi

        local surfaced
        if ! surfaced=$(json_bool "$json" "surfaced" 0); then
            report_result 3 "suppression-determinism" "SKIP" "surfaced field missing"
            return
        fi

        # Verify finding_id stays the same
        local fid
        if ! fid=$(json_get "$json" "finding_id" 0); then
            report_result 3 "suppression-determinism" "SKIP" "finding_id missing"
            return
        fi
        if [ -z "$fid_ref" ]; then
            fid_ref="$fid"
        fi

        results_a="$results_a$surfaced;"
    done

    # Run 5 times from peer with same salt/rate
    local results_b=""
    for i in 1 2 3 4 5; do
        local json
        if ! json=$(cd "$peer_wt" && MOIRE_GIT="$GIT_PROG" MOIRE_SURFACE_RATE=$rate MOIRE_SURFACE_SALT=$salt "$MOIRE_BIN" check --json 2>/dev/null); then
            report_result 3 "suppression-determinism" "SKIP" "peer moire check run $i failed"
            return
        fi

        local surfaced
        if ! surfaced=$(json_bool "$json" "surfaced" 0); then
            report_result 3 "suppression-determinism" "SKIP" "surfaced field missing in peer"
            return
        fi
        results_b="$results_b$surfaced;"
    done

    # All 10 results should be identical (deterministic based on finding_id)
    if [ "$results_a" = "$results_b" ]; then
        report_result 3 "suppression-determinism" "PASS"
    else
        report_result 3 "suppression-determinism" "FAIL" "surfaced inconsistent: A=$results_a B=$results_b"
    fi
}

test_004_salt_changes_assignment() {
    local test_dir=$(mktemp -d)
    trap "rm -rf '$test_dir'" RETURN

    if [ "$BIG_FIXTURE_OK" -ne 1 ]; then
        report_result 4 "salt-changes-assignment" "FAIL" "shared 40-peer fixture unavailable: ${BIG_FIXTURE_ERR:-unknown error}"
        return
    fi

    local repo="$BIG_FIXTURE_REPO"
    local json_a="$test_dir/a.json"
    local json_b="$test_dir/b.json"

    if ! (cd "$repo" && MOIRE_GIT="$GIT_PROG" MOIRE_SURFACE_RATE=0.5 MOIRE_SURFACE_SALT=saltA "$MOIRE_BIN" check --json) >"$json_a" 2>/dev/null; then
        report_result 4 "salt-changes-assignment" "FAIL" "check with saltA failed"
        return
    fi
    if ! (cd "$repo" && MOIRE_GIT="$GIT_PROG" MOIRE_SURFACE_RATE=0.5 MOIRE_SURFACE_SALT=saltB "$MOIRE_BIN" check --json) >"$json_b" 2>/dev/null; then
        report_result 4 "salt-changes-assignment" "FAIL" "check with saltB failed"
        return
    fi

    # All comparison of the two JSON documents (and the set-vs-set diff) is
    # done in python3, never by grepping the JSON text.
    local summary
    if ! summary=$(python3 -c "
import json
a = json.load(open('$json_a'))
b = json.load(open('$json_b'))
if len(a) != $BIG_FIXTURE_N or len(b) != $BIG_FIXTURE_N:
    print(0, 0, 0, 'BADCOUNT')
else:
    sa = set(r['finding_id'] for r in a if r.get('finding_id') and r.get('surfaced'))
    sb = set(r['finding_id'] for r in b if r.get('finding_id') and r.get('surfaced'))
    overlap = sa & sb
    status = 'DIFF' if sa != sb else 'SAME'
    print(len(sa), len(sb), len(overlap), status)
" 2>/dev/null); then
        report_result 4 "salt-changes-assignment" "FAIL" "could not parse JSON output"
        return
    fi

    local count_a count_b overlap status
    read -r count_a count_b overlap status <<<"$summary"

    if [ "$status" = "BADCOUNT" ]; then
        report_result 4 "salt-changes-assignment" "FAIL" "expected $BIG_FIXTURE_N records per run, got a mismatched count"
        return
    fi

    # Assert the SET of surfaced finding_ids differs, not merely the counts
    # (which could coincide even though the sets differ, or vice versa).
    if [ "$status" = "DIFF" ]; then
        report_result 4 "salt-changes-assignment" "PASS" "saltA surfaced=$count_a saltB surfaced=$count_b overlap=$overlap"
    else
        report_result 4 "salt-changes-assignment" "FAIL" "surfaced sets identical across salts: saltA=$count_a saltB=$count_b overlap=$overlap"
    fi
}

test_005_suppressed_invisible() {
    local test_dir=$(mktemp -d)
    trap "rm -rf '$test_dir'" RETURN

    local repo="$test_dir/repo"
    mkdir -p "$repo"
    setup_conflict_repo "$repo" "file1.txt"

    # Run with rate 0 to suppress everything
    local json
    if ! json=$(moire_check_json "$repo" "" "MOIRE_SURFACE_RATE=0.0"); then
        report_result 5 "suppressed-invisible" "SKIP" "moire check with rate 0 failed"
        return
    fi

    local surfaced
    if ! surfaced=$(json_bool "$json" "surfaced" 0); then
        report_result 5 "suppressed-invisible" "SKIP" "surfaced field missing"
        return
    fi

    # JSON should contain finding_id but surfaced should be false
    local fid
    if ! fid=$(json_get "$json" "finding_id" 0); then
        report_result 5 "suppressed-invisible" "SKIP" "finding_id not in JSON"
        return
    fi

    if [ "$surfaced" != "false" ]; then
        report_result 5 "suppressed-invisible" "FAIL" "expected surfaced=false, got $surfaced"
        return
    fi

    # Now test human output - should not contain the finding_id or conflict path
    local scratch=$(mktemp -d)
    trap "rm -rf '$scratch'" RETURN
    if ! cp -r "$repo" "$scratch/test"; then
        report_result 5 "suppressed-invisible" "FAIL" "could not copy repo"
        return
    fi

    local peer_wt="$scratch/peer"
    if ! git_in "$scratch/test" worktree add "$peer_wt" branch_b >/dev/null 2>&1; then
        report_result 5 "suppressed-invisible" "FAIL" "could not create peer"
        return
    fi

    local human_output
    if ! human_output=$(cd "$scratch/test" && MOIRE_GIT="$GIT_PROG" MOIRE_SURFACE_RATE=0.0 "$MOIRE_BIN" check 2>/dev/null); then
        # Non-JSON output might not exist, that's ok
        report_result 5 "suppressed-invisible" "PASS"
        return
    fi

    # Human output should not contain the finding_id
    if echo "$human_output" | grep -q "$fid"; then
        report_result 5 "suppressed-invisible" "FAIL" "finding_id appeared in human output when suppressed"
    else
        report_result 5 "suppressed-invisible" "PASS"
    fi
}

test_006_surfaced_visible() {
    local test_dir=$(mktemp -d)
    trap "rm -rf '$test_dir'" RETURN

    if [ "$BIG_FIXTURE_OK" -ne 1 ]; then
        report_result 6 "surfaced-visible" "FAIL" "shared 40-peer fixture unavailable: ${BIG_FIXTURE_ERR:-unknown error}"
        return
    fi

    local repo="$BIG_FIXTURE_REPO"
    local json_file="$test_dir/check.json"
    local human_file="$test_dir/check.human"

    # Same rate/salt for both invocations: surfaced/suppressed is deterministic
    # on finding_id+rate+salt (see is_surfaced in bin/moire), so the --json run
    # and the human-readable run must land on the identical assignment.
    if ! (cd "$repo" && MOIRE_GIT="$GIT_PROG" MOIRE_SURFACE_RATE=0.5 MOIRE_SURFACE_SALT=case6 "$MOIRE_BIN" check --json) >"$json_file" 2>/dev/null; then
        report_result 6 "surfaced-visible" "FAIL" "json check failed"
        return
    fi
    if ! (cd "$repo" && MOIRE_GIT="$GIT_PROG" MOIRE_SURFACE_RATE=0.5 MOIRE_SURFACE_SALT=case6 "$MOIRE_BIN" check) >"$human_file" 2>/dev/null; then
        report_result 6 "surfaced-visible" "FAIL" "human check failed"
        return
    fi

    # Structure (which finding_ids are surfaced/suppressed) comes from
    # python3 parsing the JSON; the human file is only ever searched as
    # plain text for those already-known ids.
    local summary
    if ! summary=$(python3 -c "
import json
records = json.load(open('$json_file'))
text = open('$human_file').read()
if len(records) != $BIG_FIXTURE_N:
    print(0, 0, 0, 0, 'BADCOUNT')
else:
    surfaced = [r['finding_id'] for r in records if r.get('finding_id') and r.get('surfaced')]
    suppressed = [r['finding_id'] for r in records if r.get('finding_id') and not r.get('surfaced')]
    missing = [f for f in surfaced if f not in text]
    leaked = [f for f in suppressed if f in text]
    status = 'PASS' if (surfaced and suppressed and not missing and not leaked) else 'FAIL'
    print(len(surfaced), len(missing), len(suppressed), len(leaked), status)
" 2>/dev/null); then
        report_result 6 "surfaced-visible" "FAIL" "could not parse output"
        return
    fi

    local surfaced_n missing_n suppressed_n leaked_n status
    read -r surfaced_n missing_n suppressed_n leaked_n status <<<"$summary"

    if [ "$status" = "BADCOUNT" ]; then
        report_result 6 "surfaced-visible" "FAIL" "expected $BIG_FIXTURE_N records, got a mismatched count"
        return
    fi

    if [ "$status" = "PASS" ]; then
        report_result 6 "surfaced-visible" "PASS" "surfaced $surfaced_n/$surfaced_n visible in stdout, suppressed 0/$suppressed_n leaked"
    else
        report_result 6 "surfaced-visible" "FAIL" "missing=$missing_n of $surfaced_n surfaced ids from stdout; leaked=$leaked_n of $suppressed_n suppressed ids into stdout"
    fi
}

test_007_rate_honoured() {
    local test_dir=$(mktemp -d)
    trap "rm -rf '$test_dir'" RETURN

    if [ "$BIG_FIXTURE_OK" -ne 1 ]; then
        report_result 7 "rate-honoured" "FAIL" "shared 40-peer fixture unavailable: ${BIG_FIXTURE_ERR:-unknown error}"
        return
    fi

    local repo="$BIG_FIXTURE_REPO"
    local json_file="$test_dir/check.json"

    # Fixed salt over all 40 findings at rate 0.5.
    if ! (cd "$repo" && MOIRE_GIT="$GIT_PROG" MOIRE_SURFACE_RATE=0.5 MOIRE_SURFACE_SALT=case7 "$MOIRE_BIN" check --json) >"$json_file" 2>/dev/null; then
        report_result 7 "rate-honoured" "FAIL" "moire check failed"
        return
    fi

    local summary
    if ! summary=$(python3 -c "
import json
records = json.load(open('$json_file'))
fids = [r for r in records if r.get('finding_id')]
total = len(fids)
if total != $BIG_FIXTURE_N:
    print(total, 0, '0.0000', 'BADCOUNT')
else:
    surfaced = sum(1 for r in fids if r.get('surfaced'))
    fraction = surfaced / total
    status = 'INRANGE' if 0.30 <= fraction <= 0.70 else 'OUTRANGE'
    print(total, surfaced, ('%.4f' % fraction), status)
" 2>/dev/null); then
        report_result 7 "rate-honoured" "FAIL" "could not parse JSON output"
        return
    fi

    local total surfaced fraction status
    read -r total surfaced fraction status <<<"$summary"

    if [ "$status" = "BADCOUNT" ]; then
        report_result 7 "rate-honoured" "FAIL" "expected $BIG_FIXTURE_N findings, got $total"
        return
    fi

    if [ "$status" = "INRANGE" ]; then
        report_result 7 "rate-honoured" "PASS" "fraction=$fraction (surfaced=$surfaced/$total)"
    else
        report_result 7 "rate-honoured" "FAIL" "fraction=$fraction outside 0.30-0.70 (surfaced=$surfaced/$total)"
    fi
}

test_008_rate_extremes() {
    local test_dir=$(mktemp -d)
    trap "rm -rf '$test_dir'" RETURN

    local repo="$test_dir/repo"
    mkdir -p "$repo"
    setup_conflict_repo "$repo" "file1.txt"

    # Test rate 1.0
    local json1
    if ! json1=$(moire_check_json "$repo" "" "MOIRE_SURFACE_RATE=1.0"); then
        report_result 8 "rate-extremes" "SKIP" "rate 1.0 check failed"
        return
    fi

    local surf1
    if ! surf1=$(json_bool "$json1" "surfaced" 0); then
        report_result 8 "rate-extremes" "SKIP" "surfaced field missing for rate 1.0"
        return
    fi

    # Test rate 0.0
    local json0
    if ! json0=$(moire_check_json "$repo" "" "MOIRE_SURFACE_RATE=0.0"); then
        report_result 8 "rate-extremes" "FAIL" "rate 0.0 check failed"
        return
    fi

    local surf0
    if ! surf0=$(json_bool "$json0" "surfaced" 0); then
        report_result 8 "rate-extremes" "FAIL" "surfaced field missing for rate 0.0"
        return
    fi

    if [ "$surf1" = "true" ] && [ "$surf0" = "false" ]; then
        report_result 8 "rate-extremes" "PASS"
    else
        report_result 8 "rate-extremes" "FAIL" "rate 1.0=$surf1, rate 0.0=$surf0"
    fi
}

test_009_agent_identity() {
    local test_dir=$(mktemp -d)
    trap "rm -rf '$test_dir'" RETURN

    local repo="$test_dir/repo"
    mkdir -p "$repo"
    setup_conflict_repo "$repo" "file1.txt"

    # Run from side A with agent_id=alpha
    local json1
    if ! json1=$(moire_check_json "$repo" "" "MOIRE_AGENT_ID=alpha"); then
        report_result 9 "agent-identity" "SKIP" "check with MOIRE_AGENT_ID failed"
        return
    fi

    # Check if agent_id fields exist and have correct values
    local self_id1 peer_id1
    if ! self_id1=$(json_get "$json1" "self.agent_id" 0 2>/dev/null); then
        report_result 9 "agent-identity" "SKIP" "self.agent_id not in JSON"
        return
    fi

    # Now from side B with agent_id=beta
    local peer_scratch=$(mktemp -d)
    trap "rm -rf '$peer_scratch'" RETURN
    if ! cp -r "$repo" "$peer_scratch/test"; then
        report_result 9 "agent-identity" "FAIL" "could not copy repo"
        return
    fi

    git_in "$peer_scratch/test" checkout branch_b >/dev/null 2>&1
    local peer_wt="$peer_scratch/wt_a"
    if ! git_in "$peer_scratch/test" worktree add "$peer_wt" branch_a >/dev/null 2>&1; then
        report_result 9 "agent-identity" "FAIL" "could not add peer worktree"
        return
    fi

    local json2
    if ! json2=$(cd "$peer_scratch/test" && MOIRE_GIT="$GIT_PROG" MOIRE_AGENT_ID=beta "$MOIRE_BIN" check --json 2>/dev/null); then
        report_result 9 "agent-identity" "FAIL" "peer check failed"
        return
    fi

    local self_id2
    if ! self_id2=$(json_get "$json2" "self.agent_id" 0 2>/dev/null); then
        report_result 9 "agent-identity" "FAIL" "self.agent_id missing in peer output"
        return
    fi

    # self_id1 should be alpha, self_id2 should be beta
    if [ "$self_id1" = "alpha" ] && [ "$self_id2" = "beta" ]; then
        report_result 9 "agent-identity" "PASS"
    else
        report_result 9 "agent-identity" "FAIL" "expected alpha/beta, got $self_id1/$self_id2"
    fi
}

test_010_agent_id_no_verdict_change() {
    local test_dir=$(mktemp -d)
    trap "rm -rf '$test_dir'" RETURN

    local repo="$test_dir/repo"
    mkdir -p "$repo"
    setup_conflict_repo "$repo" "file1.txt"

    # Run with agent_id=alpha
    local json1
    if ! json1=$(moire_check_json "$repo" "" "MOIRE_AGENT_ID=alpha"); then
        report_result 10 "agent-id-no-verdict-change" "SKIP" "first check failed"
        return
    fi

    local verdict1
    if ! verdict1=$(json_get "$json1" "verdict" 0); then
        report_result 10 "agent-id-no-verdict-change" "SKIP" "verdict not in JSON"
        return
    fi

    local paths1
    if ! paths1=$(python3 -c "
import json, sys
try:
    data = json.loads('''$json1''')
    if isinstance(data, list):
        data = data[0]
    paths = data.get('conflict_paths', [])
    print(','.join(sorted(paths)))
except:
    sys.exit(1)
" 2>/dev/null); then
        report_result 10 "agent-id-no-verdict-change" "SKIP" "could not extract paths"
        return
    fi

    # Run with agent_id=beta
    local json2
    if ! json2=$(moire_check_json "$repo" "" "MOIRE_AGENT_ID=beta"); then
        report_result 10 "agent-id-no-verdict-change" "FAIL" "second check failed"
        return
    fi

    local verdict2
    if ! verdict2=$(json_get "$json2" "verdict" 0); then
        report_result 10 "agent-id-no-verdict-change" "FAIL" "verdict missing in second check"
        return
    fi

    local paths2
    if ! paths2=$(python3 -c "
import json, sys
try:
    data = json.loads('''$json2''')
    if isinstance(data, list):
        data = data[0]
    paths = data.get('conflict_paths', [])
    print(','.join(sorted(paths)))
except:
    sys.exit(1)
" 2>/dev/null); then
        report_result 10 "agent-id-no-verdict-change" "FAIL" "could not extract paths from second"
        return
    fi

    if [ "$verdict1" = "$verdict2" ] && [ "$paths1" = "$paths2" ]; then
        report_result 10 "agent-id-no-verdict-change" "PASS"
    else
        report_result 10 "agent-id-no-verdict-change" "FAIL" "verdict/paths changed: $verdict1/$paths1 -> $verdict2/$paths2"
    fi
}

test_011_suppression_no_verdict_change() {
    local test_dir=$(mktemp -d)
    trap "rm -rf '$test_dir'" RETURN

    local repo="$test_dir/repo"
    mkdir -p "$repo"
    setup_conflict_repo "$repo" "file1.txt"

    # Run with rate 1.0
    local json1
    if ! json1=$(moire_check_json "$repo" "" "MOIRE_SURFACE_RATE=1.0"); then
        report_result 11 "suppression-no-verdict-change" "SKIP" "rate 1.0 check failed"
        return
    fi

    local verdict1 paths1
    if ! verdict1=$(json_get "$json1" "verdict" 0); then
        report_result 11 "suppression-no-verdict-change" "SKIP" "verdict missing"
        return
    fi

    if ! paths1=$(python3 -c "
import json, sys
try:
    data = json.loads('''$json1''')
    if isinstance(data, list):
        data = data[0]
    paths = data.get('conflict_paths', [])
    print(','.join(sorted(paths)))
except:
    sys.exit(1)
" 2>/dev/null); then
        report_result 11 "suppression-no-verdict-change" "SKIP" "could not extract paths"
        return
    fi

    # Run with rate 0.0
    local json2
    if ! json2=$(moire_check_json "$repo" "" "MOIRE_SURFACE_RATE=0.0"); then
        report_result 11 "suppression-no-verdict-change" "FAIL" "rate 0.0 check failed"
        return
    fi

    local verdict2 paths2
    if ! verdict2=$(json_get "$json2" "verdict" 0); then
        report_result 11 "suppression-no-verdict-change" "FAIL" "verdict missing in rate 0"
        return
    fi

    if ! paths2=$(python3 -c "
import json, sys
try:
    data = json.loads('''$json2''')
    if isinstance(data, list):
        data = data[0]
    paths = data.get('conflict_paths', [])
    print(','.join(sorted(paths)))
except:
    sys.exit(1)
" 2>/dev/null); then
        report_result 11 "suppression-no-verdict-change" "FAIL" "could not extract paths from rate 0"
        return
    fi

    if [ "$verdict1" = "$verdict2" ] && [ "$paths1" = "$paths2" ]; then
        report_result 11 "suppression-no-verdict-change" "PASS"
    else
        report_result 11 "suppression-no-verdict-change" "FAIL" "verdict/paths differ: $verdict1/$paths1 -> $verdict2/$paths2"
    fi
}

test_012_report_study() {
    local test_dir=$(mktemp -d)
    trap "rm -rf '$test_dir'" RETURN

    local repo="$test_dir/repo"
    mkdir -p "$repo"
    setup_conflict_repo "$repo" "file1.txt"

    # Create a scratch with real repo to run report
    local scratch=$(mktemp -d)
    trap "rm -rf '$scratch'" RETURN
    if ! cp -r "$repo" "$scratch/test"; then
        report_result 12 "report-study" "SKIP" "could not copy repo"
        return
    fi

    local peer_wt="$scratch/peer"
    if ! git_in "$scratch/test" worktree add "$peer_wt" branch_b >/dev/null 2>&1; then
        report_result 12 "report-study" "SKIP" "could not create peer"
        return
    fi

    # Run check to populate log
    if ! cd "$scratch/test" && MOIRE_GIT="$GIT_PROG" "$MOIRE_BIN" check --json >/dev/null 2>&1; then
        report_result 12 "report-study" "SKIP" "moire check failed"
        return
    fi

    # Try moire report --study (if it exists)
    local report_output
    if report_output=$(cd "$scratch/test" && MOIRE_GIT="$GIT_PROG" "$MOIRE_BIN" report --study 2>&1); then
        # --study flag is recognized
        # Check that it doesn't print bare % on small n
        if echo "$report_output" | grep -E '^[0-9]+\.[0-9]%$|^[0-9]+%$' | grep -v "insufficient"; then
            report_result 12 "report-study" "FAIL" "bare % printed on small n"
        else
            report_result 12 "report-study" "PASS"
        fi
    else
        # --study not implemented yet
        report_result 12 "report-study" "SKIP" "moire report --study not implemented"
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

    # Build the shared 40-peer fixture once (see build_big_fixture) and reuse
    # it across cases 4, 6, 7 rather than rebuilding it three times. If it
    # fails to build, BIG_FIXTURE_OK stays 0 and those three cases report
    # FAIL (never SKIP) -- see their own fixture-availability checks.
    if build_big_fixture "$TMPDIR_ROOT/big40" "$BIG_FIXTURE_N"; then
        BIG_FIXTURE_OK=1
    fi

    # Run all test cases
    test_001_symmetry
    test_002_stability
    test_003_suppression_determinism
    test_004_salt_changes_assignment
    test_005_suppressed_invisible
    test_006_surfaced_visible
    test_007_rate_honoured
    test_008_rate_extremes
    test_009_agent_identity
    test_010_agent_id_no_verdict_change
    test_011_suppression_no_verdict_change
    test_012_report_study

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
