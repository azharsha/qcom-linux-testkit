#!/bin/sh

# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause

# Robustly find and source init_env
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INIT_ENV=""
SEARCH="$SCRIPT_DIR"

while [ "$SEARCH" != "/" ]; do
    if [ -f "$SEARCH/init_env" ]; then
        INIT_ENV="$SEARCH/init_env"
        break
    fi
    SEARCH=$(dirname "$SEARCH")
done

if [ -z "$INIT_ENV" ]; then
    echo "[ERROR] Could not find init_env (starting at $SCRIPT_DIR)" >&2
    exit 1
fi

# Only source if not already loaded (idempotent)
if [ -z "${__INIT_ENV_LOADED:-}" ]; then
    # shellcheck disable=SC1090
    . "$INIT_ENV"
fi

# Always source functestlib.sh, using $TOOLS exported by init_env
# shellcheck disable=SC1090,SC1091
. "$TOOLS/functestlib.sh"

TESTNAME="Interrupts"
test_path=$(find_test_case_by_name "$TESTNAME")
cd "$test_path" || exit 1

# shellcheck disable=SC2034
res_file="./$TESTNAME.res"

INTERRUPTS_WAIT_TIMEOUT_S="${INTERRUPTS_WAIT_TIMEOUT_S:-30}"
INTERRUPTS_POLL_INTERVAL_S="${INTERRUPTS_POLL_INTERVAL_S:-2}"

log_info "-----------------------------------------------------------------------------------------"
log_info "-------------------Starting $TESTNAME Testcase----------------------------"
log_info "=== Test Initialization ==="
log_info "Config: INTERRUPTS_WAIT_TIMEOUT_S=${INTERRUPTS_WAIT_TIMEOUT_S} INTERRUPTS_POLL_INTERVAL_S=${INTERRUPTS_POLL_INTERVAL_S}"

if ! wait_for_interrupt_cpu_count_increment "arch_timer" "$INTERRUPTS_WAIT_TIMEOUT_S" "$INTERRUPTS_POLL_INTERVAL_S"; then
    log_fail "$TESTNAME : Test Failed"
    echo "$TESTNAME FAIL" > "$res_file"
    exit 1
fi

echo "Initial timer count:"
echo "$INTERRUPT_WAIT_INITIAL_LINE"

echo "Timer count after polling:"
echo "$INTERRUPT_WAIT_FINAL_LINE"

echo "Comparing timer counts:"
log_info "Detected timer counters: initial=${INTERRUPT_COMPARE_CPU_COUNT} final=${INTERRUPT_COMPARE_CPU_COUNT}"
log_info "arch_timer counters incremented on all CPUs after ${INTERRUPT_WAIT_ELAPSED_S}s"

cpu_index=0
while [ "$cpu_index" -lt "$INTERRUPT_COMPARE_CPU_COUNT" ]; do
    initial_value="$(printf '%s\n' "$INTERRUPT_COMPARE_INITIAL_VALUES" | sed -n "$((cpu_index + 1))p")"
    final_value="$(printf '%s\n' "$INTERRUPT_COMPARE_FINAL_VALUES" | sed -n "$((cpu_index + 1))p")"

    echo "CPU $cpu_index: Timer count has incremented. Test PASSED"
    log_pass "CPU $cpu_index: Timer count has incremented. initial=${initial_value} final=${final_value}"

    cpu_index=$((cpu_index + 1))
done

log_pass "$TESTNAME : Test Passed"
echo "$TESTNAME PASS" > "$res_file"
exit 0
