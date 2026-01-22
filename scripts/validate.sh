#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

IFACE=${IFACE:-lo}
SERVER_ADDR=${SERVER_ADDR:-127.0.0.1}
DURATION=${DURATION:-10}
BASELINE_THRESHOLD=${BASELINE_THRESHOLD:-100000000}
DROP_THRESHOLD=${DROP_THRESHOLD:-10000000}
AUTO_THRESHOLD=${AUTO_THRESHOLD:-1}
AUTO_THRESHOLD_FRACTION=${AUTO_THRESHOLD_FRACTION:-0.6}
AUTO_THRESHOLD_MIN=${AUTO_THRESHOLD_MIN:-1000}
RESULTS_ROOT=${RESULTS_ROOT:-results}
MAP_PATH=${CONGESTION_MAP_PATH:-/sys/fs/bpf/tc/globals/congestion_reg}
MAP_NAME=${MAP_NAME:-congestion_reg}
CONTROLLER=${CONTROLLER:-controller/controller.py}
SKIP_TCPDUMP=${SKIP_TCPDUMP:-0}
TCPDUMP_COUNT=${TCPDUMP_COUNT:-20000}
TCPDUMP_SNAPLEN=${TCPDUMP_SNAPLEN:-96}
TCPDUMP_FILTER=${TCPDUMP_FILTER:-}
SKIP_PIDSTAT=${SKIP_PIDSTAT:-0}
IPERF_PORT=${IPERF_PORT:-5201}
IPERF_PORT_RANGE=${IPERF_PORT_RANGE:-10}
IPERF_CONNECT_TIMEOUT_MS=${IPERF_CONNECT_TIMEOUT_MS:-3000}
IPERF_CLIENT_TIMEOUT=${IPERF_CLIENT_TIMEOUT:-}
SERVER_WAIT_SECS=${SERVER_WAIT_SECS:-2}
KILL_IPERF=${KILL_IPERF:-1}
AUTO_ATTACH=${AUTO_ATTACH:-1}
ATTACH_OBJ=${ATTACH_OBJ:-ebpf/build/main.o}
ATTACH_SECTION=${ATTACH_SECTION:-}
ATTACH_SCRIPT=${ATTACH_SCRIPT:-${SCRIPT_DIR}/attach_tc.sh}
EXPECT_ROOT=${EXPECT_ROOT:-1}
NO_COLOR=${NO_COLOR:-}
LOG_SYSTEM=${LOG_SYSTEM:-1}

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
OUT_DIR="${RESULTS_ROOT}/results_${TIMESTAMP}"
mkdir -p "$OUT_DIR"
LOG_FILE="$OUT_DIR/validate.log"
: > "$LOG_FILE"
: > "$OUT_DIR/packet_counts.txt"

use_color=1
if [ -n "$NO_COLOR" ] || [ ! -t 1 ]; then
    use_color=0
fi

if [ "$use_color" -eq 1 ]; then
    C_RESET="\033[0m"
    C_RED="\033[31m"
    C_GREEN="\033[32m"
    C_YELLOW="\033[33m"
    C_BLUE="\033[34m"
    C_CYAN="\033[36m"
    C_BOLD="\033[1m"
else
    C_RESET=""
    C_RED=""
    C_GREEN=""
    C_YELLOW=""
    C_BLUE=""
    C_CYAN=""
    C_BOLD=""
fi

ts() {
    date "+%H:%M:%S"
}

log_line() {
    local level="$1"
    shift
    local msg="$*"
    local prefix="[$(ts)] [validate] [$level]"
    local color="$C_BLUE"
    case "$level" in
        WARN) color="$C_YELLOW" ;;
        ERROR) color="$C_RED" ;;
        OK) color="$C_GREEN" ;;
        STEP) color="$C_BOLD$C_CYAN" ;;
        *) color="$C_BLUE" ;;
    esac
    echo -e "${color}${prefix} ${msg}${C_RESET}"
    echo "${prefix} ${msg}" >> "$LOG_FILE"
}

info() { log_line INFO "$*"; }
warn() { log_line WARN "$*"; }
error() { log_line ERROR "$*"; exit 1; }
step() { log_line STEP "$*"; }

have() {
    command -v "$1" >/dev/null 2>&1
}

require_cmd() {
    if ! have "$1"; then
        error "required command '$1' not found in PATH"
    fi
}

ensure_linux() {
    if [ "$(uname -s)" != "Linux" ]; then
        error "this script must run on Linux"
    fi
}

ensure_root() {
    if [ "$EXPECT_ROOT" = "1" ] && [ "$(id -u)" -ne 0 ]; then
        error "run with sudo (root required for tc/bpf)"
    fi
}

ensure_iface() {
    if have ip; then
        if ! ip link show "$IFACE" >/dev/null 2>&1; then
            error "network interface '$IFACE' not found"
        fi
    else
        warn "ip command not found; skipping interface check"
    fi
}

TCPDUMP_FILTER_DEFAULT="tcp and port ${IPERF_PORT}"

is_port_listening() {
    local port="$1"
    if have ss; then
        ss -ltn "sport = :$port" | awk 'NR>1 {print $1}' | grep -q LISTEN
        return $?
    fi
    if have lsof; then
        lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1
        return $?
    fi
    if have netstat; then
        netstat -ltn 2>/dev/null | awk '{print $4}' | grep -q ":$port$"
        return $?
    fi
    return 1
}

select_iperf_port() {
    local start="$IPERF_PORT"
    local end=$((start + IPERF_PORT_RANGE - 1))
    local candidate

    if ! have ss && ! have lsof && ! have netstat; then
        warn "no ss/lsof/netstat; skipping port availability check"
        return 0
    fi

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

wait_for_server() {
    local attempts
    attempts=$((SERVER_WAIT_SECS * 5))
    if [ "$attempts" -lt 1 ]; then
        attempts=1
    fi

    for _ in $(seq 1 "$attempts"); do
        if is_port_listening "$IPERF_PORT"; then
            return 0
        fi
        sleep 0.2
    done
    return 1
}

run_with_timeout() {
    local timeout_secs="$1"
    shift

    if have timeout; then
        timeout "$timeout_secs" "$@"
        return $?
    fi

    "$@" &
    local cmd_pid=$!
    local watcher_pid=""

    (
        sleep "$timeout_secs"
        kill -INT "$cmd_pid" >/dev/null 2>&1 || true
    ) &
    watcher_pid=$!

    wait "$cmd_pid"
    local status=$?

    kill -INT "$watcher_pid" >/dev/null 2>&1 || true
    wait "$watcher_pid" >/dev/null 2>&1 || true

    return $status
}

stop_bg() {
    local pid="$1"
    if [ -z "$pid" ]; then
        return 0
    fi
    kill -INT "$pid" >/dev/null 2>&1 || true

    if have timeout; then
        timeout 2s bash -c "wait $pid" >/dev/null 2>&1 || true
    else
        for _ in $(seq 1 20); do
            if ! kill -0 "$pid" >/dev/null 2>&1; then
                break
            fi
            sleep 0.1
        done
    fi

    kill -KILL "$pid" >/dev/null 2>&1 || true
    wait "$pid" >/dev/null 2>&1 || true
}

TCPDUMP_PID=""
PIDSTAT_PID=""
SERVER_PID=""

cleanup_on_exit() {
    stop_bg "$TCPDUMP_PID"
    stop_bg "$PIDSTAT_PID"
    stop_bg "$SERVER_PID"
}
trap cleanup_on_exit EXIT INT TERM

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

COUNTER_BASELINE_BEFORE=""
COUNTER_BASELINE_AFTER=""
COUNTER_DROP_BEFORE=""
COUNTER_DROP_AFTER=""

record_counts() {
    local label="$1"
    local counts
    if counts=$(python3 "$CONTROLLER" --get 2>/dev/null); then
        echo "$label: $counts" >> "$OUT_DIR/packet_counts.txt"
        local counter
        counter=$(echo "$counts" | sed -n 's/.*counter=\([0-9][0-9]*\).*/\1/p')
        case "$label" in
            baseline_before) COUNTER_BASELINE_BEFORE="$counter" ;;
            baseline_after) COUNTER_BASELINE_AFTER="$counter" ;;
            drop_before) COUNTER_DROP_BEFORE="$counter" ;;
            drop_after) COUNTER_DROP_AFTER="$counter" ;;
            *) : ;;
        esac
    else
        warn "failed to read counts for $label"
        echo "$label: error" >> "$OUT_DIR/packet_counts.txt"
    fi
}

log_map_state() {
    local label="$1"
    local state
    if state=$(python3 "$CONTROLLER" --get 2>/dev/null); then
        info "$label map: $state"
    else
        warn "failed to read map after $label"
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
        local filter="$TCPDUMP_FILTER"
        if [ -z "$filter" ]; then
            filter="$TCPDUMP_FILTER_DEFAULT"
        fi
        if [ -n "$filter" ]; then
            args+=($filter)
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
    if [ "$SKIP_PIDSTAT" = "1" ]; then
        warn "pidstat disabled; creating placeholder $cpu_file"
        echo "pidstat disabled" > "$cpu_file"
        echo ""
        return
    fi
    if have pidstat; then
        pidstat 1 > "$cpu_file" &
        echo $!
    else
        warn "pidstat not found; creating placeholder $cpu_file"
        echo "pidstat not available" > "$cpu_file"
        echo ""
    fi
}

start_iperf_server() {
    local label="$1"
    local server_log="$2"
    local start_port="$IPERF_PORT"
    local end_port=$((start_port + IPERF_PORT_RANGE - 1))

    for port in $(seq "$start_port" "$end_port"); do
        if [ "$port" != "$IPERF_PORT" ]; then
            IPERF_PORT="$port"
            info "trying iperf3 server on port $IPERF_PORT"
        fi
        iperf3 -s -1 -p "$IPERF_PORT" > "$server_log" 2>&1 &
        local pid=$!
        if ! kill -0 "$pid" >/dev/null 2>&1; then
            warn "iperf3 server exited early; see $server_log"
            wait "$pid" >/dev/null 2>&1 || true
            continue
        fi
        SERVER_PID="$pid"
        if wait_for_server; then
            return 0
        fi
        warn "iperf3 server not listening on port $IPERF_PORT"
        stop_bg "$pid"
        SERVER_PID=""
    done

    warn "unable to start iperf3 server for $label"
    return 1
}

run_iperf_client() {
    local json_out="$1"
    local txt_out="$2"

    local client_timeout="${IPERF_CLIENT_TIMEOUT}"
    if [ -z "$client_timeout" ]; then
        client_timeout=$((DURATION + 10))
    fi

    local status=0
    if ! run_with_timeout "$client_timeout" iperf3 -c "$SERVER_ADDR" -p "$IPERF_PORT" \
        -t "$DURATION" --connect-timeout "$IPERF_CONNECT_TIMEOUT_MS" --json > "$json_out" 2>&1; then
        status=1
    fi

    python3 - "$json_out" "$txt_out" <<'PY'
import json
import sys
from pathlib import Path

json_path = Path(sys.argv[1])
out_path = Path(sys.argv[2])

try:
    data = json.loads(json_path.read_text())
except Exception:
    out_path.write_text("iperf3 json parse failed\n")
    sys.exit(0)

if "error" in data:
    out_path.write_text(f"iperf3 error: {data['error']}\n")
    sys.exit(0)

end = data.get("end", {})
sent = end.get("sum_sent", {})
recv = end.get("sum_received", {})

bits = sent.get("bits_per_second") or recv.get("bits_per_second")
retrans = sent.get("retransmits", 0)
duration = end.get("sum_sent", {}).get("seconds") or end.get("sum_received", {}).get("seconds")

if bits is None:
    out_path.write_text("iperf3 json missing throughput\n")
    sys.exit(0)

mbps = bits / 1_000_000.0
summary = [
    f"sender: {mbps:.2f} Mbits/sec",
    f"retransmits: {retrans}",
]
if duration:
    summary.append(f"seconds: {duration}")

out_path.write_text("\n".join(summary) + "\n")
PY

    return $status
}

ensure_prereqs() {
    ensure_linux
    ensure_root
    require_cmd iperf3
    require_cmd python3
    require_cmd bpftool
    if [ ! -f "$CONTROLLER" ]; then
        error "controller not found at $CONTROLLER"
    fi
    if [ "$AUTO_ATTACH" = "1" ] && ! have tc; then
        error "tc not found; required for auto-attach"
    fi
    if [ ! -d "$RESULTS_ROOT" ]; then
        mkdir -p "$RESULTS_ROOT"
    fi
    ensure_iface
}

record_system_info() {
    if [ "$LOG_SYSTEM" != "1" ]; then
        return 0
    fi
    {
        echo "== uname =="
        uname -a
        echo
        echo "== ip link =="
        if have ip; then
            ip link show
        else
            echo "ip not available"
        fi
        echo
        echo "== iperf3 version =="
        iperf3 --version 2>/dev/null | head -n1 || echo "iperf3 version unavailable"
        echo
        echo "== bpftool version =="
        bpftool version 2>/dev/null || echo "bpftool version unavailable"
    } > "$OUT_DIR/system.txt"
}

ensure_map_ready() {
    if [ -e "$MAP_PATH" ]; then
        return 0
    fi
    if [ "$AUTO_ATTACH" = "1" ]; then
        warn "pinned map not found at $MAP_PATH"
        info "auto-attach is enabled; attempting to attach program"
        if [ ! -x "$ATTACH_SCRIPT" ]; then
            error "attach script not found or not executable at $ATTACH_SCRIPT"
        fi
        IFACE="$IFACE" OBJ="$ATTACH_OBJ" SECTION="$ATTACH_SECTION" MAP_PATH="$MAP_PATH" MAP_NAME="$MAP_NAME" \
            "$ATTACH_SCRIPT"
    fi
    if [ ! -e "$MAP_PATH" ]; then
        error "pinned map still not found at $MAP_PATH"
    fi
}

write_meta() {
    python3 - "$OUT_DIR/meta.json" <<'PY'
import json
import os
import platform
import time
import sys

meta = {
    "timestamp": time.strftime("%Y-%m-%d %H:%M:%S"),
    "iface": os.environ.get("IFACE"),
    "server_addr": os.environ.get("SERVER_ADDR"),
    "duration": int(os.environ.get("DURATION", "0") or 0),
    "baseline_threshold": int(os.environ.get("BASELINE_THRESHOLD", "0") or 0),
    "drop_threshold": int(os.environ.get("DROP_THRESHOLD", "0") or 0),
    "iperf_port": int(os.environ.get("IPERF_PORT", "0") or 0),
    "map_path": os.environ.get("MAP_PATH"),
    "map_name": os.environ.get("MAP_NAME"),
    "auto_threshold": os.environ.get("AUTO_THRESHOLD"),
    "auto_threshold_fraction": os.environ.get("AUTO_THRESHOLD_FRACTION"),
    "tcpdump_count": os.environ.get("TCPDUMP_COUNT"),
    "tcpdump_snaplen": os.environ.get("TCPDUMP_SNAPLEN"),
    "skip_tcpdump": os.environ.get("SKIP_TCPDUMP"),
    "kernel": platform.uname().release,
}

with open(sys.argv[1], "w", encoding="utf-8") as fh:
    json.dump(meta, fh, indent=2)
PY
}

run_test() {
    local label="$1"
    local threshold="$2"
    local pcap_file="$3"
    local cpu_file="$4"
    local iperf_json="$5"
    local iperf_txt="$6"

    step "${label}: configuring threshold"
    python3 "$CONTROLLER" --set-threshold "$threshold" >/dev/null
    log_map_state "$label"

    reset_counter
    record_counts "${label}_before"

    if ! start_iperf_server "$label" "$OUT_DIR/${label}_server.txt"; then
        warn "skipping iperf3 client; server failed to start"
        echo "iperf3 server failed to start" > "$iperf_txt"
        echo "{\"error\": \"server failed to start\"}" > "$iperf_json"
        return 1
    fi

    if [ -z "$TCPDUMP_FILTER" ]; then
        TCPDUMP_FILTER_DEFAULT="tcp and port ${IPERF_PORT}"
    fi

    TCPDUMP_PID=$(start_tcpdump "$pcap_file")
    if [ -n "$TCPDUMP_PID" ]; then
        info "tcpdump started (pid $TCPDUMP_PID)"
    fi

    PIDSTAT_PID=$(start_pidstat "$cpu_file")
    if [ -n "$PIDSTAT_PID" ]; then
        info "pidstat started (pid $PIDSTAT_PID)"
    fi

    info "iperf3 client running for $DURATION seconds"
    if ! run_iperf_client "$iperf_json" "$iperf_txt"; then
        warn "iperf3 client failed for $label"
    fi

    stop_bg "$SERVER_PID"
    SERVER_PID=""

    stop_bg "$TCPDUMP_PID"
    stop_bg "$PIDSTAT_PID"
    TCPDUMP_PID=""
    PIDSTAT_PID=""

    info "captures stopped for $label"

    record_counts "${label}_after"
    return 0
}

step "preflight checks"
ensure_prereqs
record_system_info

if [ "$KILL_IPERF" = "1" ] && have pkill; then
    info "terminating any stale iperf3 processes"
    pkill -x iperf3 >/dev/null 2>&1 || true
fi

if ! select_iperf_port; then
    error "no free iperf port available"
fi

if [ -n "$TCPDUMP_FILTER" ]; then
    info "tcpdump filter: $TCPDUMP_FILTER"
else
    TCPDUMP_FILTER_DEFAULT="tcp and port ${IPERF_PORT}"
    info "tcpdump filter: ${TCPDUMP_FILTER_DEFAULT}"
fi

step "starting validation run"
info "iface=$IFACE server=$SERVER_ADDR duration=$DURATION baseline=$BASELINE_THRESHOLD drop=$DROP_THRESHOLD"
info "results_dir=$OUT_DIR map=$MAP_PATH"
info "log_file=$LOG_FILE system_info=$OUT_DIR/system.txt"
info "tcpdump_skip=$SKIP_TCPDUMP tcpdump_count=${TCPDUMP_COUNT:-none} snaplen=${TCPDUMP_SNAPLEN:-default}"
info "iperf_port=$IPERF_PORT port_range=$IPERF_PORT_RANGE connect_timeout_ms=$IPERF_CONNECT_TIMEOUT_MS client_timeout=${IPERF_CLIENT_TIMEOUT:-auto}"

export CONGESTION_MAP_PATH="$MAP_PATH"

auto_attach_note="disabled"
if [ "$AUTO_ATTACH" = "1" ]; then
    auto_attach_note="enabled"
fi
info "auto_attach=$auto_attach_note"

ensure_map_ready

snapshot_tc "$OUT_DIR/tc_before.txt"
snapshot_bpftool "$OUT_DIR/bpftool_before.txt"

run_test "baseline" "$BASELINE_THRESHOLD" "$OUT_DIR/baseline.pcap" \
    "$OUT_DIR/cpu_baseline.txt" "$OUT_DIR/iperf_baseline.json" "$OUT_DIR/iperf_baseline.txt" || true

if [ "$AUTO_THRESHOLD" = "1" ] && [ -n "$COUNTER_BASELINE_BEFORE" ] && [ -n "$COUNTER_BASELINE_AFTER" ]; then
    baseline_delta=$((COUNTER_BASELINE_AFTER - COUNTER_BASELINE_BEFORE))
    if [ "$baseline_delta" -gt "$AUTO_THRESHOLD_MIN" ]; then
        computed_drop=$(python3 - "$baseline_delta" "$AUTO_THRESHOLD_FRACTION" <<'PY'
import sys
baseline = int(sys.argv[1])
fraction = float(sys.argv[2])
print(max(1, int(baseline * fraction)))
PY
)
        info "auto-threshold: baseline_delta=$baseline_delta -> drop_threshold=$computed_drop"
        DROP_THRESHOLD="$computed_drop"
    else
        warn "auto-threshold skipped; baseline_delta too small ($baseline_delta)"
    fi
fi

export IFACE SERVER_ADDR DURATION BASELINE_THRESHOLD DROP_THRESHOLD IPERF_PORT
export MAP_PATH MAP_NAME AUTO_THRESHOLD AUTO_THRESHOLD_FRACTION
export TCPDUMP_COUNT TCPDUMP_SNAPLEN SKIP_TCPDUMP
write_meta

run_test "drop" "$DROP_THRESHOLD" "$OUT_DIR/drop.pcap" \
    "$OUT_DIR/cpu_drop.txt" "$OUT_DIR/iperf_drop.json" "$OUT_DIR/iperf_drop.txt" || true

snapshot_tc "$OUT_DIR/tc_after.txt"
snapshot_bpftool "$OUT_DIR/bpftool_after.txt"

info "results saved to $OUT_DIR"

if [ -n "$COUNTER_DROP_AFTER" ] && [ -n "$DROP_THRESHOLD" ]; then
    if [ "$COUNTER_DROP_AFTER" -ge "$DROP_THRESHOLD" ]; then
        info "drop phase reached threshold (counter=$COUNTER_DROP_AFTER threshold=$DROP_THRESHOLD)"
    else
        warn "drop phase did not reach threshold (counter=$COUNTER_DROP_AFTER threshold=$DROP_THRESHOLD)"
    fi
fi
