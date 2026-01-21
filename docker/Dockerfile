FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

# 1. Install system dependencies
RUN apt update && apt install -y \
    build-essential \
    clang \
    llvm \
    libelf-dev \
    libbpf-dev \
    iproute2 \
    linux-tools-common \
    linux-tools-generic \
    git \
    cmake \
    flex \
    bison \
    libboost-all-dev \
    python3 \
    python3-pip \
    tcpdump \
    iperf3 \
    sudo \
    && rm -rf /var/lib/apt/lists/*


# 2. Build and install p4c with eBPF backend
RUN git clone --depth 1 https://github.com/p4lang/p4c.git /p4c && \
    cd /p4c && \
    git submodule update --init --recursive --depth 1 && \
    mkdir build && cd build && \
    cmake .. -DENABLE_EBPF=ON && \
    make -j$(nproc) && \
    make install

# 3. Working directory
WORKDIR /workspace