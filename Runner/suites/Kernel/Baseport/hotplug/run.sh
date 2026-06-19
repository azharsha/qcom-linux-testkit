#!/bin/sh

# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause

SCRIPT_DIR="$(
    cd "$(dirname "$0")" || exit 1
    pwd
)"
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

if [ -z "${__INIT_ENV_LOADED:-}" ]; then
    # shellcheck disable=SC1090
    . "$INIT_ENV"
    __INIT_ENV_LOADED=1
fi

# shellcheck disable=SC1090,SC1091
. "$TOOLS/functestlib.sh"

TESTNAME="hotplug"

test_path="$(find_test_case_by_name "$TESTNAME")"
if [ -n "$test_path" ]; then
    cd "$test_path" || exit 1
else
    log_warn "Path not found for $TESTNAME test. Falling back to SCRIPT_DIR: $SCRIPT_DIR"
    test_path="$SCRIPT_DIR"
    cd "$test_path" || exit 1
fi

res_file="./$TESTNAME.res"
out_dir="./out"

HOTPLUG_BOOT_SETTLE_SECONDS="${HOTPLUG_BOOT_SETTLE_SECONDS:-10}"
HOTPLUG_RETRIES="${HOTPLUG_RETRIES:-3}"
HOTPLUG_RETRY_DELAY_SECONDS="${HOTPLUG_RETRY_DELAY_SECONDS:-5}"
HOTPLUG_RESTORE_DELAY_SECONDS="${HOTPLUG_RESTORE_DELAY_SECONDS:-1}"

# If a CPU returns persistent EBUSY during the first pass, do not fail
# immediately. Continue with other CPUs and retry EBUSY CPUs at the end.
HOTPLUG_DEFER_EBUSY="${HOTPLUG_DEFER_EBUSY:-1}"
HOTPLUG_DEFER_PASSES="${HOTPLUG_DEFER_PASSES:-1}"

# Optional debug-only override. Empty means runtime-discover all online CPUs.
HOTPLUG_CPU_LIST="${HOTPLUG_CPU_LIST:-}"

mkdir -p "$out_dir"
rm -f "$res_file"
cpu_hotplug_reset_registry

trap 'cpu_hotplug_cleanup_registered' EXIT INT TERM

log_info "-----------------------------------------------------------------------------------------"
log_info "-------------------Starting $TESTNAME Testcase----------------------------"
log_info "=== Test Initialization ==="
log_info "Policy, runtime-discovered CPU hotplug validation"
log_info "Config, BOOT_SETTLE=${HOTPLUG_BOOT_SETTLE_SECONDS}s RETRIES=$HOTPLUG_RETRIES RETRY_DELAY=${HOTPLUG_RETRY_DELAY_SECONDS}s RESTORE_DELAY=${HOTPLUG_RESTORE_DELAY_SECONDS}s DEFER_EBUSY=$HOTPLUG_DEFER_EBUSY DEFER_PASSES=$HOTPLUG_DEFER_PASSES"

if [ -n "$HOTPLUG_CPU_LIST" ]; then
    log_info "CPU selection override, HOTPLUG_CPU_LIST=$HOTPLUG_CPU_LIST"
else
    log_info "CPU selection, using runtime-discovered online CPUs"
fi

deps_list="cat grep awk sed tr sleep taskset mkdir rm id tail dmesg"

log_info "Checking dependencies: $deps_list"
if ! CHECK_DEPS_NO_EXIT=1 check_dependencies "$deps_list"; then
    log_skip "$TESTNAME SKIP - missing one or more dependencies: $deps_list"
    echo "$TESTNAME SKIP" > "$res_file"
    exit 0
fi

if [ "$(id -u)" -ne 0 ]; then
    log_fail "$TESTNAME FAIL - root privilege is required for CPU hotplug validation"
    echo "$TESTNAME FAIL" > "$res_file"
    exit 1
fi

if [ ! -r /sys/devices/system/cpu/online ]; then
    log_fail "Unable to read /sys/devices/system/cpu/online"
    echo "$TESTNAME FAIL" > "$res_file"
    exit 1
fi

if ! check_kernel_config "CONFIG_HOTPLUG_CPU"; then
    log_fail "CONFIG_HOTPLUG_CPU is required for CPU hotplug validation"
    echo "$TESTNAME FAIL" > "$res_file"
    exit 1
fi

if ! command -v cpu_hotplug_validate_cpu_once >/dev/null 2>&1; then
    log_fail "cpu_hotplug_validate_cpu_once helper is missing from functestlib.sh"
    echo "$TESTNAME FAIL" > "$res_file"
    exit 1
fi

log_info "Waiting ${HOTPLUG_BOOT_SETTLE_SECONDS}s for system to settle before CPU hotplug"
sleep "$HOTPLUG_BOOT_SETTLE_SECONDS"

cpu_hotplug_log_topology

online_cpus="$(get_online_cpus)"
online_count="$(printf '%s\n' "$online_cpus" | awk 'NF { count++ } END { print count + 0 }')"

if [ "$online_count" -lt 2 ]; then
    log_skip "$TESTNAME SKIP - fewer than two online CPUs available; cannot offline the last runnable CPU safely"
    echo "$TESTNAME SKIP" > "$res_file"
    exit 0
fi

if [ -n "$HOTPLUG_CPU_LIST" ]; then
    selected_cpus="$(expand_cpu_list "$HOTPLUG_CPU_LIST")"
else
    selected_cpus="$online_cpus"
fi

if [ -z "$selected_cpus" ]; then
    log_fail "No CPUs selected for hotplug validation"
    echo "$TESTNAME FAIL" > "$res_file"
    exit 1
fi

selected_count="$(printf '%s\n' "$selected_cpus" | awk 'NF { count++ } END { print count + 0 }')"

log_info "Selected CPUs for hotplug validation:"
printf '%s\n' "$selected_cpus" |
while IFS= read -r cpu_index || [ -n "$cpu_index" ]; do
    [ -n "$cpu_index" ] || continue
    cpu_hotplug_log_cpu_topology_one "$cpu_index"
done

controllable=0
tested=0
passed=0
failed=0
skipped=0
deferred=0
deferred_cpus=""

case "$HOTPLUG_RETRIES" in
    ''|*[!0-9]*)
        HOTPLUG_RETRIES=3
        ;;
esac

case "$HOTPLUG_RETRY_DELAY_SECONDS" in
    ''|*[!0-9]*)
        HOTPLUG_RETRY_DELAY_SECONDS=5
        ;;
esac

case "$HOTPLUG_RESTORE_DELAY_SECONDS" in
    ''|*[!0-9]*)
        HOTPLUG_RESTORE_DELAY_SECONDS=1
        ;;
esac

case "$HOTPLUG_DEFER_PASSES" in
    ''|*[!0-9]*)
        HOTPLUG_DEFER_PASSES=1
        ;;
esac

if [ "$HOTPLUG_DEFER_PASSES" -lt 1 ] 2>/dev/null; then
    HOTPLUG_DEFER_PASSES=1
fi

# Primary pass:
# Test all selected CPUs once. CPUs that return persistent EBUSY are not failed
# immediately when deferral is enabled; they are retried after the other CPUs.
for cpu_index in $selected_cpus; do
    cpu_hotplug_validate_cpu_once \
        "$cpu_index" \
        "primary" \
        "$HOTPLUG_RETRIES" \
        "$HOTPLUG_RETRY_DELAY_SECONDS" \
        "$HOTPLUG_RESTORE_DELAY_SECONDS" \
        "$out_dir"

    cpu_rc=$?

    if [ "$cpu_rc" -eq 2 ]; then
        if [ "$HOTPLUG_DEFER_EBUSY" = "1" ]; then
            log_warn "CPU$cpu_index EBUSY persisted during primary pass; deferring until after other CPUs"
            deferred_cpus="${deferred_cpus} ${cpu_index}"
            deferred=$((deferred + 1))
        else
            log_fail "CPU$cpu_index failed due to persistent EBUSY and deferral is disabled"
            failed=$((failed + 1))
        fi
    fi
done

# Deferred pass:
# Retry only CPUs that were busy in the primary pass. This handles early boot
# transient EBUSY without hiding real persistent hotplug failures.
defer_pass=1
while [ -n "$deferred_cpus" ] && [ "$defer_pass" -le "$HOTPLUG_DEFER_PASSES" ]; do
    retry_cpus="$deferred_cpus"
    deferred_cpus=""

    log_info "Retrying EBUSY-deferred CPUs, deferred pass ${defer_pass}/${HOTPLUG_DEFER_PASSES}:$retry_cpus"

    for cpu_index in $retry_cpus; do
        cpu_hotplug_validate_cpu_once \
            "$cpu_index" \
            "deferred-${defer_pass}" \
            "$HOTPLUG_RETRIES" \
            "$HOTPLUG_RETRY_DELAY_SECONDS" \
            "$HOTPLUG_RESTORE_DELAY_SECONDS" \
            "$out_dir"

        cpu_rc=$?

        if [ "$cpu_rc" -eq 2 ]; then
            if [ "$defer_pass" -lt "$HOTPLUG_DEFER_PASSES" ]; then
                log_warn "CPU$cpu_index still EBUSY; keeping for another deferred pass"
                deferred_cpus="${deferred_cpus} ${cpu_index}"
            else
                log_fail "CPU$cpu_index remained EBUSY after deferred retry handling"
                failed=$((failed + 1))
            fi
        fi
    done

    defer_pass=$((defer_pass + 1))
done

cpu_hotplug_log_topology

log_info "=== CPU hotplug Summary ==="
log_info "HOTPLUG_SUMMARY: online=$online_count selected=$selected_count controllable=$controllable tested=$tested passed=$passed failed=$failed skipped=$skipped deferred_ebusy=$deferred"

if [ "$failed" -gt 0 ]; then
    log_fail "$TESTNAME : Test Failed"
    echo "$TESTNAME FAIL" > "$res_file"
    exit 1
fi

if [ "$tested" -eq 0 ]; then
    log_skip "$TESTNAME SKIP - no runtime-discovered CPU completed hotplug validation"
    echo "$TESTNAME SKIP" > "$res_file"
    exit 0
fi

log_pass "$TESTNAME : Test Passed"
echo "$TESTNAME PASS" > "$res_file"
exit 0
