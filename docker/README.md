# Docker build support

This Docker image is provided only to reproduce the build toolchain (p4c-ebpf + clang/llvm).
It does **not** run the tc attach step inside Docker. Runtime attach/execution happens on
the host kernel using `tc` and `bpftool`.

Targets:
- `make docker-build` builds the image from `docker/Dockerfile`.
- `make docker-shell` opens a shell with the repo mounted at `/workspace`.
- `make docker-compile` runs `make build` inside the container.

Notes:
- The container only compiles; it does not load or attach the eBPF program.
- Use the host VM for `make attach`, `make validate`, and `make cleanup`.
