#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause
#
# DDR Training Test - controller-side serial-log capture + reboot + parse
#
# IMPORTANT:
#   This script must run on a controller/host that can:
#     1) access the DUT serial port
#     2) execute a reboot/reset command for the DUT
#
#   It must NOT be run on the same machine that is rebooting.
#
# Flow per iteration:
#   1. Start serial capture to a per-iteration log
#   2. Trigger DUT reboot using REBOOT_TARGET_CMD
#   3. Wait for BOOT_MARKER in the collected log
#   4. Stop serial capture
#   5. Parse DDR training time from the log
#   6. Compare against thresholds
#   7. Record PASS/FAIL and continue

SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" 2>/dev/null && pwd)

TESTNAME="${TESTNAME:-DDR_Training}"

ITERATIONS="${ITERATIONS:-5}"
SERIAL_PORT="${SERIAL_PORT:-/dev/ttyMSM0}"
SERIAL_BAUD="${SERIAL_BAUD:-115200}"
SERIAL_LOG_DIR="${SERIAL_LOG_DIR:-$SCRIPT_DIR/logs}"
RES_FILE="${RES_FILE:-$SCRIPT_DIR/${TESTNAME}.res}"

BOOT_TIMEOUT_S="${BOOT_TIMEOUT_S:-300}"
POST_BOOT_SETTLE_S="${POST_BOOT_SETTLE_S:-2}"
BOOT_MARKER="${BOOT_MARKER:-POST Time}"

DDR_TRAINING_TIME_MIN="${DDR_TRAINING_TIME_MIN:-0}"     # seconds
DDR_TRAINING_TIME_MAX="${DDR_TRAINING_TIME_MAX:-500}"   # seconds

# Must be supplied by caller. Examples:
#   REBOOT_TARGET_CMD='ssh root@192.168.1.50 reboot'
#   REBOOT_TARGET_CMD='adb reboot'
#   REBOOT_TARGET_CMD='/path/to/reset_target.sh'
REBOOT_TARGET_CMD="${REBOOT_TARGET_CMD:-reboot}"

CHIPSET="${CHIPSET:-}"   # e.g. Mannar or empty for generic

SERIAL_CAP_PID=""
PASS_COUNT=0
FAIL_COUNT=0

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------
log_info() { printf '%s\n' "[INFO] $*"; }
log_warn() { printf '%s\n' "[WARN] $*" >&2; }
log_fail() { printf '%s\n' "[FAIL] $*" >&2; }
log_pass() { printf '%s\n' "[PASS] $*"; }
log_skip() { printf '%s\n' "[SKIP] $*"; }

fatal() {
    log_fail "$*"
    cleanup
    exit 1
}

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
usage() {
    cat <<EOF
Usage: $0 [options]

Options:
  --iterations N          Number of reboot iterations (default: $ITERATIONS)
  --serial-port DEV       Serial device node (default: $SERIAL_PORT)
  --serial-baud RATE      Baud rate (default: $SERIAL_BAUD)
  --log-dir DIR           Directory to store per-iteration logs (default: $SERIAL_LOG_DIR)
  --res-file FILE         Result file path (default: $RES_FILE)
  --boot-timeout S        Timeout waiting for boot marker (default: $BOOT_TIMEOUT_S)
  --settle-time S         Extra sleep after boot marker before stopping capture (default: $POST_BOOT_SETTLE_S)
  --boot-marker STR       String that indicates boot is complete enough (default: $BOOT_MARKER)
  --ddr-min S             Minimum DDR training time in seconds (default: $DDR_TRAINING_TIME_MIN)
  --ddr-max S             Maximum DDR training time in seconds (default: $DDR_TRAINING_TIME_MAX)
  --chipset NAME          Chipset name (Mannar or generic; default: empty/generic)
  --reboot-cmd CMD        Command used to reboot the DUT (required)
  -h, --help              Show this help and exit

Environment variables may also be used for all options.
EOF
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
is_uint() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
        *) return 0 ;;
    esac
}

check_dependencies() {
    for _cmd in "$@"; do
        command -v "$_cmd" >/dev/null 2>&1 || fatal "Missing dependency: $_cmd"
    done
}

cleanup() {
    if [ -n "$SERIAL_CAP_PID" ]; then
        kill "$SERIAL_CAP_PID" 2>/dev/null || true
        wait "$SERIAL_CAP_PID" 2>/dev/null || true
        SERIAL_CAP_PID=""
    fi
}

trap cleanup EXIT INT TERM HUP

start_serial_capture() {
    _logfile="$1"

    # Try to set the serial port parameters. Ignore failure if the environment
    # already manages line discipline, but keep the capture attempt.
    stty "$SERIAL_BAUD" cs8 -cstopb -parenb -echo < "$SERIAL_PORT" 2>/dev/null || \
        log_warn "stty configuration failed for $SERIAL_PORT; continuing anyway"

    cat "$SERIAL_PORT" >> "$_logfile" &
    SERIAL_CAP_PID=$!

    # Verify that the capture process stayed alive long enough to open the port.
    sleep 1
    if ! kill -0 "$SERIAL_CAP_PID" 2>/dev/null; then
        SERIAL_CAP_PID=""
        fatal "Serial capture failed to start on $SERIAL_PORT"
    fi

    log_info "Serial capture started: PID=$SERIAL_CAP_PID -> $_logfile"
}

stop_serial_capture() {
    if [ -n "$SERIAL_CAP_PID" ]; then
        kill "$SERIAL_CAP_PID" 2>/dev/null || true
        wait "$SERIAL_CAP_PID" 2>/dev/null || true
        SERIAL_CAP_PID=""
        log_info "Serial capture stopped"
    fi
}

wait_for_string() {
    _file="$1"
    _str="$2"
    _timeout="$3"
    _elapsed=0

    while [ "$_elapsed" -lt "$_timeout" ]; do
        if [ -f "$_file" ] && grep -qF "$_str" "$_file" 2>/dev/null; then
            return 0
        fi
        sleep 2
        _elapsed=$((_elapsed + 2))
    done

    return 1
}

parse_ddr_delta_us() {
    # Prints the extracted delta in microseconds to stdout on success.
    _logfile="$1"

    if [ "$CHIPSET" = "Mannar" ]; then
        _pattern='^[[:space:]]*\[.*\][[:space:]]*D -[[:space:]].*[[:space:]]- sbl1_do_ddr_training[[:space:]]*$'
        _split=' - sbl1_do_ddr_training'
    else
        _pattern='^[[:space:]]*\[.*\][[:space:]]*D -[[:space:]].*[[:space:]]- do_ddr_training, Delta[[:space:]]*$'
        _split=' - do_ddr_training, Delta'
    fi

    _line=$(grep -E "$_pattern" "$_logfile" 2>/dev/null | head -n 1)
    [ -n "$_line" ] || return 1

    _left=$(printf '%s' "$_line" | awk -F"$_split" '{print $1}')
    _delta_us=$(printf '%s' "$_left" | sed 's/^[[:space:]]*\[.*\][[:space:]]*D -[[:space:]]*//')

    case "$_delta_us" in
        ''|*[!0-9]*)
            return 2
            ;;
    esac

    printf '%s\n' "$_delta_us"
    return 0
}

write_res() {
    # Usage: write_res ITER STATUS MESSAGE
    _iter="$1"
    _status="$2"
    _msg="$3"
    printf '%s_iter_%s %s %s\n' "$TESTNAME" "$_iter" "$_status" "$_msg" >> "$RES_FILE"
}

# ---------------------------------------------------------------------------
# CLI parsing
# ---------------------------------------------------------------------------
while [ "$#" -gt 0 ]; do
    case "$1" in
        --iterations) shift; ITERATIONS="${1:?--iterations requires a value}" ;;
        --serial-port) shift; SERIAL_PORT="${1:?--serial-port requires a value}" ;;
        --serial-baud) shift; SERIAL_BAUD="${1:?--serial-baud requires a value}" ;;
        --log-dir) shift; SERIAL_LOG_DIR="${1:?--log-dir requires a value}" ;;
        --res-file) shift; RES_FILE="${1:?--res-file requires a value}" ;;
        --boot-timeout) shift; BOOT_TIMEOUT_S="${1:?--boot-timeout requires a value}" ;;
        --settle-time) shift; POST_BOOT_SETTLE_S="${1:?--settle-time requires a value}" ;;
        --boot-marker) shift; BOOT_MARKER="${1:?--boot-marker requires a value}" ;;
        --ddr-min) shift; DDR_TRAINING_TIME_MIN="${1:?--ddr-min requires a value}" ;;
        --ddr-max) shift; DDR_TRAINING_TIME_MAX="${1:?--ddr-max requires a value}" ;;
        --chipset) shift; CHIPSET="${1:?--chipset requires a value}" ;;
        --reboot-cmd) shift; REBOOT_TARGET_CMD="${1:?--reboot-cmd requires a value}" ;;
        -h|--help) usage; exit 0 ;;
        *)
            fatal "Unknown option: $1"
            ;;
    esac
    shift
done

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------
is_uint "$ITERATIONS" || fatal "ITERATIONS must be a non-negative integer"
is_uint "$BOOT_TIMEOUT_S" || fatal "BOOT_TIMEOUT_S must be a non-negative integer"
is_uint "$POST_BOOT_SETTLE_S" || fatal "POST_BOOT_SETTLE_S must be a non-negative integer"
is_uint "$DDR_TRAINING_TIME_MIN" || fatal "DDR_TRAINING_TIME_MIN must be a non-negative integer"
is_uint "$DDR_TRAINING_TIME_MAX" || fatal "DDR_TRAINING_TIME_MAX must be a non-negative integer"
[ -n "$REBOOT_TARGET_CMD" ] || fatal "REBOOT_TARGET_CMD is required and must be set explicitly"

check_dependencies stty grep awk sed cat kill sleep head

mkdir -p "$SERIAL_LOG_DIR" || fatal "Failed to create log directory: $SERIAL_LOG_DIR"
: > "$RES_FILE" || fatal "Failed to create result file: $RES_FILE"

case "$SERIAL_PORT" in
    /dev/*)
        if [ ! -c "$SERIAL_PORT" ]; then
            fatal "Serial port $SERIAL_PORT is not a character device or is not present"
        fi
        ;;
esac

DDR_MIN_US=$((DDR_TRAINING_TIME_MIN * 1000000))
DDR_MAX_US=$((DDR_TRAINING_TIME_MAX * 1000000))

# ---------------------------------------------------------------------------
# Start
# ---------------------------------------------------------------------------
log_info "=== $TESTNAME START ==="
log_info "Iterations  : $ITERATIONS"
log_info "Serial port : $SERIAL_PORT @ $SERIAL_BAUD"
log_info "Log dir     : $SERIAL_LOG_DIR"
log_info "Result file : $RES_FILE"
log_info "Boot marker : $BOOT_MARKER"
log_info "Boot timeout: ${BOOT_TIMEOUT_S}s"
log_info "Settle time : ${POST_BOOT_SETTLE_S}s"
log_info "DDR range   : ${DDR_TRAINING_TIME_MIN}s..${DDR_TRAINING_TIME_MAX}s"
log_info "Chipset     : ${CHIPSET:-generic}"

i=0
while [ "$i" -lt "$ITERATIONS" ]; do
    iter_log="${SERIAL_LOG_DIR}/${TESTNAME}_iter_${i}.log"
    rm -f "$iter_log"

    log_info "--- Iteration $i ---"
    log_info "Log file: $iter_log"

    start_serial_capture "$iter_log"

    log_info "Iter $i: triggering reboot with configured command"
    if ! sh -c "$REBOOT_TARGET_CMD"; then
        log_fail "Iter $i: reboot command returned non-zero"
        stop_serial_capture
        write_res "$i" FAIL "reboot_command_failed"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        i=$((i + 1))
        continue
    fi

    log_info "Iter $i: waiting for boot marker '$BOOT_MARKER'"
    if ! wait_for_string "$iter_log" "$BOOT_MARKER" "$BOOT_TIMEOUT_S"; then
        log_fail "Iter $i: boot marker not found within ${BOOT_TIMEOUT_S}s"
        stop_serial_capture
        write_res "$i" FAIL "boot_marker_timeout"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        i=$((i + 1))
        continue
    fi

    log_info "Iter $i: boot marker found; settling for ${POST_BOOT_SETTLE_S}s"
    sleep "$POST_BOOT_SETTLE_S"

    stop_serial_capture

    ddr_us=$(parse_ddr_delta_us "$iter_log" 2>/dev/null)
    rc=$?

    if [ "$rc" -ne 0 ]; then
        if [ "$rc" -eq 2 ]; then
            log_fail "Iter $i: DDR delta found but was non-numeric"
            write_res "$i" FAIL "ddr_delta_non_numeric"
        else
            log_fail "Iter $i: DDR training line not found in log"
            write_res "$i" FAIL "ddr_delta_not_found"
        fi
        FAIL_COUNT=$((FAIL_COUNT + 1))
        i=$((i + 1))
        continue
    fi

    log_info "Iter $i: DDR delta = ${ddr_us} us"

    if [ "$ddr_us" -ge "$DDR_MIN_US" ] && [ "$ddr_us" -le "$DDR_MAX_US" ]; then
        log_pass "Iter $i: PASS (within thresholds)"
        write_res "$i" PASS "ddr_delta=${ddr_us}us"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        log_fail "Iter $i: FAIL (outside thresholds)"
        write_res "$i" FAIL "ddr_delta=${ddr_us}us_out_of_range"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi

    i=$((i + 1))
done

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
TOTAL_COUNT=$((PASS_COUNT + FAIL_COUNT))
log_info "Total iterations : $TOTAL_COUNT"
log_info "Pass            : $PASS_COUNT"
log_info "Fail            : $FAIL_COUNT"

if [ "$FAIL_COUNT" -eq 0 ] && [ "$TOTAL_COUNT" -eq "$ITERATIONS" ]; then
    log_pass "$TESTNAME PASS"
    printf '%s PASS\n' "$TESTNAME" >> "$RES_FILE"
    exit 0
fi

log_fail "$TESTNAME FAIL"
printf '%s FAIL\n' "$TESTNAME" >> "$RES_FILE"
exit 1
