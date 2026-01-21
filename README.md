# NEVA P4 to eBPF (tc) project

This repository contains a small P4-to-eBPF pipeline that counts packets and drops
them once a configurable threshold is exceeded. The eBPF program is attached to tc
ingress and controlled via a pinned BPF map.

## Repository layout
- `p4/main.p4`: P4 program.
- `ebpf/src/`: eBPF C sources and headers.
- `ebpf/build/`: build outputs (ignored by git).
- `controller/controller.py`: map controller.
- `scripts/`: attach, cleanup, and validation scripts.
- `docker/`: optional build-only Docker toolchain.
- `docs/`: demo and validation notes.

## Prerequisites (native build)
Install common tooling on the Ubuntu VM:

```
sudo apt update && sudo apt install -y \
  build-essential clang llvm libelf-dev libbpf-dev iproute2 \
  linux-tools-common linux-tools-generic git cmake flex bison \
  libboost-all-dev python3 python3-pip tcpdump iperf3 sysstat
```

Optional: `p4c-ebpf` for P4 compilation. If not available, the build uses the
pre-generated C source in `ebpf/src/main.c`.

## Quickstart (native)
```
make build
sudo make attach IFACE=lo
sudo make threshold VALUE=1000
sudo make validate IFACE=lo
sudo make cleanup IFACE=lo
```

## Quickstart (Docker build only)
Docker is used only to reproduce the build toolchain. The program does NOT run in
Docker; tc attach and runtime execution use the host kernel.

```
make docker-build
make docker-compile
```

## Map layout
The pinned map path is:

```
/sys/fs/bpf/tc/globals/congestion_reg
```

Map keys (u32, little-endian):
- key 0: packet counter
- key 1: drop threshold

You can override the map path with `CONGESTION_MAP_PATH` or `--map-path` in the
controller.

## Controller usage
```
python3 controller/controller.py --set-threshold 1000
python3 controller/controller.py --get
python3 controller/controller.py --monitor
```

## Validation outputs
`make validate` writes artifacts to `results/results_YYYYMMDD_HHMMSS/`:
- `iperf_baseline.txt`, `iperf_drop.txt`
- `baseline.pcap`, `drop.pcap`
- `cpu_baseline.txt`, `cpu_drop.txt`
- `packet_counts.txt`
- `tc_before.txt`, `tc_after.txt`
- `bpftool_before.txt`, `bpftool_after.txt`

## Troubleshooting
- Verifier errors: check kernel version, clang version, and ensure maps are defined
  in `ebpf/src/congestion.h`.
- Permission errors: run attach/cleanup/validate with `sudo`.
- Wrong interface: use `IFACE=...` and confirm traffic is on that interface.
- Missing pinned map: ensure the program is attached via tc and that
  `/sys/fs/bpf/tc/globals/congestion_reg` exists.
- No drops observed: set a lower threshold, reset the counter, or increase load.
- Wrong section name: use `SECTION=...` to override if auto-detect fails.

## License
This project uses the MIT License for a simple, permissive university-friendly
license. See `LICENSE`.
