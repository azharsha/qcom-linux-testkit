#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause#
# BT_SCAN – Bluetooth scanning validation (non-expect version)

# ---------- Repo env + helpers ----------
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

# shellcheck disable=SC1091
. "$TOOLS/functestlib.sh"
# shellcheck disable=SC1091
. "$TOOLS/lib_bluetooth.sh"

# ---------- CLI / env parameters ----------
BT_ADAPTER="${BT_ADAPTER-}"
BT_SCAN_TARGET_MAC="${BT_SCAN_TARGET_MAC-}"
BT_TARGET_MAC="${BT_TARGET_MAC-}"
BT_SCAN_SECONDS="${BT_SCAN_SECONDS:-15}"
BT_SCAN_RETRIES="${BT_SCAN_RETRIES:-3}"
BT_SCAN_RETRY_DELAY="${BT_SCAN_RETRY_DELAY:-2}"

while [ "$#" -gt 0 ]; do
    case "$1" in
        --adapter)
            BT_ADAPTER="$2"
            shift 2
            ;;
        --target-mac)
            BT_TARGET_MAC="$2"
            shift 2
            ;;
        --scan-seconds)
            BT_SCAN_SECONDS="$2"
            shift 2
            ;;
        --scan-retries)
            BT_SCAN_RETRIES="$2"
            shift 2
            ;;
        --scan-retry-delay)
            BT_SCAN_RETRY_DELAY="$2"
            shift 2
            ;;
        *)
            log_warn "Unknown argument ignored: $1"
            shift 1
            ;;
    esac
done

TESTNAME="BT_SCAN"
testpath="$(find_test_case_by_name "$TESTNAME")" || {
    log_fail "$TESTNAME : Test directory not found."
    echo "$TESTNAME FAIL" > "./$TESTNAME.res"
    exit 0
}

cd "$testpath" || exit 1
res_file="./$TESTNAME.res"
rm -f "$res_file"

log_info "------------------------------------------------------------"
log_info "Starting $TESTNAME Testcase"
log_info "Checking dependencies: bluetoothctl pgrep"

if ! check_dependencies bluetoothctl pgrep; then
    echo "$TESTNAME SKIP" > "$res_file"
    exit 0
fi

# -----------------------------
# 1. Ensure bluetoothd is running
# -----------------------------
log_info "Checking if bluetoothd is running..."
retry=0
MAX_RETRIES=3
RETRY_DELAY=5

while [ "$retry" -lt "$MAX_RETRIES" ]; do
    if pgrep bluetoothd >/dev/null 2>&1; then
        log_info "bluetoothd is running"
        break
    fi
    log_warn "bluetoothd not running, retrying in ${RETRY_DELAY}s..."
    sleep "$RETRY_DELAY"
    retry=$((retry + 1))
done

if [ "$retry" -eq "$MAX_RETRIES" ]; then
    log_fail "bluetoothd not detected after $MAX_RETRIES attempts."
    echo "$TESTNAME FAIL" > "$res_file"
    exit 0
fi

# -----------------------------
# 2. Detect adapter (CLI/ENV > auto-detect)
# -----------------------------
if [ -n "$BT_ADAPTER" ]; then
    ADAPTER="$BT_ADAPTER"
    log_info "Using adapter from BT_ADAPTER/CLI: $ADAPTER"
elif findhcisysfs >/dev/null 2>&1; then
    ADAPTER="$(findhcisysfs 2>/dev/null || true)"
else
    ADAPTER=""
fi

if [ -n "$ADAPTER" ]; then
    if [ -n "$BT_ADAPTER" ]; then
        bt_log_selected_adapter "$ADAPTER" "BT_ADAPTER/CLI"
    else
        bt_log_selected_adapter "$ADAPTER" "auto-detect"
    fi
fi

if [ -n "$ADAPTER" ]; then
    log_info "Using adapter: $ADAPTER"
else
    log_warn "No HCI adapter found; skipping test."
    echo "$TESTNAME SKIP" > "$res_file"
    exit 0
fi

# -----------------------------
# 3. Ensure controller is visible
# -----------------------------
if ! bt_ensure_controller_visible "$ADAPTER"; then
    log_warn "SKIP — controller not visible to bluetoothctl."
    echo "$TESTNAME SKIP" > "$res_file"
    exit 0
fi

# -----------------------------
# 4. Ensure power is ON
# -----------------------------
pw="$(btgetpower "$ADAPTER" 2>/dev/null || true)"
if [ "$pw" = "yes" ]; then
    log_pass "Power ON verified before scan."
else
    log_info "Controller Power=$pw — enabling now..."
    if ! btpower "$ADAPTER" on; then
        log_fail "Failed to power ON controller."
        echo "$TESTNAME FAIL" > "$res_file"
        exit 0
    fi
    log_pass "Power ON successful."
fi

# -----------------------------
# 5. Determine scan target MAC
# -----------------------------
TARGET_MAC="${BT_SCAN_TARGET_MAC:-$BT_TARGET_MAC}"

if [ -n "$TARGET_MAC" ]; then
    log_info "Target MAC provided: $TARGET_MAC — will validate its presence after scan."
else
    log_info "No target MAC provided, BT_SCAN will check for generic device visibility."
fi

# -----------------------------
# 6. Scan using common Bluetooth helper
# -----------------------------
log_info "Testing Bluetooth scan..."
log_info "Scan config: BT_SCAN_SECONDS=${BT_SCAN_SECONDS} BT_SCAN_RETRIES=${BT_SCAN_RETRIES} BT_SCAN_RETRY_DELAY=${BT_SCAN_RETRY_DELAY}"

SCAN_SECONDS="$BT_SCAN_SECONDS"
SCAN_ATTEMPTS="$BT_SCAN_RETRIES"
SCAN_RETRY_DELAY="$BT_SCAN_RETRY_DELAY"
MAC_ID="$TARGET_MAC"
BT_ADAPTER="$ADAPTER"

export SCAN_SECONDS
export SCAN_ATTEMPTS
export SCAN_RETRY_DELAY
export MAC_ID
export BT_ADAPTER

if bt_scan_devices "$TARGET_MAC"; then
    dstate_on="$(bt_get_discovering 2>/dev/null || true)"
    [ -z "$dstate_on" ] && dstate_on="unknown"
    log_info "Discovering state after scan attempts: $dstate_on"

    if [ -n "$TARGET_MAC" ]; then
        log_pass "Target MAC $TARGET_MAC detected."
    else
        log_pass "At least one Bluetooth device discovered."
    fi
else
    dstate_on="$(bt_get_discovering 2>/dev/null || true)"
    [ -z "$dstate_on" ] && dstate_on="unknown"
    log_info "Discovering state after failed scan attempts: $dstate_on"

    if [ -n "$TARGET_MAC" ]; then
        log_fail "Target MAC $TARGET_MAC missing after scan attempts."
    else
        log_fail "No Bluetooth devices discovered after scan attempts."
    fi

    echo "$TESTNAME FAIL" > "$res_file"
    exit 0
fi

# -----------------------------
# 8. Scan OFF via helper + Discovering check
# -----------------------------
log_info "Testing scan OFF..."
if ! bt_set_scan off "$ADAPTER"; then
    # bt_set_scan(off) can be flaky on minimal images; rely on poll helper
    log_warn "bt_set_scan(off) returned non-zero; continuing with scan-off polling."
fi

# Use lib helper to avoid repetitive log spam and handle 'unknown' cleanly.
if bt_scan_poll_off 10 1; then
    # On minimal/ramdisk images bt_scan_poll_off may treat persistent 'unknown' as non-fatal.
    log_pass "Scan OFF cleanup completed."
else
    # If you keep bt_scan_poll_off strict, this may still warn; not a test failure.
    log_warn "Scan OFF cleanup did not confirm Discovering=no (non-fatal)."
fi

echo "$TESTNAME PASS" > "$res_file"
exit 0

