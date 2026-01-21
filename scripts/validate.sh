#!/usr/bin/env bash
set -euo pipefail

IFACE=${IFACE:-lo}
SERVER_ADDR=${SERVER_ADDR:-127.0.0.1}
DURATION=${DURATION:-10}
BASELINE_THRESHOLD=${BASELINE_THRESHOLD:-1000000}
DROP_THRESHOLD=${DROP_THRESHOLD:-1000}
RESULTS_ROOT=${RESULTS_ROOT:-results}
MAP_PATH=${CONGESTION_MAP_PATH:-/sys/fs/bpf/tc/globals/congestion_reg}
CONTROLLER=${CONTROLLER:-controller/controller.py}

log() {
    echo "[validate] $*"
}

warn() {
    echo "[validate] Warning: $*" >&2
}

have() {
    command -v "$1" >/dev/null 2>&1
}

require_cmd() {
    if ! have "$1"; then
        echo "[validate] Error: required command '$1' not found" >&2
        exit 1
    fi
}

require_cmd iperf3
require_cmd python3

if [ ! -f "$CONTROLLER" ]; then
    echo "[validate] Error: controller not found at $CONTROLLER" >&2
    exit 1
fi

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
OUT_DIR="${RESULTS_ROOT}/results_${TIMESTAMP}"
mkdir -p "$OUT_DIR"

export CONGESTION_MAP_PATH="$MAP_PATH"

snapshot_tc() {
    if have tc; then
        {
            echo "== tc qdisc show =="
            tc qdisc show dev "$IFACE"
            echo
            echo "== tc filter show ingress =="
            tc filter show dev "$IFACE" ingress
        } > "$1"
    else
        warn "tc not found; skipping tc snapshot"
        echo "tc not available" > "$1"
    fi
}

snapshot_bpftool() {
    local out_file="$1"
    if have bpftool; then
        if [ -e "$MAP_PATH" ]; then
            {
                echo "== bpftool map show pinned =="
                bpftool map show pinned "$MAP_PATH"
                echo
                echo "== bpftool map dump pinned =="
                bpftool map dump pinned "$MAP_PATH"
            } > "$out_file"
        else
            warn "pinned map not found at $MAP_PATH"
            echo "pinned map not found at $MAP_PATH" > "$out_file"
        fi
    else
        warn "bpftool not found; skipping bpftool snapshot"
        echo "bpftool not available" > "$out_file"
    fi
}

reset_counter() {
    if have bpftool && [ -e "$MAP_PATH" ]; then
        bpftool map update pinned "$MAP_PATH" key hex 00 00 00 00 value hex 00 00 00 00 >/dev/null 2>&1 || \
            warn "failed to reset counter"
    fi
}

record_counts() {
    local label="$1"
    local counts
    if counts=$(python3 "$CONTROLLER" --get 2>/dev/null); then
        echo "$label: $counts" >> "$OUT_DIR/packet_counts.txt"
    else
        warn "failed to read counts for $label"
        echo "$label: error" >> "$OUT_DIR/packet_counts.txt"
    fi
}

start_tcpdump() {
    local pcap_file="$1"
    if have tcpdump; then
        tcpdump -i "$IFACE" -w "$pcap_file" >/dev/null 2>&1 &
        echo $!
    else
        warn "tcpdump not found; creating placeholder $pcap_file"
        : > "$pcap_file"
        echo ""
    fi
}

start_pidstat() {
    local cpu_file="$1"
    if have pidstat; then
        pidstat 1 > "$cpu_file" &
        echo $!
    else
        warn "pidstat not found; creating placeholder $cpu_file"
        echo "pidstat not available" > "$cpu_file"
        echo ""
    fi
}

stop_bg() {
    local pid="$1"
    if [ -n "$pid" ]; then
        kill -INT "$pid" >/dev/null 2>&1 || true
        wait "$pid" >/dev/null 2>&1 || true
    fi
}

run_test() {
    local label="$1"
    local threshold="$2"
    local pcap_file="$3"
    local cpu_file="$4"
    local iperf_out="$5"

    log "setting threshold to $threshold for $label"
    python3 "$CONTROLLER" --set-threshold "$threshold" >/dev/null

    reset_counter
    record_counts "${label}_before"

    local tcpdump_pid=""
    local pidstat_pid=""

    tcpdump_pid=$(start_tcpdump "$pcap_file")
    pidstat_pid=$(start_pidstat "$cpu_file")

    iperf3 -s -1 > "$OUT_DIR/${label}_server.txt" 2>&1 &
    local server_pid=$!
    sleep 1

    if ! iperf3 -c "$SERVER_ADDR" -t "$DURATION" > "$iperf_out" 2>&1; then
        warn "iperf3 client failed for $label"
    fi

    wait "$server_pid" >/dev/null 2>&1 || true
    stop_bg "$tcpdump_pid"
    stop_bg "$pidstat_pid"

    record_counts "${label}_after"
}

snapshot_tc "$OUT_DIR/tc_before.txt"
snapshot_bpftool "$OUT_DIR/bpftool_before.txt"

run_test "baseline" "$BASELINE_THRESHOLD" "$OUT_DIR/baseline.pcap" \
    "$OUT_DIR/cpu_baseline.txt" "$OUT_DIR/iperf_baseline.txt"

run_test "drop" "$DROP_THRESHOLD" "$OUT_DIR/drop.pcap" \
    "$OUT_DIR/cpu_drop.txt" "$OUT_DIR/iperf_drop.txt"

snapshot_tc "$OUT_DIR/tc_after.txt"
snapshot_bpftool "$OUT_DIR/bpftool_after.txt"

log "results saved to $OUT_DIR"
