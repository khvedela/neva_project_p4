#!/usr/bin/env bash
set -euo pipefail

IFACE=${IFACE:-lo}
MAP_PATH=${MAP_PATH:-/sys/fs/bpf/tc/globals/congestion_reg}
CLEAN_MAP=${CLEAN_MAP:-1}

log() {
    echo "[cleanup] $*"
}

if ! command -v tc >/dev/null 2>&1; then
    echo "[cleanup] Error: tc not found in PATH" >&2
    exit 1
fi

log "iface=$IFACE map=$MAP_PATH clean_map=$CLEAN_MAP"
log "current qdisc:"
tc qdisc show dev "$IFACE" || true
log "current ingress filters:"
tc filter show dev "$IFACE" ingress || true

log "removing ingress filter (pref 1 handle 1)"
tc filter del dev "$IFACE" ingress pref 1 handle 1 2>/dev/null || true

log "removing clsact qdisc"
tc qdisc del dev "$IFACE" clsact 2>/dev/null || true

if [ "$CLEAN_MAP" != "0" ] && [ -e "$MAP_PATH" ]; then
    rm -f "$MAP_PATH" 2>/dev/null || true
    log "removed pinned map at $MAP_PATH"
fi

log "post-cleanup qdisc:"
tc qdisc show dev "$IFACE" || true
log "post-cleanup ingress filters:"
tc filter show dev "$IFACE" ingress || true

log "removed ingress filter and clsact on $IFACE"
