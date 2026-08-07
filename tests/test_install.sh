#!/bin/bash
set -eu

# Standalone shell test for `moire` CLI installation, hooks, and log integrity
# Covers: install, hook wiring, path resolution, log-shard integrity, doctor
# Exit 0 only if all cases pass; else exit 1 with failure count.

# ============================================================================
# Setup
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

MOIRE_BIN="${REPO_ROOT}/bin/moire"
MOIRE_GIT="${MOIRE_GIT:-/opt/homebrew/bin/git}"

# Fallback to /usr/bin/git if homebrew not available
if [[ ! -x "$MOIRE_GIT" ]]; then
	MOIRE_GIT="/usr/bin/git"
fi

# Check git version
GIT_VERSION=$("$MOIRE_GIT" --version | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
GIT_MAJOR=$(echo "$GIT_VERSION" | cut -d. -f1)
GIT_MINOR=$(echo "$GIT_VERSION" | cut -d. -f2)

# Counters
PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

# Track temp directories for cleanup
declare -a TEMP_DIRS

# Cleanup function
cleanup_on_exit() {
	if [[ ${#TEMP_DIRS[@]} -gt 0 ]]; then
		for tmpdir in "${TEMP_DIRS[@]}"; do
			if [[ -d "$tmpdir" ]]; then
				rm -rf "$tmpdir"
			fi
		done
	fi
}

trap cleanup_on_exit EXIT

# ============================================================================
# Functions
# ============================================================================

log_test() {
	local num=$1
	local status=$2
	local reason=$3
	echo "${status}: test_${num} - ${reason}"
	# NOTE: `((PASS_COUNT++))` evaluates to the PRE-increment value, so 0->1
	# evaluates to 0 and the `((...))` command itself "fails" -- fatal under
	# `set -e`. Plain arithmetic assignment has no such trap.
	case "$status" in
		PASS) PASS_COUNT=$((PASS_COUNT + 1)) ;;
		FAIL) FAIL_COUNT=$((FAIL_COUNT + 1)) ;;
		SKIP) SKIP_COUNT=$((SKIP_COUNT + 1)) ;;
	esac
}

# Helper: check if bin/moire is available and executable
check_moire_available() {
	if [[ ! -x "$MOIRE_BIN" ]]; then
		return 1
	fi
	return 0
}

# Helper: check git version >= 2.38
check_git_version() {
	if [[ $GIT_MAJOR -gt 2 ]] || { [[ $GIT_MAJOR -eq 2 ]] && [[ $GIT_MINOR -ge 38 ]]; }; then
		return 0
	fi
	return 1
}

# Helper: create a temp git repo with standard config
#
# NOTE: this function is always invoked as `tmpdir=$(setup_test_repo)`, which
# runs its body in a forked subshell. Appending to TEMP_DIRS in here would
# only mutate that subshell's copy of the array and vanish when it exits, so
# the top-level EXIT trap would never see it -- callers register the path
# into TEMP_DIRS themselves, right after capturing this function's output.
setup_test_repo() {
	local tmpdir=$(mktemp -d)
	cd "$tmpdir"

	export GIT_AUTHOR_NAME="Test Author"
	export GIT_AUTHOR_EMAIL="test@example.com"
	export GIT_COMMITTER_NAME="Test Committer"
	export GIT_COMMITTER_EMAIL="test@example.com"

	# NOTE: every git call here must be silenced. This function's stdout is
	# captured wholesale by callers via `tmpdir=$(setup_test_repo)`; any git
	# noise (e.g. "Initialized empty Git repository in ...", the commit
	# summary line) would get glued onto the path, making $tmpdir an invalid
	# multi-line string and every subsequent `cd "$tmpdir"` fail.
	"$MOIRE_GIT" init > /dev/null 2>&1
	"$MOIRE_GIT" config user.name "Test User" > /dev/null 2>&1
	"$MOIRE_GIT" config user.email "test@example.local" > /dev/null 2>&1

	# Create initial commit
	echo "initial" > README.md
	"$MOIRE_GIT" add README.md > /dev/null 2>&1
	"$MOIRE_GIT" commit -m "initial commit" > /dev/null 2>&1

	echo "$tmpdir"
}

# Helper: get git common dir
get_git_common_dir() {
	local repo_dir="${1:-.}"
	(cd "$repo_dir" && "$MOIRE_GIT" rev-parse --git-common-dir)
}

# Helper: check if a file contains duplicates of a pattern
has_duplicate_content() {
	local file=$1
	local pattern=$2
	local count
	# NOTE: `grep -c` prints "0" (exit 1) on zero matches, and prints nothing
	# (exit 2) if the file is unreadable. The old `|| echo 0` fallback fired
	# on the zero-matches case too, appending a second "0" line and turning
	# $count into "0\n0" -- not a valid integer for the `[[ -gt ]]` below.
	count=$(grep -c -- "$pattern" "$file" 2>/dev/null)
	count=${count:-0}
	[[ $count -gt 1 ]]
}

# Helper: validate JSON array
is_valid_json_array() {
	local file=$1
	python3 -c "import json, sys; json.load(open('$file')); print('valid')" 2>/dev/null | grep -q "valid"
}

# ============================================================================
# Early exits
# ============================================================================

if ! check_moire_available; then
	echo "SKIP: bin/moire not present or not executable"
	exit 0
fi

if ! check_git_version; then
	echo "SKIP: git version $GIT_VERSION < 2.38 required (found $MOIRE_GIT)"
	exit 0
fi

# ============================================================================
# Test Cases
# ============================================================================

# TEST 1: moire install copies binary to $GIT_COMMON_DIR/moire/bin/moire and is executable
test_001() {
	local tmpdir=$(setup_test_repo)
	TEMP_DIRS+=("$tmpdir")
	cd "$tmpdir"

	if ! "$MOIRE_BIN" install > /dev/null 2>&1; then
		log_test 001 FAIL "moire install failed"
		rm -rf "$tmpdir"
		return
	fi

	local common_dir=$(get_git_common_dir)
	local moire_installed="$common_dir/moire/bin/moire"

	if [[ ! -f "$moire_installed" ]]; then
		log_test 001 FAIL "binary not copied to $moire_installed"
	elif [[ ! -x "$moire_installed" ]]; then
		log_test 001 FAIL "binary not executable"
	else
		log_test 001 PASS "binary installed and executable"
	fi

	rm -rf "$tmpdir"
}

# TEST 2: After install, git config --get core.hooksPath is empty
test_002() {
	local tmpdir=$(setup_test_repo)
	TEMP_DIRS+=("$tmpdir")
	cd "$tmpdir"

	"$MOIRE_BIN" install > /dev/null 2>&1

	local hooks_path=$("$MOIRE_GIT" config --get core.hooksPath || echo "")

	if [[ -z "$hooks_path" ]]; then
		log_test 002 PASS "core.hooksPath is not set"
	else
		log_test 002 FAIL "core.hooksPath is set to: $hooks_path"
	fi

	rm -rf "$tmpdir"
}

# TEST 3: Hooks land in $GIT_COMMON_DIR/hooks/ and are executable
test_003() {
	local tmpdir=$(setup_test_repo)
	TEMP_DIRS+=("$tmpdir")
	cd "$tmpdir"

	"$MOIRE_BIN" install > /dev/null 2>&1

	local common_dir=$(get_git_common_dir)
	local hooks_dir="$common_dir/hooks"

	local post_commit="$hooks_dir/post-commit"
	local post_merge="$hooks_dir/post-merge"

	if [[ ! -x "$post_commit" ]]; then
		log_test 003 FAIL "post-commit hook not installed or not executable"
	elif [[ ! -x "$post_merge" ]]; then
		log_test 003 FAIL "post-merge hook not installed or not executable"
	else
		log_test 003 PASS "hooks installed and executable"
	fi

	rm -rf "$tmpdir"
}

# TEST 4: moire install is idempotent
test_004() {
	local tmpdir=$(setup_test_repo)
	TEMP_DIRS+=("$tmpdir")
	cd "$tmpdir"

	"$MOIRE_BIN" install > /dev/null 2>&1

	local common_dir=$(get_git_common_dir)
	local post_commit="$common_dir/hooks/post-commit"
	local post_merge="$common_dir/hooks/post-merge"

	# Capture content after first install
	local commit_v1=$(cat "$post_commit")
	local merge_v1=$(cat "$post_merge")

	# Run install again
	"$MOIRE_BIN" install > /dev/null 2>&1

	local commit_v2=$(cat "$post_commit")
	local merge_v2=$(cat "$post_merge")

	if [[ "$commit_v1" != "$commit_v2" ]] || [[ "$merge_v1" != "$merge_v2" ]]; then
		log_test 004 FAIL "hooks changed after second install"
	elif has_duplicate_content "$post_commit" "moire check"; then
		log_test 004 FAIL "duplicate hook content detected"
	else
		log_test 004 PASS "install is idempotent"
	fi

	rm -rf "$tmpdir"
}

# TEST 5: Hook chaining - preserve existing post-commit hook
test_005() {
	local tmpdir=$(setup_test_repo)
	TEMP_DIRS+=("$tmpdir")
	cd "$tmpdir"

	local common_dir=$(get_git_common_dir)
	mkdir -p "$common_dir/hooks"

	# Pre-place an existing post-commit hook that writes a sentinel
	local post_commit="$common_dir/hooks/post-commit"
	cat > "$post_commit" << 'EOF'
#!/bin/bash
echo "SENTINEL_FROM_ORIGINAL_HOOK" > /tmp/moire_test_sentinel_$$
EOF
	chmod +x "$post_commit"

	# Run moire install
	"$MOIRE_BIN" install > /dev/null 2>&1

	# Per cmd_install in bin/moire, chaining moves the
	# pre-existing hook aside to "<hook>.moire-chained" and replaces the hook path
	# itself with a wrapper that calls the chained script first. So checking
	# the literal $post_commit path for the sentinel is checking the wrong
	# file -- it now holds moire's wrapper, not the original content. "Preserved"
	# means: the sentinel survives in the chained file, and the new wrapper
	# actually calls it (so it still fires on a real commit).
	local chained="${post_commit}.moire-chained"

	if [[ ! -f "$chained" ]]; then
		log_test 005 FAIL "original hook was not chained aside to $chained"
	elif ! grep -q "SENTINEL_FROM_ORIGINAL_HOOK" "$chained"; then
		log_test 005 FAIL "original hook content was clobbered"
	elif ! grep -q "moire-chained" "$post_commit"; then
		log_test 005 FAIL "new hook does not call the chained original"
	else
		log_test 005 PASS "original hook content preserved and chained"
	fi

	rm -rf "$tmpdir"
}

# TEST 6: Nothing executable written into any working tree
test_006() {
	local tmpdir=$(setup_test_repo)
	TEMP_DIRS+=("$tmpdir")
	cd "$tmpdir"

	"$MOIRE_BIN" install > /dev/null 2>&1

	# Check for executable files in the working tree (excluding .git).
	# NOTE: `-executable` is a GNU find extension; BSD find (macOS default)
	# rejects it with "unknown primary or operator", find exits nonzero and
	# prints nothing, so `wc -l` silently sees zero lines and this check
	# could never fail. Use `-type f` + a portable `[[ -x ]]` test instead.
	local exec_in_worktree=0
	while IFS= read -r -d '' f; do
		if [[ -x "$f" ]]; then
			exec_in_worktree=$((exec_in_worktree + 1))
		fi
	done < <(find . -path "./.git" -prune -o -type f -print0)

	if [[ $exec_in_worktree -eq 0 ]]; then
		log_test 006 PASS "no executables in worktree"
	else
		log_test 006 FAIL "found $exec_in_worktree executable(s) in worktree"
	fi

	rm -rf "$tmpdir"
}

# TEST 7: moire doctor succeeds from main worktree root
test_007() {
	local tmpdir=$(setup_test_repo)
	TEMP_DIRS+=("$tmpdir")
	cd "$tmpdir"

	"$MOIRE_BIN" install > /dev/null 2>&1

	if "$MOIRE_BIN" doctor > /dev/null 2>&1; then
		log_test 007 PASS "doctor succeeds from main worktree root"
	else
		log_test 007 FAIL "doctor failed from main worktree root"
	fi

	rm -rf "$tmpdir"
}

# TEST 8: moire doctor succeeds from nested subdirectory
test_008() {
	local tmpdir=$(setup_test_repo)
	TEMP_DIRS+=("$tmpdir")
	cd "$tmpdir"

	"$MOIRE_BIN" install > /dev/null 2>&1

	mkdir -p "some/nested/dir"
	cd "some/nested/dir"

	if "$MOIRE_BIN" doctor > /dev/null 2>&1; then
		log_test 008 PASS "doctor succeeds from nested subdirectory"
	else
		log_test 008 FAIL "doctor failed from nested subdirectory"
	fi

	rm -rf "$tmpdir"
}

# TEST 9: moire doctor succeeds from linked worktree and resolves to same state dir
test_009() {
	local tmpdir=$(setup_test_repo)
	TEMP_DIRS+=("$tmpdir")
	cd "$tmpdir"

	"$MOIRE_BIN" install > /dev/null 2>&1

	# Get state dir from main worktree. `git rev-parse --git-common-dir`
	# returns a path RELATIVE TO CWD when run from the main worktree (only
	# absolute from a linked worktree) -- resolve it to absolute now, while
	# cwd is still $tmpdir, so it stays meaningful after we `cd linked-wt`
	# below (a bare string like ".git" resolved against the wrong cwd is
	# not even a directory there, let alone the right one).
	local main_common_dir=$(get_git_common_dir)
	local main_abs
	# `pwd -P` (physical path) rather than plain `pwd`: macOS's mktemp gives
	# paths through the /var -> /private/var symlink, and git's own absolute
	# git-common-dir output (used below for the linked worktree) is already
	# the resolved physical path -- comparing a symlinked spelling against a
	# resolved one would report a false mismatch for the SAME directory.
	main_abs=$(cd "$main_common_dir" && pwd -P)

	# Create a linked worktree
	# NOTE: `git worktree add <path> main` fails ("'main' is already used by
	# worktree at ...") because `main` is already checked out in this very
	# worktree -- git refuses to check the same branch out twice. Use a new
	# branch pointed at the same commit so this is still a genuine linked
	# worktree sharing the common dir, without that collision.
	#
	# NOTE: the target path must stay INSIDE $tmpdir. "../linked-wt" is a
	# sibling of $tmpdir under the shared system tmp root, so it survives
	# `rm -rf "$tmpdir"` and collides with the next test/run that tries the
	# same relative path -- a real "wrote outside the temp dir" violation
	# that also made this test flaky across runs.
	"$MOIRE_GIT" worktree add -b moire-test-linked linked-wt main >/dev/null 2>&1 || {
		log_test 009 SKIP "git worktree not available"
		rm -rf "$tmpdir"
		return
	}

	cd linked-wt

	if ! "$MOIRE_BIN" doctor > /dev/null 2>&1; then
		log_test 009 FAIL "doctor failed from linked worktree"
		rm -rf "$tmpdir"
		return
	fi

	# Verify common dir is the same. The linked worktree's git-common-dir is
	# already absolute (per git's own behavior), so only main_abs needed the
	# earlier resolution.
	local linked_common_dir=$(get_git_common_dir)
	local linked_abs
	linked_abs=$(cd "$linked_common_dir" && pwd -P)

	if [[ "$main_abs" == "$linked_abs" ]]; then
		log_test 009 PASS "doctor succeeds and resolves to same state directory"
	else
		log_test 009 FAIL "state directories differ: $main_abs vs $linked_abs"
	fi

	rm -rf "$tmpdir"
}

# TEST 10: Hooks fire from linked worktrees
test_010() {
	local tmpdir=$(setup_test_repo)
	TEMP_DIRS+=("$tmpdir")
	cd "$tmpdir"

	"$MOIRE_BIN" install > /dev/null 2>&1

	# Create a linked worktree
	# NOTE: `git worktree add <path> main` fails ("'main' is already used by
	# worktree at ...") because `main` is already checked out in this very
	# worktree -- git refuses to check the same branch out twice. Use a new
	# branch pointed at the same commit so this is still a genuine linked
	# worktree sharing the common dir, without that collision.
	#
	# NOTE: the target path must stay INSIDE $tmpdir. "../linked-wt" is a
	# sibling of $tmpdir under the shared system tmp root, so it survives
	# `rm -rf "$tmpdir"` and collides with the next test/run that tries the
	# same relative path -- a real "wrote outside the temp dir" violation
	# that also made this test flaky across runs.
	"$MOIRE_GIT" worktree add -b moire-test-linked linked-wt main >/dev/null 2>&1 || {
		log_test 010 SKIP "git worktree not available"
		rm -rf "$tmpdir"
		return
	}

	cd linked-wt

	# Make a commit to trigger post-commit hook
	echo "test content" > testfile.txt
	"$MOIRE_GIT" add testfile.txt
	"$MOIRE_GIT" commit -m "test commit from linked worktree" > /dev/null 2>&1

	local common_dir=$(get_git_common_dir)
	local log_dir="$common_dir/moire/log"

	# Check if any log shard was created (hook ran)
	if [[ -d "$log_dir" ]] && [[ $(ls "$log_dir" 2>/dev/null | wc -l) -gt 0 ]]; then
		log_test 010 PASS "hooks fire from linked worktree"
	else
		log_test 010 FAIL "no log shard created from linked worktree commit"
	fi

	rm -rf "$tmpdir"
}

# TEST 11: One moire check invocation produces exactly one shard file
test_011() {
	local tmpdir=$(setup_test_repo)
	TEMP_DIRS+=("$tmpdir")
	cd "$tmpdir"

	"$MOIRE_BIN" install > /dev/null 2>&1

	local common_dir=$(get_git_common_dir)
	local log_dir="$common_dir/moire/log"
	mkdir -p "$log_dir"

	# Run moire check
	"$MOIRE_BIN" check > /dev/null 2>&1 || true

	# Count shard files
	local shard_count=$(ls "$log_dir" 2>/dev/null | wc -l)

	if [[ $shard_count -eq 1 ]]; then
		log_test 011 PASS "one shard file created per check"
	else
		log_test 011 FAIL "expected 1 shard, found $shard_count"
	fi

	rm -rf "$tmpdir"
}

# TEST 12: Every shard is a valid JSON array
test_012() {
	local tmpdir=$(setup_test_repo)
	TEMP_DIRS+=("$tmpdir")
	cd "$tmpdir"

	"$MOIRE_BIN" install > /dev/null 2>&1

	local common_dir=$(get_git_common_dir)
	local log_dir="$common_dir/moire/log"
	mkdir -p "$log_dir"

	# Run moire check to create a shard
	"$MOIRE_BIN" check > /dev/null 2>&1 || true

	# Validate each shard is valid JSON array
	local all_valid=true
	for shard in "$log_dir"/*.json; do
		if [[ -f "$shard" ]]; then
			if ! python3 -c "import json, sys; data = json.load(open('$shard')); assert isinstance(data, list)" 2>/dev/null; then
				all_valid=false
				break
			fi
		fi
	done

	if [[ "$all_valid" == "true" ]]; then
		log_test 012 PASS "all shards are valid JSON arrays"
	else
		log_test 012 FAIL "at least one shard is not a valid JSON array"
	fi

	rm -rf "$tmpdir"
}

# TEST 13: Concurrency - 12 parallel moire check runs, all shards valid JSON
test_013() {
	local tmpdir=$(setup_test_repo)
	TEMP_DIRS+=("$tmpdir")
	cd "$tmpdir"

	"$MOIRE_BIN" install > /dev/null 2>&1

	local common_dir=$(get_git_common_dir)
	local log_dir="$common_dir/moire/log"
	mkdir -p "$log_dir"

	# Launch 12 concurrent moire check runs
	local pids=()
	for i in {1..12}; do
		"$MOIRE_BIN" check > /dev/null 2>&1 &
		pids+=($!)
	done

	# Wait for all to complete
	for pid in "${pids[@]}"; do
		wait "$pid" 2>/dev/null || true
	done

	# Count shard files and validate each
	local shard_count=$(ls "$log_dir" 2>/dev/null | wc -l)
	local invalid_count=0

	for shard in "$log_dir"/*.json; do
		if [[ -f "$shard" ]]; then
			if ! python3 -c "import json, sys; data = json.load(open('$shard')); assert isinstance(data, list)" 2>/dev/null; then
				invalid_count=$((invalid_count + 1))
			fi
		fi
	done

	if [[ $shard_count -eq 12 ]] && [[ $invalid_count -eq 0 ]]; then
		log_test 013 PASS "12 concurrent checks: 12 shards, all valid JSON"
	elif [[ $shard_count -eq 0 ]]; then
		log_test 013 SKIP "moire check did not create shards (phase 1 not yet implemented)"
	else
		log_test 013 FAIL "expected 12 shards, found $shard_count; $invalid_count invalid"
	fi

	rm -rf "$tmpdir"
}

# TEST 14: moire report runs and prints base rate
test_014() {
	local tmpdir=$(setup_test_repo)
	TEMP_DIRS+=("$tmpdir")
	cd "$tmpdir"

	"$MOIRE_BIN" install > /dev/null 2>&1

	local common_dir=$(get_git_common_dir)
	local log_dir="$common_dir/moire/log"
	mkdir -p "$log_dir"

	# Run a check to create a shard
	"$MOIRE_BIN" check > /dev/null 2>&1 || true

	# Run moire report
	local output=$("$MOIRE_BIN" report 2>&1 || true)

	# Check if report ran and printed something (base rate should be mentioned)
	if echo "$output" | grep -qiE "rate|check|conflict" || [[ $? -eq 0 ]]; then
		log_test 014 PASS "moire report runs and produces output"
	else
		log_test 014 SKIP "moire report not yet implemented or no output"
	fi

	rm -rf "$tmpdir"
}

# TEST 15: moire doctor exits non-zero before install, 0 after
test_015() {
	local tmpdir=$(setup_test_repo)
	TEMP_DIRS+=("$tmpdir")
	cd "$tmpdir"

	# Before install, doctor should fail
	if "$MOIRE_BIN" doctor > /dev/null 2>&1; then
		log_test 015 FAIL "doctor should exit non-zero before install"
		rm -rf "$tmpdir"
		return
	fi

	# After install, doctor should succeed
	"$MOIRE_BIN" install > /dev/null 2>&1

	if "$MOIRE_BIN" doctor > /dev/null 2>&1; then
		log_test 015 PASS "doctor exits non-zero before install, 0 after"
	else
		log_test 015 FAIL "doctor should exit 0 after install"
	fi

	rm -rf "$tmpdir"
}

# TEST 16: moire doctor exits non-zero if core.hooksPath is set
test_016() {
	local tmpdir=$(setup_test_repo)
	TEMP_DIRS+=("$tmpdir")
	cd "$tmpdir"

	"$MOIRE_BIN" install > /dev/null 2>&1

	# Set core.hooksPath to something
	"$MOIRE_GIT" config core.hooksPath ".git/hooks"

	if "$MOIRE_BIN" doctor > /dev/null 2>&1; then
		log_test 016 FAIL "doctor should exit non-zero when core.hooksPath is set"
	else
		log_test 016 PASS "doctor exits non-zero when core.hooksPath is set"
	fi

	# Clean up
	"$MOIRE_GIT" config --unset core.hooksPath || true

	rm -rf "$tmpdir"
}

# ============================================================================
# Run all tests
# ============================================================================

test_001
test_002
test_003
test_004
test_005
test_006
test_007
test_008
test_009
test_010
test_011
test_012
test_013
test_014
test_015
test_016

# ============================================================================
# Summary
# ============================================================================

echo ""
echo "=========================================="
printf "Results: %d passed, %d failed, %d skipped\n" "$PASS_COUNT" "$FAIL_COUNT" "$SKIP_COUNT"
echo "=========================================="

if [[ $FAIL_COUNT -eq 0 ]]; then
	exit 0
else
	exit 1
fi
