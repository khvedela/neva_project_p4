#!/usr/bin/env bash
set -euo pipefail

IFACE=${IFACE:-lo}
MAP_PATH=${MAP_PATH:-/sys/fs/bpf/tc/globals/congestion_reg}
CLEAN_MAP=${CLEAN_MAP:-1}
CLEAN_ALL=${CLEAN_ALL:-0}
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
    local prefix="[$(ts)] [cleanup] [$level]"
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

if have ip; then
    if ! ip link show "$IFACE" >/dev/null 2>&1; then
        error "network interface '$IFACE' not found"
    fi
else
    warn "ip command not found; skipping interface check"
fi

info "iface=$IFACE map=$MAP_PATH clean_map=$CLEAN_MAP clean_all=$CLEAN_ALL"
info "current qdisc:"
tc qdisc show dev "$IFACE" || true
info "current ingress filters:"
tc filter show dev "$IFACE" ingress || true

step "removing ingress filters"
if [ "$CLEAN_ALL" = "1" ]; then
    tc filter del dev "$IFACE" ingress 2>/dev/null || true
else
    tc filter del dev "$IFACE" ingress pref 1 handle 1 2>/dev/null || true
fi

step "removing clsact qdisc"
tc qdisc del dev "$IFACE" clsact 2>/dev/null || true

if [ "$CLEAN_MAP" != "0" ] && [ -e "$MAP_PATH" ]; then
    rm -f "$MAP_PATH" 2>/dev/null || true
    info "removed pinned map at $MAP_PATH"
fi

info "post-cleanup qdisc:"
tc qdisc show dev "$IFACE" || true
info "post-cleanup ingress filters:"
tc filter show dev "$IFACE" ingress || true

info "cleanup complete on $IFACE"
