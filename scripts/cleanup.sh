#!/usr/bin/env bash
set -euo pipefail

IFACE=${IFACE:-lo}
MAP_PATH=${MAP_PATH:-/sys/fs/bpf/tc/globals/congestion_reg}
CLEAN_MAP=${CLEAN_MAP:-1}

if ! command -v tc >/dev/null 2>&1; then
    echo "[cleanup] Error: tc not found in PATH" >&2
    exit 1
fi

tc filter del dev "$IFACE" ingress pref 1 handle 1 2>/dev/null || true

tc qdisc del dev "$IFACE" clsact 2>/dev/null || true

if [ "$CLEAN_MAP" != "0" ] && [ -e "$MAP_PATH" ]; then
    rm -f "$MAP_PATH" 2>/dev/null || true
    echo "[cleanup] removed pinned map at $MAP_PATH"
fi

echo "[cleanup] removed ingress filter and clsact on $IFACE"
