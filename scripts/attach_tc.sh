#!/usr/bin/env bash
set -euo pipefail

IFACE=${IFACE:-lo}
OBJ=${OBJ:-ebpf/build/main.o}
SECTION=${SECTION:-}

log() {
    echo "[attach] $*"
}

warn() {
    echo "[attach] Warning: $*" >&2
}

if ! command -v tc >/dev/null 2>&1; then
    echo "[attach] Error: tc not found in PATH" >&2
    exit 1
fi

if [ ! -f "$OBJ" ]; then
    echo "[attach] Error: eBPF object not found at $OBJ" >&2
    exit 1
fi

if ! tc qdisc show dev "$IFACE" | grep -q clsact; then
    log "adding clsact qdisc on $IFACE"
    tc qdisc add dev "$IFACE" clsact 2>/dev/null || true
fi

detect_section() {
    local obj="$1"
    local section=""

    if command -v llvm-objdump >/dev/null 2>&1; then
        section=$(llvm-objdump -h "$obj" | awk 'NR>5 {print $2}' | \
            grep -E '^(tc|classifier|xdp|ingress|egress)$' | head -n1 || true)
    fi

    if [ -z "$section" ] && command -v readelf >/dev/null 2>&1; then
        section=$(readelf -S "$obj" | awk '{print $2}' | tr -d '[]' | \
            grep -E '^(tc|classifier|xdp|ingress|egress)$' | head -n1 || true)
    fi

    if [ -z "$section" ] && command -v llvm-objdump >/dev/null 2>&1; then
        section=$(llvm-objdump -h "$obj" | awk 'NR>5 {print $2}' | \
            grep -v '^\.' | grep -v -E '^(license|maps|BTF|BTF.ext)$' | head -n1 || true)
    fi

    if [ -z "$section" ] && command -v readelf >/dev/null 2>&1; then
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

log "attaching section '$SECTION' from $OBJ on $IFACE"
if ! tc filter replace dev "$IFACE" ingress pref 1 handle 1 bpf da obj "$OBJ" sec "$SECTION"; then
    warn "tc filter replace failed; trying delete+add"
    tc filter del dev "$IFACE" ingress 2>/dev/null || true
    tc filter add dev "$IFACE" ingress pref 1 handle 1 bpf da obj "$OBJ" sec "$SECTION"
fi

log "attached"
