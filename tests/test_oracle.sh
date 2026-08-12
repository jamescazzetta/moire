#!/bin/bash

# test_oracle.sh - Verify moire conflict detection matches real git merge behavior
# Builds git fixtures and asserts conflict detection against ground truth

set -u

# Resolve paths relative to this script's own location, not the caller's cwd,
# so the suite runs the same from any working directory.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

# Global state
TMPDIR_ROOT=""
GIT_PROG=""
MOIRE_BIN="${MOIRE_BIN:-$REPO_ROOT/bin/moire}"
PASSED=0
FAILED=0
SKIPPED=0

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

# Compute ground truth using git merge
compute_ground_truth() {
    local repo="$1"
    local scratch

    scratch=$(mktemp -d)
    trap "rm -rf '$scratch'" RETURN

    cp -r "$repo" "$scratch/test" || return 1

    # Checkout branch_a (should already be checked out)
    git_in "$scratch/test" checkout branch_a >/dev/null 2>&1 || return 1

    # Try to merge branch_b
    if git_in "$scratch/test" merge --no-commit --no-ff branch_b >/dev/null 2>&1; then
        # Merge succeeded without automatic conflict resolution
        # Check for unmerged paths (conflict markers)
        local unmerged
        unmerged=$(git_in "$scratch/test" diff --name-only --diff-filter=U 2>/dev/null | wc -l)

        # Also check status for conflict states
        local conflict_states
        conflict_states=$(git_in "$scratch/test" status --porcelain 2>/dev/null | grep -cE '^(DD|AU|UD|UA|DU|AA|UU)' || true)

        git_in "$scratch/test" merge --abort 2>/dev/null || true

        if [ "$unmerged" -gt 0 ] || [ "$conflict_states" -gt 0 ]; then
            echo "conflict"
        else
            echo "clean"
        fi
    else
        # Merge command failed - there are conflicts
        git_in "$scratch/test" merge --abort 2>/dev/null || true
        echo "conflict"
    fi
}

# Query moire for conflict verdict (requires JSON parsing).
#
# `moire check` compares the *current* worktree against peer worktrees discovered
# via `git worktree list` -- it never compares
# arbitrary local branches. Our fixtures leave branch_b as a plain branch ref,
# so we must materialize it as a real linked worktree before invoking moire, or
# moire would see zero peers and every verdict would be meaningless by construction.
moire_check() {
    local repo="$1"
    local scratch peer_dir output verdict

    scratch=$(mktemp -d)
    trap "rm -rf '$scratch'" RETURN

    if ! cp -r "$repo" "$scratch/test"; then
        echo "error"
        return 1
    fi

    peer_dir="$scratch/peer"
    if ! git_in "$scratch/test" worktree add "$peer_dir" branch_b >/dev/null 2>&1; then
        echo "error"
        return 1
    fi

    # Pin moire to the same validated git the rest of this suite uses (MOIRE_GIT is
    # exclusive in moire: an unset/older git on PATH must not silently substitute).
    if ! output=$(cd "$scratch/test" && MOIRE_GIT="$GIT_PROG" "$MOIRE_BIN" check --json 2>/dev/null); then
        echo "error"
        return 1
    fi

    # Parse JSON and pick out the record for our specific peer worktree by
    # realpath, rather than assuming record order/count.
    verdict=$(MOIRE_PEER_DIR="$peer_dir" python3 -c '
import json, os, sys
try:
    records = json.load(sys.stdin)
except Exception:
    sys.exit(1)
peer_dir = os.path.realpath(os.environ["MOIRE_PEER_DIR"])
for r in records:
    peer = (r.get("peer") or {}).get("worktree")
    if peer and os.path.realpath(peer) == peer_dir:
        sys.stdout.write(r.get("verdict") or "")
        sys.exit(0)
sys.exit(1)
' <<<"$output" 2>/dev/null)

    if [ -z "$verdict" ]; then
        echo "error"
        return 1
    fi
    echo "$verdict"
}

# Report test result
report_result() {
    local num="$1" name="$2" expected="$3" moire_verdict="$4" ground_truth="$5"
    local status verdict_str

    # Determine status based on ground truth matching expected
    if [ "$ground_truth" = "$expected" ]; then
        if [ -x "$MOIRE_BIN" ] && [ "$moire_verdict" != "$expected" ]; then
            status="FAIL"
            ((FAILED++))
        else
            status="PASS"
            ((PASSED++))
        fi
    else
        status="FAIL"
        ((FAILED++))
    fi

    echo "$status $num $name expected=$expected actual=$moire_verdict ground_truth=$ground_truth"
}

# === FIXTURE BUILDERS ===

fixture_1() {
    # Case 1: rename/rename to divergent targets
    local repo="$1"
    git_in "$repo" init >/dev/null 2>&1
    git_in "$repo" config user.name "Test"
    git_in "$repo" config user.email "test@example.com"

    # Base: create f.txt
    echo "original content" > "$repo/f.txt"
    git_in "$repo" add f.txt
    git_in "$repo" commit -m "base: add f.txt" >/dev/null 2>&1
    local base=$(git_in "$repo" rev-parse HEAD)

    # Branch A: rename f.txt to a.txt
    git_in "$repo" checkout -b branch_a >/dev/null 2>&1
    git_in "$repo" mv f.txt a.txt
    git_in "$repo" commit -m "rename to a.txt" >/dev/null 2>&1

    # Branch B: rename f.txt to b.txt
    git_in "$repo" checkout "$base" >/dev/null 2>&1
    git_in "$repo" checkout -b branch_b >/dev/null 2>&1
    git_in "$repo" mv f.txt b.txt
    git_in "$repo" commit -m "rename to b.txt" >/dev/null 2>&1

    # Return to branch_a for testing
    git_in "$repo" checkout branch_a >/dev/null 2>&1
}

fixture_2() {
    # Case 2: modify vs delete
    local repo="$1"
    git_in "$repo" init >/dev/null 2>&1
    git_in "$repo" config user.name "Test"
    git_in "$repo" config user.email "test@example.com"

    # Base: create f.txt
    echo "original content" > "$repo/f.txt"
    git_in "$repo" add f.txt
    git_in "$repo" commit -m "base: add f.txt" >/dev/null 2>&1
    local base=$(git_in "$repo" rev-parse HEAD)

    # Branch A: modify f.txt
    git_in "$repo" checkout -b branch_a >/dev/null 2>&1
    echo "modified content" > "$repo/f.txt"
    git_in "$repo" commit -am "modify f.txt" >/dev/null 2>&1

    # Branch B: delete f.txt
    git_in "$repo" checkout "$base" >/dev/null 2>&1
    git_in "$repo" checkout -b branch_b >/dev/null 2>&1
    git_in "$repo" rm f.txt >/dev/null 2>&1
    git_in "$repo" commit -m "delete f.txt" >/dev/null 2>&1

    # Return to branch_a
    git_in "$repo" checkout branch_a >/dev/null 2>&1
}

fixture_3() {
    # Case 3: binary file modified on both sides
    local repo="$1"
    git_in "$repo" init >/dev/null 2>&1
    git_in "$repo" config user.name "Test"
    git_in "$repo" config user.email "test@example.com"

    # Base: create binary file
    printf '\x89PNG\x0d\x0a\x1a\x0a\x00\x00\x00\x0d' > "$repo/image.bin"
    git_in "$repo" add image.bin
    git_in "$repo" commit -m "base: add binary" >/dev/null 2>&1
    local base=$(git_in "$repo" rev-parse HEAD)

    # Branch A: modify binary
    git_in "$repo" checkout -b branch_a >/dev/null 2>&1
    printf '\x89PNG\x0d\x0a\x1a\x0a\x00\x00\x00\x0eAA' > "$repo/image.bin"
    git_in "$repo" commit -am "modify binary A" >/dev/null 2>&1

    # Branch B: modify binary differently
    git_in "$repo" checkout "$base" >/dev/null 2>&1
    git_in "$repo" checkout -b branch_b >/dev/null 2>&1
    printf '\x89PNG\x0d\x0a\x1a\x0a\x00\x00\x00\x0eBB' > "$repo/image.bin"
    git_in "$repo" commit -am "modify binary B" >/dev/null 2>&1

    # Return to branch_a
    git_in "$repo" checkout branch_a >/dev/null 2>&1
}

fixture_4() {
    # Case 4: rename vs edit (clean - rename is preserved)
    local repo="$1"
    git_in "$repo" init >/dev/null 2>&1
    git_in "$repo" config user.name "Test"
    git_in "$repo" config user.email "test@example.com"

    # Base: create f.txt
    echo "line1" > "$repo/f.txt"
    echo "line2" >> "$repo/f.txt"
    git_in "$repo" add f.txt
    git_in "$repo" commit -m "base: add f.txt" >/dev/null 2>&1
    local base=$(git_in "$repo" rev-parse HEAD)

    # Branch A: rename f.txt to renamed.txt
    git_in "$repo" checkout -b branch_a >/dev/null 2>&1
    git_in "$repo" mv f.txt renamed.txt
    git_in "$repo" commit -m "rename to renamed.txt" >/dev/null 2>&1

    # Branch B: edit f.txt
    git_in "$repo" checkout "$base" >/dev/null 2>&1
    git_in "$repo" checkout -b branch_b >/dev/null 2>&1
    echo "modified line1" > "$repo/f.txt"
    echo "line2" >> "$repo/f.txt"
    git_in "$repo" commit -am "edit f.txt" >/dev/null 2>&1

    # Return to branch_a
    git_in "$repo" checkout branch_a >/dev/null 2>&1
}

fixture_5() {
    # Case 5: same line edited differently on both sides (conflict)
    local repo="$1"
    git_in "$repo" init >/dev/null 2>&1
    git_in "$repo" config user.name "Test"
    git_in "$repo" config user.email "test@example.com"

    # Base: create f.txt
    echo "line1: base" > "$repo/f.txt"
    echo "line2: unchanged" >> "$repo/f.txt"
    git_in "$repo" add f.txt
    git_in "$repo" commit -m "base: add f.txt" >/dev/null 2>&1
    local base=$(git_in "$repo" rev-parse HEAD)

    # Branch A: edit line1 to "A"
    git_in "$repo" checkout -b branch_a >/dev/null 2>&1
    echo "line1: A version" > "$repo/f.txt"
    echo "line2: unchanged" >> "$repo/f.txt"
    git_in "$repo" commit -am "edit to A version" >/dev/null 2>&1

    # Branch B: edit line1 to "B"
    git_in "$repo" checkout "$base" >/dev/null 2>&1
    git_in "$repo" checkout -b branch_b >/dev/null 2>&1
    echo "line1: B version" > "$repo/f.txt"
    echo "line2: unchanged" >> "$repo/f.txt"
    git_in "$repo" commit -am "edit to B version" >/dev/null 2>&1

    # Return to branch_a
    git_in "$repo" checkout branch_a >/dev/null 2>&1
}

fixture_6() {
    # Case 6: edits to entirely different files (clean)
    local repo="$1"
    git_in "$repo" init >/dev/null 2>&1
    git_in "$repo" config user.name "Test"
    git_in "$repo" config user.email "test@example.com"

    # Base: create two files
    echo "a_content" > "$repo/file_a.txt"
    echo "b_content" > "$repo/file_b.txt"
    git_in "$repo" add file_a.txt file_b.txt
    git_in "$repo" commit -m "base: add files" >/dev/null 2>&1
    local base=$(git_in "$repo" rev-parse HEAD)

    # Branch A: edit file_a.txt
    git_in "$repo" checkout -b branch_a >/dev/null 2>&1
    echo "a_modified" > "$repo/file_a.txt"
    git_in "$repo" commit -am "edit file_a" >/dev/null 2>&1

    # Branch B: edit file_b.txt
    git_in "$repo" checkout "$base" >/dev/null 2>&1
    git_in "$repo" checkout -b branch_b >/dev/null 2>&1
    echo "b_modified" > "$repo/file_b.txt"
    git_in "$repo" commit -am "edit file_b" >/dev/null 2>&1

    # Return to branch_a
    git_in "$repo" checkout branch_a >/dev/null 2>&1
}

fixture_7() {
    # Case 7: edits 1 unchanged line apart in same file (clean)
    local repo="$1"
    git_in "$repo" init >/dev/null 2>&1
    git_in "$repo" config user.name "Test"
    git_in "$repo" config user.email "test@example.com"

    # Base: create f.txt with multiple lines
    echo "line1: base" > "$repo/f.txt"
    echo "line2: unchanged" >> "$repo/f.txt"
    echo "line3: base" >> "$repo/f.txt"
    git_in "$repo" add f.txt
    git_in "$repo" commit -m "base: add f.txt" >/dev/null 2>&1
    local base=$(git_in "$repo" rev-parse HEAD)

    # Branch A: edit line1
    git_in "$repo" checkout -b branch_a >/dev/null 2>&1
    echo "line1: A version" > "$repo/f.txt"
    echo "line2: unchanged" >> "$repo/f.txt"
    echo "line3: base" >> "$repo/f.txt"
    git_in "$repo" commit -am "edit line1" >/dev/null 2>&1

    # Branch B: edit line3 (1 line away)
    git_in "$repo" checkout "$base" >/dev/null 2>&1
    git_in "$repo" checkout -b branch_b >/dev/null 2>&1
    echo "line1: base" > "$repo/f.txt"
    echo "line2: unchanged" >> "$repo/f.txt"
    echo "line3: B version" >> "$repo/f.txt"
    git_in "$repo" commit -am "edit line3" >/dev/null 2>&1

    # Return to branch_a
    git_in "$repo" checkout branch_a >/dev/null 2>&1
}

fixture_8() {
    # Case 8: identical edit made on both sides (clean)
    local repo="$1"
    git_in "$repo" init >/dev/null 2>&1
    git_in "$repo" config user.name "Test"
    git_in "$repo" config user.email "test@example.com"

    # Base: create f.txt
    echo "line1: base" > "$repo/f.txt"
    echo "line2: base" >> "$repo/f.txt"
    git_in "$repo" add f.txt
    git_in "$repo" commit -m "base: add f.txt" >/dev/null 2>&1
    local base=$(git_in "$repo" rev-parse HEAD)

    # Branch A: make identical edit
    git_in "$repo" checkout -b branch_a >/dev/null 2>&1
    echo "line1: identical" > "$repo/f.txt"
    echo "line2: base" >> "$repo/f.txt"
    git_in "$repo" commit -am "identical edit" >/dev/null 2>&1

    # Branch B: make identical edit
    git_in "$repo" checkout "$base" >/dev/null 2>&1
    git_in "$repo" checkout -b branch_b >/dev/null 2>&1
    echo "line1: identical" > "$repo/f.txt"
    echo "line2: base" >> "$repo/f.txt"
    git_in "$repo" commit -am "identical edit" >/dev/null 2>&1

    # Return to branch_a
    git_in "$repo" checkout branch_a >/dev/null 2>&1
}

fixture_9() {
    # Case 9: both sides delete the same file (clean)
    local repo="$1"
    git_in "$repo" init >/dev/null 2>&1
    git_in "$repo" config user.name "Test"
    git_in "$repo" config user.email "test@example.com"

    # Base: create f.txt
    echo "content" > "$repo/f.txt"
    git_in "$repo" add f.txt
    git_in "$repo" commit -m "base: add f.txt" >/dev/null 2>&1
    local base=$(git_in "$repo" rev-parse HEAD)

    # Branch A: delete f.txt
    git_in "$repo" checkout -b branch_a >/dev/null 2>&1
    git_in "$repo" rm f.txt >/dev/null 2>&1
    git_in "$repo" commit -m "delete f.txt" >/dev/null 2>&1

    # Branch B: delete f.txt
    git_in "$repo" checkout "$base" >/dev/null 2>&1
    git_in "$repo" checkout -b branch_b >/dev/null 2>&1
    git_in "$repo" rm f.txt >/dev/null 2>&1
    git_in "$repo" commit -m "delete f.txt" >/dev/null 2>&1

    # Return to branch_a
    git_in "$repo" checkout branch_a >/dev/null 2>&1
}

fixture_10() {
    # Case 10: both add same new path, different content (conflict)
    local repo="$1"
    git_in "$repo" init >/dev/null 2>&1
    git_in "$repo" config user.name "Test"
    git_in "$repo" config user.email "test@example.com"

    # Base: create dummy file
    echo "base" > "$repo/dummy.txt"
    git_in "$repo" add dummy.txt
    git_in "$repo" commit -m "base: add dummy" >/dev/null 2>&1
    local base=$(git_in "$repo" rev-parse HEAD)

    # Branch A: add new.txt with A content
    git_in "$repo" checkout -b branch_a >/dev/null 2>&1
    echo "A version" > "$repo/new.txt"
    git_in "$repo" add new.txt
    git_in "$repo" commit -m "add new.txt (A)" >/dev/null 2>&1

    # Branch B: add new.txt with B content
    git_in "$repo" checkout "$base" >/dev/null 2>&1
    git_in "$repo" checkout -b branch_b >/dev/null 2>&1
    echo "B version" > "$repo/new.txt"
    git_in "$repo" add new.txt
    git_in "$repo" commit -m "add new.txt (B)" >/dev/null 2>&1

    # Return to branch_a
    git_in "$repo" checkout branch_a >/dev/null 2>&1
}

fixture_11() {
    # Case 11: both add same new path, identical content (clean)
    local repo="$1"
    git_in "$repo" init >/dev/null 2>&1
    git_in "$repo" config user.name "Test"
    git_in "$repo" config user.email "test@example.com"

    # Base: create dummy file
    echo "base" > "$repo/dummy.txt"
    git_in "$repo" add dummy.txt
    git_in "$repo" commit -m "base: add dummy" >/dev/null 2>&1
    local base=$(git_in "$repo" rev-parse HEAD)

    # Branch A: add new.txt
    git_in "$repo" checkout -b branch_a >/dev/null 2>&1
    echo "identical content" > "$repo/new.txt"
    git_in "$repo" add new.txt
    git_in "$repo" commit -m "add new.txt" >/dev/null 2>&1

    # Branch B: add new.txt with same content
    git_in "$repo" checkout "$base" >/dev/null 2>&1
    git_in "$repo" checkout -b branch_b >/dev/null 2>&1
    echo "identical content" > "$repo/new.txt"
    git_in "$repo" add new.txt
    git_in "$repo" commit -m "add new.txt" >/dev/null 2>&1

    # Return to branch_a
    git_in "$repo" checkout branch_a >/dev/null 2>&1
}

fixture_12() {
    # Case 12: marker injection - A writes conflict markers, B edits unrelated file (clean)
    local repo="$1"
    git_in "$repo" init >/dev/null 2>&1
    git_in "$repo" config user.name "Test"
    git_in "$repo" config user.email "test@example.com"

    # Base: create two files
    echo "original_a" > "$repo/f.txt"
    echo "original_b" > "$repo/g.txt"
    git_in "$repo" add f.txt g.txt
    git_in "$repo" commit -m "base: add files" >/dev/null 2>&1
    local base=$(git_in "$repo" rev-parse HEAD)

    # Branch A: write literal conflict markers to f.txt
    git_in "$repo" checkout -b branch_a >/dev/null 2>&1
    cat > "$repo/f.txt" << 'EOF'
line before
<<<<<<<
=======
>>>>>>>
line after
EOF
    git_in "$repo" commit -am "write markers" >/dev/null 2>&1

    # Branch B: edit unrelated file g.txt
    git_in "$repo" checkout "$base" >/dev/null 2>&1
    git_in "$repo" checkout -b branch_b >/dev/null 2>&1
    echo "modified_b" > "$repo/g.txt"
    git_in "$repo" commit -am "edit g.txt" >/dev/null 2>&1

    # Return to branch_a
    git_in "$repo" checkout branch_a >/dev/null 2>&1
}

# === TEST RUNNER ===

test_case() {
    local num="$1" name="$2" expected="$3"
    local fixture_fn="fixture_$num"
    local repo test_dir ground_truth moire_verdict

    # Create test repo
    test_dir=$(mktemp -d)
    repo="$test_dir/repo"
    mkdir -p "$repo"

    # Build fixture
    if ! ($fixture_fn "$repo" 2>/dev/null); then
        report_result "$num" "$name" "$expected" "N/A" "fixture_error"
        rm -rf "$test_dir"
        return 1
    fi

    # Compute ground truth
    ground_truth=$(compute_ground_truth "$repo")

    # Check with moire (if available)
    moire_verdict="N/A"
    if [ -x "$MOIRE_BIN" ]; then
        moire_verdict=$(moire_check "$repo") || moire_verdict="error"
    fi

    # Report result
    report_result "$num" "$name" "$expected" "$moire_verdict" "$ground_truth"

    rm -rf "$test_dir"
}

# === MAIN ===

main() {
    # A missing/stub binary is a FAIL, not a silent SKIP: a suite that exits 0
    # whenever the tool is absent proves nothing about the tool. See
    # tests/negative_control.sh, which stubs MOIRE_BIN and asserts this.
    if [ ! -x "$MOIRE_BIN" ]; then
        echo "FAIL: bin/moire not present or not executable ($MOIRE_BIN)"
        exit 1
    fi

    # Find suitable git
    GIT_PROG=$(find_git) || {
        echo "SKIP: git >= 2.38 required"
        exit 0
    }

    # Setup environment
    setup_git_env
    TMPDIR_ROOT=$(mktemp -d)

    # Run all test cases
    test_case 1 "rename/rename" "conflict"
    test_case 2 "modify vs delete" "conflict"
    test_case 3 "binary modified both" "conflict"
    test_case 4 "rename vs edit" "clean"
    test_case 5 "same line different edits" "conflict"
    test_case 6 "different files" "clean"
    test_case 7 "1 line apart" "clean"
    test_case 8 "identical edit" "clean"
    test_case 9 "both delete" "clean"
    test_case 10 "both add different" "conflict"
    test_case 11 "both add identical" "clean"
    test_case 12 "marker injection" "clean"

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
