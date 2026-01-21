#!/usr/bin/env bash
set -euo pipefail

IFACE=${IFACE:-lo}

if ! command -v tc >/dev/null 2>&1; then
    echo "[cleanup] Error: tc not found in PATH" >&2
    exit 1
fi

if tc filter show dev "$IFACE" ingress >/dev/null 2>&1; then
    tc filter del dev "$IFACE" ingress 2>/dev/null || true
fi

tc qdisc del dev "$IFACE" clsact 2>/dev/null || true

echo "[cleanup] removed ingress filter and clsact on $IFACE"
