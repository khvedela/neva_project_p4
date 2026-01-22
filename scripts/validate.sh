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
SKIP_TCPDUMP=${SKIP_TCPDUMP:-0}
TCPDUMP_COUNT=${TCPDUMP_COUNT:-}
TCPDUMP_SNAPLEN=${TCPDUMP_SNAPLEN:-}
IPERF_PORT=${IPERF_PORT:-5201}
IPERF_CONNECT_TIMEOUT_MS=${IPERF_CONNECT_TIMEOUT_MS:-3000}
IPERF_CLIENT_TIMEOUT=${IPERF_CLIENT_TIMEOUT:-}
SERVER_WAIT_SECS=${SERVER_WAIT_SECS:-2}

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

log "iface=$IFACE server=$SERVER_ADDR duration=$DURATION baseline=$BASELINE_THRESHOLD drop=$DROP_THRESHOLD"
log "results_dir=$OUT_DIR map=$MAP_PATH"
log "tcpdump_skip=$SKIP_TCPDUMP tcpdump_count=${TCPDUMP_COUNT:-none} snaplen=${TCPDUMP_SNAPLEN:-default}"
log "iperf_port=$IPERF_PORT connect_timeout_ms=$IPERF_CONNECT_TIMEOUT_MS client_timeout=${IPERF_CLIENT_TIMEOUT:-auto}"

export CONGESTION_MAP_PATH="$MAP_PATH"

is_port_listening() {
    local port="$1"
    if ! have ss; then
        return 1
    fi
    ss -ltn "sport = :$port" | awk 'NR>1 {print $1}' | grep -q LISTEN
}

select_iperf_port() {
    if ! have ss; then
        return 0
    fi
    local start="$IPERF_PORT"
    local end=$((start + 9))
    local candidate
    for candidate in $(seq "$start" "$end"); do
        if ! is_port_listening "$candidate"; then
            if [ "$candidate" != "$IPERF_PORT" ]; then
                warn "port $IPERF_PORT is in use; switching to $candidate"
                IPERF_PORT="$candidate"
            fi
            return 0
        fi
    done
    warn "ports $start-$end are busy; set IPERF_PORT to a free port"
    return 1
}

select_iperf_port || exit 1

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
    if [ "$SKIP_TCPDUMP" = "1" ]; then
        warn "tcpdump disabled; creating placeholder $pcap_file"
        : > "$pcap_file"
        echo ""
        return
    fi
    if have tcpdump; then
        local args=(-i "$IFACE" -w "$pcap_file")
        if [ -n "$TCPDUMP_SNAPLEN" ]; then
            args+=(-s "$TCPDUMP_SNAPLEN")
        fi
        if [ -n "$TCPDUMP_COUNT" ]; then
            args+=(-c "$TCPDUMP_COUNT")
        fi
        tcpdump "${args[@]}" >/dev/null 2>&1 &
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

wait_for_server() {
    if ! have ss; then
        return 0
    fi
    local attempts
    attempts=$((SERVER_WAIT_SECS * 5))
    if [ "$attempts" -lt 1 ]; then
        attempts=1
    fi
    for _ in $(seq 1 "$attempts"); do
        if ss -ltn "sport = :$IPERF_PORT" | awk 'NR>1 {print $1}' | grep -q LISTEN; then
            return 0
        fi
        sleep 0.2
    done
    return 1
}

run_iperf_client() {
    local iperf_out="$1"
    local timeout_cmd=()
    local client_timeout="${IPERF_CLIENT_TIMEOUT}"
    if [ -z "$client_timeout" ]; then
        client_timeout=$((DURATION + 5))
    fi
    if have timeout; then
        timeout_cmd=(timeout "$client_timeout")
    fi
    if ! "${timeout_cmd[@]}" iperf3 -c "$SERVER_ADDR" -p "$IPERF_PORT" \
        -t "$DURATION" --connect-timeout "$IPERF_CONNECT_TIMEOUT_MS" > "$iperf_out" 2>&1; then
        return 1
    fi
    return 0
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
    if [ -n "$tcpdump_pid" ]; then
        log "tcpdump started (pid $tcpdump_pid)"
    fi
    pidstat_pid=$(start_pidstat "$cpu_file")
    if [ -n "$pidstat_pid" ]; then
        log "pidstat started (pid $pidstat_pid)"
    fi

    iperf3 -s -1 -p "$IPERF_PORT" > "$OUT_DIR/${label}_server.txt" 2>&1 &
    local server_pid=$!
    log "iperf3 server started (pid $server_pid)"
    if ! kill -0 "$server_pid" >/dev/null 2>&1; then
        warn "iperf3 server exited early; see ${label}_server.txt"
        return
    fi
    if ! wait_for_server; then
        warn "iperf3 server not listening on port $IPERF_PORT"
    fi

    log "iperf3 client running for $DURATION seconds"
    if ! run_iperf_client "$iperf_out"; then
        warn "iperf3 client failed for $label"
    fi

    wait "$server_pid" >/dev/null 2>&1 || true
    stop_bg "$tcpdump_pid"
    stop_bg "$pidstat_pid"
    log "captures stopped for $label"

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
