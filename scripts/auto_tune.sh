#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

IFACE=${IFACE:-lo}
SERVER_ADDR=${SERVER_ADDR:-127.0.0.1}
MAP_PATH=${CONGESTION_MAP_PATH:-/sys/fs/bpf/tc/globals/congestion_reg}
MAP_NAME=${MAP_NAME:-congestion_reg}
CONTROLLER=${CONTROLLER:-controller/controller.py}
DURATION=${DURATION:-4}
BASELINE_THRESHOLD=${BASELINE_THRESHOLD:-1000000000}
DROP_FRACTION=${DROP_FRACTION:-0.97}
IPERF_PORT=${IPERF_PORT:-5202}
IPERF_PORT_RANGE=${IPERF_PORT_RANGE:-1}
IPERF_CONNECT_TIMEOUT_MS=${IPERF_CONNECT_TIMEOUT_MS:-3000}
IPERF_CLIENT_TIMEOUT=${IPERF_CLIENT_TIMEOUT:-12}
AUTO_ATTACH=${AUTO_ATTACH:-1}
ATTACH_SCRIPT=${ATTACH_SCRIPT:-${SCRIPT_DIR}/attach_tc.sh}
ATTACH_OBJ=${ATTACH_OBJ:-ebpf/build/main.o}
ATTACH_SECTION=${ATTACH_SECTION:-}
KILL_IPERF=${KILL_IPERF:-1}
OUT_DIR=${OUT_DIR:-results/tune_$(date +%Y%m%d_%H%M%S)}

log() {
    echo "[auto-tune] $*"
}

warn() {
    echo "[auto-tune] Warning: $*" >&2
}

error() {
    echo "[auto-tune] Error: $*" >&2
    exit 1
}

have() {
    command -v "$1" >/dev/null 2>&1
}

require_cmd() {
    if ! have "$1"; then
        error "required command '$1' not found"
    fi
}

if [ "$(uname -s)" != "Linux" ]; then
    error "this script must run on Linux"
fi

if [ "$(id -u)" -ne 0 ]; then
    error "run with sudo (root required for tc/bpf)"
fi

require_cmd iperf3
require_cmd python3
require_cmd bpftool

if [ ! -f "$CONTROLLER" ]; then
    error "controller not found at $CONTROLLER"
fi

mkdir -p "$OUT_DIR"

cleanup() {
    if [ -n "${SERVER_PID:-}" ]; then
        kill -INT "$SERVER_PID" >/dev/null 2>&1 || true
        wait "$SERVER_PID" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT INT TERM

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
    return 1
}

select_iperf_port() {
    local start="$IPERF_PORT"
    local end=$((start + IPERF_PORT_RANGE - 1))
    local candidate

    if ! have ss && ! have lsof; then
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

    error "ports $start-$end are busy; set IPERF_PORT to a free port"
}

wait_for_server() {
    local attempts=15
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
    local pid=$!
    (
        sleep "$timeout_secs"
        kill -INT "$pid" >/dev/null 2>&1 || true
    ) &
    local watcher=$!
    wait "$pid"
    local status=$?
    kill -INT "$watcher" >/dev/null 2>&1 || true
    wait "$watcher" >/dev/null 2>&1 || true
    return $status
}

if [ "$KILL_IPERF" = "1" ] && have pkill; then
    log "terminating any stale iperf3 processes"
    pkill -x iperf3 >/dev/null 2>&1 || true
fi

select_iperf_port

if [ ! -e "$MAP_PATH" ] && [ "$AUTO_ATTACH" = "1" ]; then
    log "pinned map missing; attempting auto-attach"
    IFACE="$IFACE" OBJ="$ATTACH_OBJ" SECTION="$ATTACH_SECTION" MAP_PATH="$MAP_PATH" MAP_NAME="$MAP_NAME" \
        "$ATTACH_SCRIPT"
fi

if [ ! -e "$MAP_PATH" ]; then
    error "pinned map not found at $MAP_PATH"
fi

export CONGESTION_MAP_PATH="$MAP_PATH"

log "baseline duration=${DURATION}s iperf_port=$IPERF_PORT drop_fraction=$DROP_FRACTION"

if ! python3 "$CONTROLLER" --set-threshold "$BASELINE_THRESHOLD" >/dev/null 2>&1; then
    error "failed to set baseline threshold"
fi

bpftool map update pinned "$MAP_PATH" key hex 00 00 00 00 value hex 00 00 00 00 >/dev/null 2>&1 || \
    warn "failed to reset counter"

before=$(python3 "$CONTROLLER" --get-counter 2>/dev/null || echo "")
if [ -z "$before" ]; then
    error "failed to read counter before baseline"
fi

iperf3 -s -1 -p "$IPERF_PORT" > "$OUT_DIR/iperf_server.txt" 2>&1 &
SERVER_PID=$!
if ! wait_for_server; then
    error "iperf3 server not listening on port $IPERF_PORT"
fi

client_timeout="$IPERF_CLIENT_TIMEOUT"
if ! run_with_timeout "$client_timeout" iperf3 -c "$SERVER_ADDR" -p "$IPERF_PORT" \
    -t "$DURATION" --connect-timeout "$IPERF_CONNECT_TIMEOUT_MS" > "$OUT_DIR/iperf_client.txt" 2>&1; then
    warn "iperf3 client returned non-zero; continuing anyway"
fi

wait "$SERVER_PID" >/dev/null 2>&1 || true

after=$(python3 "$CONTROLLER" --get-counter 2>/dev/null || echo "")
if [ -z "$after" ]; then
    error "failed to read counter after baseline"
fi

baseline_delta=$((after - before))
if [ "$baseline_delta" -le 0 ]; then
    error "baseline counter delta is not positive (${baseline_delta})"
fi

if python3 - "$DROP_FRACTION" <<'PY' >/dev/null 2>&1; then
import sys
v = float(sys.argv[1])
if v <= 0 or v >= 1:
    raise SystemExit(1)
PY
    :
else
    warn "DROP_FRACTION should be between 0 and 1 (got $DROP_FRACTION); using 0.97"
    DROP_FRACTION=0.97
fi

drop_threshold=$(python3 - "$baseline_delta" "$DROP_FRACTION" <<'PY'
import sys
baseline = int(sys.argv[1])
fraction = float(sys.argv[2])
value = max(1, int(baseline * fraction))
print(value)
PY
)

log "baseline_delta=${baseline_delta} -> drop_threshold=${drop_threshold}"

cat <<CMD

Recommended command for this machine:

sudo env DURATION=${DURATION} AUTO_THRESHOLD=0 DROP_THRESHOLD=${drop_threshold} \
IPERF_PORT=${IPERF_PORT} IPERF_PORT_RANGE=${IPERF_PORT_RANGE} \
IPERF_CLIENT_TIMEOUT=${IPERF_CLIENT_TIMEOUT} \
make validate IFACE=${IFACE}

Logs saved in: ${OUT_DIR}
CMD
