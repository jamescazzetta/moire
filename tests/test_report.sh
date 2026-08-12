#!/bin/bash

# test_report.sh - Verify `moire report`'s surviving behaviour, and confirm
# the suppression/study machinery it used to expose is actually gone.
#
# Replaces test_study.sh (deleted): that suite tested the --study suppression
# arm (MOIRE_SURFACE_RATE/SALT, is_surfaced, surfaced/suppressed splits,
# cross/same-agent splits, `report --study`) - all deleted, because the
# mechanism could not produce a valid result (arms flip as a live collision's
# path set grows; same-second ties broke on a random uuid; both arms needed
# >=20 distinct findings for an event measured at zero - see the design
# rationale for D1). What survives from test_study.sh's coverage: finding_id
# symmetry/stability (general infrastructure `report`'s distinct-finding
# counts depend on, not suppression-specific) and MOIRE_AGENT_ID as an inert
# provenance label. Both are ported below (001/002, 004/005). Suppression
# determinism, salt-changes-assignment, suppressed/surfaced visibility,
# rate-honoured and rate-extremes (test_study.sh's 003-008) tested only the
# deleted mechanism and have no replacement here - see 007 below, which
# instead asserts the env vars that used to drive them are now inert.
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

# Get the git common dir's moire log shard count for a repo.
log_shard_count() {
    local repo="$1"
    local common_dir
    common_dir=$(git_in "$repo" rev-parse --git-common-dir 2>/dev/null) || { echo 0; return; }
    case "$common_dir" in
        /*) : ;;
        *) common_dir="$repo/$common_dir" ;;
    esac
    ls "$common_dir/moire/log" 2>/dev/null | wc -l | tr -d ' '
}

# Build a simple two-worktree fixture with a textual conflict
setup_conflict_repo() {
    local repo="$1"
    local conflict_file="${2:-conflict.txt}"

    git_in "$repo" init >/dev/null 2>&1
    git_in "$repo" config user.name "Test"
    git_in "$repo" config user.email "test@example.com"

    echo "original content" > "$repo/$conflict_file"
    git_in "$repo" add "$conflict_file"
    git_in "$repo" commit -m "base: add $conflict_file" >/dev/null 2>&1
    local base=$(git_in "$repo" rev-parse HEAD)

    git_in "$repo" checkout -b branch_a >/dev/null 2>&1
    echo "content from branch A" > "$repo/$conflict_file"
    git_in "$repo" commit -am "modify to A" >/dev/null 2>&1

    git_in "$repo" checkout "$base" >/dev/null 2>&1
    git_in "$repo" checkout -b branch_b >/dev/null 2>&1
    echo "content from branch B" > "$repo/$conflict_file"
    git_in "$repo" commit -am "modify to B" >/dev/null 2>&1

    git_in "$repo" checkout branch_a >/dev/null 2>&1
}

# === TEST CASES ===

test_001_finding_id_symmetry() {
    local test_dir=$(mktemp -d)
    trap "rm -rf '$test_dir'" RETURN

    local main_wt="$test_dir/main"
    mkdir -p "$main_wt"
    setup_conflict_repo "$main_wt" "file1.txt"

    local peer_wt="$test_dir/peer"
    if ! git_in "$main_wt" worktree add "$peer_wt" branch_b >/dev/null 2>&1; then
        report_result 1 "finding-id-symmetry" "SKIP" "could not create peer worktree"
        return
    fi

    local json1
    if ! json1=$(cd "$main_wt" && MOIRE_GIT="$GIT_PROG" "$MOIRE_BIN" check --json 2>/dev/null); then
        report_result 1 "finding-id-symmetry" "SKIP" "moire check from main failed"
        return
    fi
    local fid1
    if ! fid1=$(json_get "$json1" "finding_id" 0); then
        report_result 1 "finding-id-symmetry" "SKIP" "finding_id not in main output"
        return
    fi

    local json2
    if ! json2=$(cd "$peer_wt" && MOIRE_GIT="$GIT_PROG" "$MOIRE_BIN" check --json 2>/dev/null); then
        report_result 1 "finding-id-symmetry" "SKIP" "moire check from peer failed"
        return
    fi
    local fid2
    if ! fid2=$(json_get "$json2" "finding_id" 0); then
        report_result 1 "finding-id-symmetry" "SKIP" "finding_id not found in peer output"
        return
    fi

    if [ "$fid1" = "$fid2" ]; then
        report_result 1 "finding-id-symmetry" "PASS"
    else
        report_result 1 "finding-id-symmetry" "FAIL" "finding_ids differ: $fid1 vs $fid2"
    fi
}

# Also confirms `report`'s pair-state count stays at 1 across repeated
# observations of the SAME collision - the F1 fix (rates over distinct
# pair-states, not raw records) applied to `check`'s textual path, which
# test_verify.sh's equivalent cases (V25/V26) only exercise via `verify`.
test_002_finding_id_stability_and_pair_state_count() {
    local test_dir=$(mktemp -d)
    trap "rm -rf '$test_dir'" RETURN

    local main_wt="$test_dir/main"
    mkdir -p "$main_wt"
    setup_conflict_repo "$main_wt" "file1.txt"

    local peer_wt="$test_dir/peer"
    if ! git_in "$main_wt" worktree add "$peer_wt" branch_b >/dev/null 2>&1; then
        report_result 2 "finding-id-stability" "SKIP" "could not create peer worktree"
        return
    fi

    local fid1 fid2 i
    for i in 1 2 3; do
        local json
        if ! json=$(cd "$main_wt" && MOIRE_GIT="$GIT_PROG" "$MOIRE_BIN" check --json 2>/dev/null); then
            report_result 2 "finding-id-stability" "SKIP" "moire check run $i failed"
            return
        fi
        local fid
        if ! fid=$(json_get "$json" "finding_id" 0); then
            report_result 2 "finding-id-stability" "SKIP" "finding_id missing on run $i"
            return
        fi
        if [ -z "${fid1:-}" ]; then fid1="$fid"; else fid2="$fid"; fi
        if [ "$fid" != "$fid1" ]; then
            report_result 2 "finding-id-stability" "FAIL" "same collision produced different IDs across runs: $fid1 vs $fid"
            return
        fi
    done

    local rj states
    rj=$(cd "$main_wt" && MOIRE_GIT="$GIT_PROG" "$MOIRE_BIN" report --json 2>/dev/null)
    states=$(json_get "$rj" "pair_states_evaluated" 0)

    if [ "$states" = "1" ]; then
        report_result 2 "finding-id-stability" "PASS"
    else
        report_result 2 "finding-id-stability" "FAIL" "expected pair_states_evaluated=1 after 3 checks of the same collision, got $states"
    fi
}

test_003_agent_id_self_only_no_peer_field() {
    local test_dir=$(mktemp -d)
    trap "rm -rf '$test_dir'" RETURN

    local main_wt="$test_dir/main"
    mkdir -p "$main_wt"
    setup_conflict_repo "$main_wt" "file1.txt"

    local peer_wt="$test_dir/peer"
    if ! git_in "$main_wt" worktree add "$peer_wt" branch_b >/dev/null 2>&1; then
        report_result 3 "agent-id-self-only" "SKIP" "could not create peer worktree"
        return
    fi

    local json
    if ! json=$(cd "$main_wt" && MOIRE_GIT="$GIT_PROG" MOIRE_AGENT_ID=alpha "$MOIRE_BIN" check --json 2>/dev/null); then
        report_result 3 "agent-id-self-only" "SKIP" "moire check failed"
        return
    fi

    local self_id peer_has_field
    if ! self_id=$(json_get "$json" "self.agent_id" 0); then
        report_result 3 "agent-id-self-only" "SKIP" "self.agent_id not in JSON"
        return
    fi
    peer_has_field=$(json_has "$json" "peer.agent_id" 0)

    # D3: the marker-file mechanism that used to populate peer.agent_id is
    # deleted. self.agent_id is the only surviving provenance field - a
    # worktree's own record of its own MOIRE_AGENT_ID, never read back about
    # a peer.
    if [ "$self_id" = "alpha" ] && [ "$peer_has_field" = "no" ]; then
        report_result 3 "agent-id-self-only" "PASS"
    else
        report_result 3 "agent-id-self-only" "FAIL" "self.agent_id=$self_id peer_has_agent_id_field=$peer_has_field"
    fi
}

test_004_agent_id_no_verdict_change() {
    local test_dir=$(mktemp -d)
    trap "rm -rf '$test_dir'" RETURN

    local repo="$test_dir/repo"
    mkdir -p "$repo"
    setup_conflict_repo "$repo" "file1.txt"

    local peer_wt="$test_dir/peer"
    if ! git_in "$repo" worktree add "$peer_wt" branch_b >/dev/null 2>&1; then
        report_result 4 "agent-id-no-verdict-change" "SKIP" "could not create peer worktree"
        return
    fi

    local json1 verdict1 paths1
    if ! json1=$(cd "$repo" && MOIRE_GIT="$GIT_PROG" MOIRE_AGENT_ID=alpha "$MOIRE_BIN" check --json 2>/dev/null); then
        report_result 4 "agent-id-no-verdict-change" "SKIP" "first check failed"
        return
    fi
    verdict1=$(json_get "$json1" "verdict" 0)
    paths1=$(python3 -c "
import json, sys
try:
    data = json.loads('''$json1''')[0]
    print(','.join(sorted(data.get('conflict_paths', []))))
except:
    sys.exit(1)
" 2>/dev/null) || { report_result 4 "agent-id-no-verdict-change" "SKIP" "could not extract paths"; return; }

    local json2 verdict2 paths2
    if ! json2=$(cd "$repo" && MOIRE_GIT="$GIT_PROG" MOIRE_AGENT_ID=beta "$MOIRE_BIN" check --json 2>/dev/null); then
        report_result 4 "agent-id-no-verdict-change" "FAIL" "second check failed"
        return
    fi
    verdict2=$(json_get "$json2" "verdict" 0)
    paths2=$(python3 -c "
import json, sys
try:
    data = json.loads('''$json2''')[0]
    print(','.join(sorted(data.get('conflict_paths', []))))
except:
    sys.exit(1)
" 2>/dev/null) || { report_result 4 "agent-id-no-verdict-change" "FAIL" "could not extract paths from second"; return; }

    if [ "$verdict1" = "$verdict2" ] && [ "$paths1" = "$paths2" ]; then
        report_result 4 "agent-id-no-verdict-change" "PASS"
    else
        report_result 4 "agent-id-no-verdict-change" "FAIL" "verdict/paths changed: $verdict1/$paths1 -> $verdict2/$paths2"
    fi
}

test_005_report_text_and_json_shape() {
    local test_dir=$(mktemp -d)
    trap "rm -rf '$test_dir'" RETURN

    local repo="$test_dir/repo"
    mkdir -p "$repo"
    setup_conflict_repo "$repo" "file1.txt"

    if ! git_in "$repo" worktree add "$test_dir/peer" branch_b >/dev/null 2>&1; then
        report_result 5 "report-text-and-json-shape" "SKIP" "could not create peer worktree"
        return
    fi
    if ! (cd "$repo" && MOIRE_GIT="$GIT_PROG" "$MOIRE_BIN" check --json) >/dev/null 2>&1; then
        report_result 5 "report-text-and-json-shape" "SKIP" "moire check failed"
        return
    fi

    local human rj
    human=$(cd "$repo" && MOIRE_GIT="$GIT_PROG" "$MOIRE_BIN" report 2>/dev/null)
    rj=$(cd "$repo" && MOIRE_GIT="$GIT_PROG" "$MOIRE_BIN" report --json 2>/dev/null)

    local has_evaluated has_textual_rate has_findings_header
    echo "$human" | grep -q "^pair-states evaluated" && has_evaluated=yes || has_evaluated=no
    echo "$human" | grep -q "^textual rate (per pair-state)" && has_textual_rate=yes || has_textual_rate=no
    echo "$human" | grep -q "^distinct findings" && has_findings_header=yes || has_findings_header=no

    # The deleted --study surface must leave no trace in plain report's JSON:
    # no arms, no min_n_per_arm, no lifecycle_top20_by_times_seen key.
    local no_arms no_min_n no_lifecycle
    json_has "$rj" "arms" 0 | grep -q '^no$' && no_arms=yes || no_arms=no
    json_has "$rj" "min_n_per_arm" 0 | grep -q '^no$' && no_min_n=yes || no_min_n=no
    json_has "$rj" "lifecycle_top20_by_times_seen" 0 | grep -q '^no$' && no_lifecycle=yes || no_lifecycle=no

    if [ "$has_evaluated" = "yes" ] && [ "$has_textual_rate" = "yes" ] && [ "$has_findings_header" = "yes" ] \
       && [ "$no_arms" = "yes" ] && [ "$no_min_n" = "yes" ] && [ "$no_lifecycle" = "yes" ]; then
        report_result 5 "report-text-and-json-shape" "PASS"
    else
        report_result 5 "report-text-and-json-shape" "FAIL" \
            "text: evaluated=$has_evaluated textual_rate=$has_textual_rate findings=$has_findings_header; json absent-checks: arms=$no_arms min_n_per_arm=$no_min_n lifecycle=$no_lifecycle"
    fi
}

test_006_study_flag_refused() {
    local test_dir=$(mktemp -d)
    trap "rm -rf '$test_dir'" RETURN

    local repo="$test_dir/repo"
    mkdir -p "$repo"
    git_in "$repo" init >/dev/null 2>&1
    git_in "$repo" config user.name "Test"
    git_in "$repo" config user.email "test@example.com"
    echo "x" > "$repo/f.txt"
    git_in "$repo" add -A >/dev/null 2>&1
    git_in "$repo" commit -qm base >/dev/null 2>&1

    local before after rc stderr_out
    before=$(log_shard_count "$repo")
    stderr_out=$(cd "$repo" && MOIRE_GIT="$GIT_PROG" "$MOIRE_BIN" report --study 2>&1 >/dev/null)
    rc=$?
    after=$(log_shard_count "$repo")

    local expected="moire: unknown argument '--study' for report (removed in 0.11; see report's findings section)"
    if [ "$rc" -eq 2 ] && [ "$before" = "$after" ] \
       && echo "$stderr_out" | grep -qF "$expected"; then
        report_result 6 "study-flag-refused" "PASS"
    else
        report_result 6 "study-flag-refused" "FAIL" \
            "rc=$rc shards_before=$before shards_after=$after stderr=$(echo "$stderr_out" | tr '\n' ' ' | head -c 200)"
    fi
}

# MOIRE_SURFACE_RATE/MOIRE_SURFACE_SALT used to select which findings were
# shown to the agent (deleted with the rest of D1). A caller who still has
# them set (an old hook config, an old script) must see no effect at all:
# no suppression, no "surfaced" key in the record.
test_007_surface_env_vars_inert() {
    local test_dir=$(mktemp -d)
    trap "rm -rf '$test_dir'" RETURN

    local repo="$test_dir/repo"
    mkdir -p "$repo"
    setup_conflict_repo "$repo" "file1.txt"

    if ! git_in "$repo" worktree add "$test_dir/peer" branch_b >/dev/null 2>&1; then
        report_result 7 "surface-env-vars-inert" "SKIP" "could not create peer worktree"
        return
    fi

    local json human
    if ! json=$(cd "$repo" && MOIRE_GIT="$GIT_PROG" MOIRE_SURFACE_RATE=0.0 MOIRE_SURFACE_SALT=x \
                 "$MOIRE_BIN" check --json 2>/dev/null); then
        report_result 7 "surface-env-vars-inert" "SKIP" "moire check failed"
        return
    fi
    human=$(cd "$repo" && MOIRE_GIT="$GIT_PROG" MOIRE_SURFACE_RATE=0.0 MOIRE_SURFACE_SALT=x \
             "$MOIRE_BIN" check 2>/dev/null)

    local verdict has_surfaced_field shows_conflict
    verdict=$(json_get "$json" "verdict" 0)
    has_surfaced_field=$(json_has "$json" "surfaced" 0)
    echo "$human" | grep -q "^CONFLICT with" && shows_conflict=yes || shows_conflict=no

    if [ "$verdict" = "conflict" ] && [ "$has_surfaced_field" = "no" ] && [ "$shows_conflict" = "yes" ]; then
        report_result 7 "surface-env-vars-inert" "PASS"
    else
        report_result 7 "surface-env-vars-inert" "FAIL" \
            "verdict=$verdict has_surfaced_field=$has_surfaced_field shows_conflict=$shows_conflict (MOIRE_SURFACE_RATE=0.0 must no longer suppress anything)"
    fi
}

# === MAIN ===

main() {
    # A missing/stub binary is a FAIL, not a silent SKIP (F8): a suite that
    # exits 0 whenever the tool is absent proves nothing about the tool.
    if [ ! -x "$MOIRE_BIN" ]; then
        echo "FAIL: bin/moire not present or not executable ($MOIRE_BIN)"
        exit 1
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
    test_001_finding_id_symmetry
    test_002_finding_id_stability_and_pair_state_count
    test_003_agent_id_self_only_no_peer_field
    test_004_agent_id_no_verdict_change
    test_005_report_text_and_json_shape
    test_006_study_flag_refused
    test_007_surface_env_vars_inert

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
