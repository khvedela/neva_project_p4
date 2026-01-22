#!/usr/bin/env bash
set -euo pipefail

IFACE=${IFACE:-lo}
OBJ=${OBJ:-ebpf/build/main.o}
SECTION=${SECTION:-}
MAP_PATH=${MAP_PATH:-/sys/fs/bpf/tc/globals/congestion_reg}
MAP_NAME=${MAP_NAME:-congestion_reg}
CLEAN_MAP=${CLEAN_MAP:-0}
STRICT_MAP=${STRICT_MAP:-1}
NO_COLOR=${NO_COLOR:-}

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
    local prefix="[$(ts)] [attach] [$level]"
    local color="$C_BLUE"
    case "$level" in
        WARN) color="$C_YELLOW" ;;
        ERROR) color="$C_RED" ;;
        OK) color="$C_GREEN" ;;
        STEP) color="$C_BOLD$C_CYAN" ;;
        *) color="$C_BLUE" ;;
    esac
    echo -e "${color}${prefix} ${msg}${C_RESET}"
}

info() { log_line INFO "$*"; }
warn() { log_line WARN "$*"; }
error() { log_line ERROR "$*"; exit 1; }
step() { log_line STEP "$*"; }

have() {
    command -v "$1" >/dev/null 2>&1
}

if [ "$(uname -s)" != "Linux" ]; then
    error "this script must run on Linux"
fi

if [ "$(id -u)" -ne 0 ]; then
    error "run with sudo (root required for tc/bpf)"
fi

if ! have tc; then
    error "tc not found in PATH"
fi

if [ ! -f "$OBJ" ]; then
    error "eBPF object not found at $OBJ"
fi

if have ip; then
    if ! ip link show "$IFACE" >/dev/null 2>&1; then
        error "network interface '$IFACE' not found"
    fi
else
    warn "ip command not found; skipping interface check"
fi

info "iface=$IFACE obj=$OBJ section=${SECTION:-auto} map=$MAP_PATH clean_map=$CLEAN_MAP"

if [ "$CLEAN_MAP" = "1" ] && [ -e "$MAP_PATH" ]; then
    warn "removing existing pinned map at $MAP_PATH"
    rm -f "$MAP_PATH" 2>/dev/null || true
fi

info "current qdisc:"
tc qdisc show dev "$IFACE" || true
info "current ingress filters:"
tc filter show dev "$IFACE" ingress || true

if ! tc qdisc show dev "$IFACE" | grep -q clsact; then
    info "adding clsact qdisc on $IFACE"
    tc qdisc add dev "$IFACE" clsact 2>/dev/null || true
else
    info "clsact already present on $IFACE"
fi

detect_section() {
    local obj="$1"
    local section=""

    if have llvm-objdump; then
        section=$(llvm-objdump -h "$obj" | awk 'NR>5 {print $2}' | \
            grep -E '^(tc|classifier|xdp|ingress|egress)$' | head -n1 || true)
    fi

    if [ -z "$section" ] && have readelf; then
        section=$(readelf -S "$obj" | awk '{print $2}' | tr -d '[]' | \
            grep -E '^(tc|classifier|xdp|ingress|egress)$' | head -n1 || true)
    fi

    if [ -z "$section" ] && have llvm-objdump; then
        section=$(llvm-objdump -h "$obj" | awk 'NR>5 {print $2}' | \
            grep -v '^\.' | grep -v -E '^(license|maps|BTF|BTF.ext)$' | head -n1 || true)
    fi

    if [ -z "$section" ] && have readelf; then
        section=$(readelf -S "$obj" | awk '{print $2}' | tr -d '[]' | \
            grep -v '^\.' | grep -v -E '^(license|maps|BTF|BTF.ext)$' | head -n1 || true)
    fi

    echo "$section"
}

if [ -z "$SECTION" ]; then
    SECTION=$(detect_section "$OBJ")
fi

if [ -z "$SECTION" ]; then
    SECTION="tc"
    warn "unable to detect section; defaulting to '$SECTION'"
fi

step "attaching section '$SECTION'"
if ! tc filter replace dev "$IFACE" ingress pref 1 handle 1 bpf da obj "$OBJ" sec "$SECTION"; then
    warn "tc filter replace failed; trying delete+add"
    tc filter del dev "$IFACE" ingress 2>/dev/null || true
    tc filter add dev "$IFACE" ingress pref 1 handle 1 bpf da obj "$OBJ" sec "$SECTION"
fi

pin_map_if_missing() {
    if [ -e "$MAP_PATH" ]; then
        return 0
    fi
    if ! have bpftool; then
        warn "bpftool not found; cannot pin map"
        return 0
    fi
    local map_id
    map_id=$(bpftool -j map show 2>/dev/null | python3 - "$MAP_NAME" <<'PY'
import json
import sys

name = sys.argv[1]
try:
    data = json.load(sys.stdin)
except json.JSONDecodeError:
    sys.exit(1)

matches = [m for m in data if m.get("name") == name]
if not matches:
    sys.exit(1)

matches.sort(key=lambda m: m.get("id", 0))
print(matches[-1].get("id", ""))
PY
)
    if [ -n "$map_id" ]; then
        mkdir -p "$(dirname "$MAP_PATH")"
        if bpftool map pin id "$map_id" "$MAP_PATH" >/dev/null 2>&1; then
            info "pinned map '$MAP_NAME' at $MAP_PATH"
        else
            warn "failed to pin map '$MAP_NAME' (id $map_id)"
        fi
    else
        warn "map '$MAP_NAME' not found for pinning"
    fi
}

pin_map_if_missing

if [ "$STRICT_MAP" = "1" ] && [ ! -e "$MAP_PATH" ]; then
    error "pinned map missing at $MAP_PATH (attach succeeded but map not pinned)"
fi

info "post-attach qdisc:"
tc qdisc show dev "$IFACE" || true
info "post-attach ingress filters:"
tc filter show dev "$IFACE" ingress || true

info "attached"
