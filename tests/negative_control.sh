#!/bin/bash

# tests/negative_control.sh - proves the five suites can actually FAIL.
#
# Deleting bin/moire and running the suites is not a negative control: every
# suite's early-exit guard used to print "SKIP: bin/moire not present" and
# exit 0 when the binary was missing - correct skip-guard behaviour, but it
# demonstrates nothing about whether the suite's assertions catch a broken
# tool. A suite that always exits 0 when the tool is absent would pass that
# "test" too. (F8 closes half of this: a missing/stub binary is now a FAIL
# in every suite's own guard, not a SKIP - see the guard at the top of each
# tests/test_*.sh main().)
#
# The real negative control has to stub the LOGIC, not just remove the
# binary: point MOIRE_BIN at something present, executable, and that does
# nothing (`exit 0` for every invocation, real logic replaced with a no-op),
# then confirm every suite goes RED - not skips, not passes vacuously, but
# FAILS with a nonzero exit, because its assertions on actual output no
# longer hold. Two scenarios are checked, both required by F8:
#
#   1. MOIRE_BIN -> a present, executable stub that does nothing.
#   2. MOIRE_BIN -> a path that does not exist at all.
#
# Every suite must exit nonzero in BOTH scenarios. This script's own exit
# code reports whether that held: 0 means the negative control is validated
# (the suites really do fail when the tool is broken or absent); nonzero
# means some suite exited 0 anyway, which is a hole in that suite, not a
# passing negative control.
#
# Run this against the real bin/moire separately (bash tests/test_*.sh with
# no MOIRE_BIN override) to see the contrasting GREEN run - this script only
# ever exercises the two broken scenarios above, on purpose: mixing a "real
# binary passes" assertion in here would let a suite that passes on the
# stub AND on the real binary slip through undetected.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SUITES=(test_oracle.sh test_install.sh test_report.sh test_setup.sh test_verify.sh)

CHECKS=0
PASSED=0
FAILED=0

STUB_DIR=""
cleanup() {
    if [ -n "$STUB_DIR" ] && [ -d "$STUB_DIR" ]; then
        rm -rf "$STUB_DIR"
    fi
}
trap cleanup EXIT

STUB_DIR=$(mktemp -d)
STUB_BIN="$STUB_DIR/moire"
printf '#!/bin/sh\nexit 0\n' > "$STUB_BIN"
chmod +x "$STUB_BIN"
MISSING_BIN="$STUB_DIR/nowhere/moire"

# Run one suite with MOIRE_BIN pointed at a broken binary; PASS (for this
# negative-control check) means the suite exited nonzero, i.e. it noticed.
check_scenario() {
    local scenario="$1" bin_path="$2" suite="$3"
    local out rc
    out=$(MOIRE_BIN="$bin_path" bash "$SCRIPT_DIR/$suite" 2>&1)
    rc=$?
    CHECKS=$((CHECKS + 1))
    if [ "$rc" -ne 0 ]; then
        echo "PASS  [$scenario] $suite  (exited $rc - went RED as required)"
        PASSED=$((PASSED + 1))
    else
        echo "FAIL  [$scenario] $suite  (exited 0 - should have gone RED)"
        FAILED=$((FAILED + 1))
        echo "  --- last 15 lines of suite output ---"
        echo "$out" | tail -15 | sed 's/^/  /'
    fi
}

echo "== scenario: stub binary present, executable, logic replaced with a no-op =="
echo "   MOIRE_BIN=$STUB_BIN (#!/bin/sh; exit 0)"
for suite in "${SUITES[@]}"; do
    check_scenario "stub" "$STUB_BIN" "$suite"
done

echo ""
echo "== scenario: MOIRE_BIN points at a path that does not exist =="
echo "   MOIRE_BIN=$MISSING_BIN"
for suite in "${SUITES[@]}"; do
    check_scenario "missing" "$MISSING_BIN" "$suite"
done

echo ""
echo "Summary: $CHECKS checks, $PASSED went RED as required, $FAILED wrongly stayed GREEN"

if [ "$FAILED" -gt 0 ]; then
    exit 1
fi
exit 0
