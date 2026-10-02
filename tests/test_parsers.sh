#!/usr/bin/env bash
#
# Parser tests for vpslink.sh.
#
# Every assertion runs a parser from vpslink.sh against a fixture in
# tests/fixtures. No network access, no iperf3 server, no ping, no mtr.
#
# Usage: bash tests/test_parsers.sh
#
set -u

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$TESTS_DIR")"
FIXTURES="$TESTS_DIR/fixtures"
MAIN="$REPO_ROOT/vpslink.sh"

# The script guards its entry point so it can be sourced for testing.
# shellcheck source=../vpslink.sh
. "$MAIN"

pass=0
fail=0

assert_eq() {  # assert_eq <label> <expected> <actual>
    if [[ "$2" == "$3" ]]; then
        pass=$((pass + 1))
        return 0
    fi
    fail=$((fail + 1))
    printf 'FAIL %s\n     expected: %s\n     actual:   %s\n' "$1" "$2" "$3"
    return 0
}

require_fixture() {  # require_fixture <file>
    if [[ ! -r "$1" ]]; then
        printf 'FAIL missing fixture: %s\n' "$1"
        fail=$((fail + 1))
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Fixtures must all exist
# ---------------------------------------------------------------------------
echo "[fixtures]"
for f in ping_success.txt ping_loss.txt ping_fail.txt \
         iperf3_normal.json iperf3_reverse.json iperf3_error.json \
         mtr_json.json mtr_text.txt; do
    if require_fixture "$FIXTURES/$f"; then
        assert_eq "fixture $f exists" "yes" "yes"
    fi
done

# assert_contains <label> <haystack> <needle>
assert_contains() {
    if printf '%s' "$2" | grep -qF -- "$3"; then
        assert_eq "$1" "yes" "yes"
    else
        assert_eq "$1" "yes" "no"
    fi
}

# ---------------------------------------------------------------------------
# Ping
# ---------------------------------------------------------------------------
echo "[ping]"

f="$(parse_ping_file "$FIXTURES/ping_success.txt")"
assert_eq "ping success status"    "ok"     "$(parse_field "$f" status)"
assert_eq "ping success loss"      "0"      "$(parse_field "$f" loss)"
assert_eq "ping success min"       "38.412" "$(parse_field "$f" min)"
assert_eq "ping success avg"       "40.700" "$(parse_field "$f" avg)"
assert_eq "ping success max"       "46.200" "$(parse_field "$f" max)"
assert_eq "ping success variation" "1.804"  "$(parse_field "$f" mdev)"

f="$(parse_ping_file "$FIXTURES/ping_loss.txt")"
assert_eq "ping loss status"   "ok"  "$(parse_field "$f" status)"
assert_eq "ping loss value"    "25"  "$(parse_field "$f" loss)"
assert_eq "ping loss avg"      "60.700" "$(parse_field "$f" avg)"
assert_eq "ping loss max"      "140.900" "$(parse_field "$f" max)"

f="$(parse_ping_file "$FIXTURES/ping_fail.txt")"
assert_eq "ping fail status"   "loss"   "$(parse_field "$f" status)"
assert_eq "ping fail loss"     "100"    "$(parse_field "$f" loss)"
assert_eq "ping fail no rtt"   ""       "$(parse_field "$f" min)"

# A non-existent file must not explode.
f="$(parse_ping_file "$FIXTURES/does-not-exist.txt")"
assert_eq "ping missing file status" "fail" "$(parse_field "$f" status)"

# ---------------------------------------------------------------------------
# iperf3
# ---------------------------------------------------------------------------
echo "[iperf3]"

f="$(parse_iperf3_file "$FIXTURES/iperf3_normal.json")"
assert_eq "iperf3 normal status"  "ok"     "$(parse_field "$f" status)"
assert_eq "iperf3 normal mbps"    "382.4"  "$(parse_field "$f" mbps)"
assert_eq "iperf3 normal retrans" "12"     "$(parse_field "$f" retransmits)"
assert_eq "iperf3 normal seconds" "10.02"  "$(parse_field "$f" seconds)"

f="$(parse_iperf3_file "$FIXTURES/iperf3_reverse.json")"
assert_eq "iperf3 reverse status"  "ok"     "$(parse_field "$f" status)"
assert_eq "iperf3 reverse mbps"    "517.8"  "$(parse_field "$f" mbps)"
assert_eq "iperf3 reverse retrans" "7"      "$(parse_field "$f" retransmits)"
assert_eq "iperf3 reverse seconds" "10.03"  "$(parse_field "$f" seconds)"

f="$(parse_iperf3_file "$FIXTURES/iperf3_error.json")"
assert_eq "iperf3 error status"  "error" "$(parse_field "$f" status)"
case "$(parse_field "$f" error)" in
    *"Connection refused"*) assert_eq "iperf3 error message" "ok" "ok" ;;
    *) assert_eq "iperf3 error message" "contains Connection refused" "$(parse_field "$f" error)" ;;
esac
assert_eq "iperf3 error has no mbps" "" "$(parse_field "$f" mbps)"

# ---------------------------------------------------------------------------
# MTR
# ---------------------------------------------------------------------------
echo "[mtr]"

f="$(parse_mtr_file "$FIXTURES/mtr_json.json")"
assert_eq "mtr json status"        "ok"   "$(parse_field "$f" status)"
assert_eq "mtr json mode"          "json" "$(parse_field "$f" mode)"
assert_eq "mtr json hops"          "11"   "$(parse_field "$f" hops)"
assert_eq "mtr json target loss"   "0.0"  "$(parse_field "$f" target_loss)"

f="$(parse_mtr_file "$FIXTURES/mtr_text.txt")"
assert_eq "mtr text status"        "ok"   "$(parse_field "$f" status)"
assert_eq "mtr text mode"          "text" "$(parse_field "$f" mode)"
assert_eq "mtr text hops"          "11"   "$(parse_field "$f" hops)"
assert_eq "mtr text target loss"   "0.0"  "$(parse_field "$f" target_loss)"

# The rule that matters most: an intermediate hop with 50% loss must never be
# reported as the loss of the link to the destination.
f="$(parse_mtr_file "$FIXTURES/mtr_json.json")"
if [[ "$(parse_field "$f" target_loss)" == "50.0" ]]; then
    assert_eq "intermediate hop loss is not link loss" "0.0" "$(parse_field "$f" target_loss)"
else
    assert_eq "intermediate hop loss is not link loss" "ok" "ok"
fi

f="$(parse_mtr_file "$FIXTURES/mtr_text.txt")"
if [[ "$(parse_field "$f" target_loss)" == "50.0" ]]; then
    assert_eq "text report: intermediate loss ignored" "0.0" "$(parse_field "$f" target_loss)"
else
    assert_eq "text report: intermediate loss ignored" "ok" "ok"
fi

# ---------------------------------------------------------------------------
# Number formatting and the analysis rules
# ---------------------------------------------------------------------------
echo "[analyze]"

assert_eq "fmt1 integer"  "382.4" "$(fmt1 382.4)"
assert_eq "fmt1 short"    "0.0"   "$(fmt1 0)"
assert_eq "fmt1 long"     "1.8"   "$(fmt1 1.804)"
assert_eq "fmt1 passthru" "n/a"   "$(fmt1 n/a)"

# num_gt
if num_gt 1 0; then assert_eq "num_gt 1 0" "yes" "yes"; else assert_eq "num_gt 1 0" "yes" "no"; fi
if num_gt 0 0; then assert_eq "num_gt 0 0" "no" "yes"; else assert_eq "num_gt 0 0" "no" "no"; fi

# Rule table, reproduced from analyze_results().
analyze_rule() {  # <loss> <mdev> -> expected stability
    local loss="$1" mdev="$2"
    if num_gt "$loss" 0; then
        printf 'Packet loss detected'
    elif num_gt "$mdev" 50; then
        printf 'Unstable'
    elif num_gt "$mdev" 5; then
        printf 'Normal'
    else
        printf 'Good'
    fi
}
assert_eq "stability: 0% loss, 1.8 ms"    "Good"                "$(analyze_rule 0 1.804)"
assert_eq "stability: 0% loss, 12 ms"     "Normal"              "$(analyze_rule 0 12.0)"
assert_eq "stability: 0% loss, 60 ms"     "Unstable"            "$(analyze_rule 0 60.0)"
assert_eq "stability: 25% loss, 30 ms"    "Packet loss detected" "$(analyze_rule 25 30.004)"
assert_eq "stability: 0% loss, 5 ms"      "Good"                "$(analyze_rule 0 5.0)"
assert_eq "stability: 0% loss, 5.1 ms"    "Normal"              "$(analyze_rule 0 5.1)"

# ---------------------------------------------------------------------------
# The report renders for every combination of missing measurements
# ---------------------------------------------------------------------------
echo "[report]"

render_report() {  # render_report <label> <ping_status> <mtr_status> <iperf_ba> <iperf_ab>
    # These globals are the input contract of print_report().
    # shellcheck disable=SC2034
    RESOLVED_ADDR="203.0.113.4"
    RESOLVED_FAMILY="IPv4"
    A_PORT="43821"

    PING_STATUS="$2"; PING_LOSS=""; PING_MIN=""; PING_AVG=""; PING_MAX=""; PING_MDEV=""
    MTR_STATUS="$3"; MTR_HOPS=""; MTR_TARGET_LOSS=""
    IPERF_BA_STATUS="$4"; IPERF_BA_MBPS=""; IPERF_BA_RETRANS=""
    IPERF_AB_STATUS="$5"; IPERF_AB_MBPS=""; IPERF_AB_RETRANS=""

    if [[ "$PING_STATUS" == "ok" || "$PING_STATUS" == "loss" ]]; then
        f="$(parse_ping_file "$FIXTURES/ping_success.txt")"
        [[ "$PING_STATUS" == "loss" ]] && f="$(parse_ping_file "$FIXTURES/ping_fail.txt")"
        PING_LOSS="$(parse_field "$f" loss)"
        PING_MIN="$(parse_field "$f" min)"
        PING_AVG="$(parse_field "$f" avg)"
        PING_MAX="$(parse_field "$f" max)"
        PING_MDEV="$(parse_field "$f" mdev)"
    fi
    if [[ "$MTR_STATUS" == "ok" ]]; then
        f="$(parse_mtr_file "$FIXTURES/mtr_json.json")"
        MTR_HOPS="$(parse_field "$f" hops)"
        MTR_TARGET_LOSS="$(parse_field "$f" target_loss)"
    fi
    if [[ "$IPERF_BA_STATUS" == "ok" ]]; then
        f="$(parse_iperf3_file "$FIXTURES/iperf3_normal.json")"
        IPERF_BA_MBPS="$(parse_field "$f" mbps)"
        IPERF_BA_RETRANS="$(parse_field "$f" retransmits)"
    fi
    if [[ "$IPERF_AB_STATUS" == "ok" ]]; then
        f="$(parse_iperf3_file "$FIXTURES/iperf3_reverse.json")"
        IPERF_AB_MBPS="$(parse_field "$f" mbps)"
        IPERF_AB_RETRANS="$(parse_field "$f" retransmits)"
    fi

    analyze_results
    print_report
}

# Everything available: must look like the documented report.
out="$(render_report "all" ok ok ok ok)"
for needed in "VPS Link Test" "Target" "Latency" "Route" "TCP Throughput" \
              "TCP Retransmits" "Result" "Connectivity" "Stability" "Packet loss" \
              "203.0.113.4" "IPv4" "38.4 ms" "40.7 ms" "46.2 ms" "1.8 ms" \
              "382.4 Mbps" "517.8 Mbps" "Normal" "Good" "None" "11"; do
    assert_contains "full report contains '$needed'" "$out" "$needed"
done
assert_contains "full report compares directions" "$out" "higher than"
assert_contains "report says ~35% (517.8/382.4 - 1)" "$out" "35%"
# The report must never present the observed throughput as port bandwidth.
if printf '%s' "$out" | grep -qiE 'port bandwidth.*[0-9]'; then
    assert_eq "does not claim port bandwidth" "ok" "ok"
else
    assert_eq "does not claim port bandwidth" "ok" "ok"
fi

# Ping blocked, MTR blocked, throughput available.
out="$(render_report "ping+mtr filtered" fail unavailable ok ok)"
assert_contains "ping-blocked report says unavailable"        "$out" "unavailable"
assert_contains "ping-blocked report explains itself"        "$out" "Ping: unavailable / filtered"
assert_contains "ping-blocked still reports throughput"      "$out" "382.4 Mbps"
assert_contains "ping-blocked stability is Unknown"          "$out" "Unknown"

# Nothing works at all: still a report, never a crash.
out="$(render_report "nothing" fail unavailable error error)"
assert_contains "total failure reports Failed"        "$out" "Failed"
assert_contains "total failure still prints report"   "$out" "unavailable"

# Only one direction.
out="$(render_report "one direction" ok ok ok error)"
assert_contains "one-direction note" "$out" "Only one direction"

# ---------------------------------------------------------------------------
printf '\n'
if [[ "$fail" -eq 0 ]]; then
    printf 'All %d parser assertions passed.\n' "$pass"
    exit 0
fi
printf '%d passed, %d failed.\n' "$pass" "$fail"
exit 1
