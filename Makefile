SHELL := /bin/bash

P4C ?= p4c-ebpf
CLANG ?= clang
IFACE ?= lo
SECTION ?=
OBJ ?= ebpf/build/main.o
MAP_PATH ?= /sys/fs/bpf/tc/globals/congestion_reg
MAP_NAME ?= congestion_reg
CLEAN_MAP ?= 1

P4_SRC := p4/main.p4
EBPF_SRC := ebpf/src/main.c
EBPF_BUILD_DIR := ebpf/build
EBPF_GEN_C := $(EBPF_BUILD_DIR)/main.c
EBPF_GEN_H := $(EBPF_BUILD_DIR)/main.h
EBPF_CONGESTION := ebpf/src/congestion.h
CONTROLLER := controller/controller.py

DOCKER_IMAGE ?= neva-p4c

UNAME_S := $(shell uname -s)
UNAME_M := $(shell uname -m)
SYS_INCLUDES :=
ifeq ($(UNAME_S),Linux)
SYS_INCLUDES := -I/usr/include -I/usr/include/$(UNAME_M)-linux-gnu
endif

SUDO :=
ifeq ($(shell id -u),0)
SUDO :=
else
SUDO := sudo
endif

.PHONY: build attach cleanup threshold validate docker-build docker-shell docker-compile

build:
	@mkdir -p $(EBPF_BUILD_DIR)
	@if command -v $(P4C) >/dev/null 2>&1; then \
		echo "[build] Using p4c-ebpf to generate eBPF C"; \
		if $(P4C) -o $(EBPF_GEN_C) $(P4_SRC); then \
			if [ ! -f $(EBPF_GEN_H) ]; then \
				echo "[build] Warning: $(EBPF_GEN_H) not generated; using fallback header"; \
				cp ebpf/src/main.h $(EBPF_GEN_H); \
			fi; \
			$(CLANG) -O2 -g -target bpf -c $(EBPF_GEN_C) -o $(OBJ) \
				-I ebpf/src -I $(EBPF_BUILD_DIR) $(SYS_INCLUDES) -include $(EBPF_CONGESTION); \
		else \
			echo "[build] p4c-ebpf failed; falling back to ebpf/src/main.c"; \
			$(CLANG) -O2 -g -target bpf -c $(EBPF_SRC) -o $(OBJ) -I ebpf/src $(SYS_INCLUDES); \
		fi; \
	else \
		echo "[build] p4c-ebpf not found; building from ebpf/src/main.c"; \
		$(CLANG) -O2 -g -target bpf -c $(EBPF_SRC) -o $(OBJ) -I ebpf/src $(SYS_INCLUDES); \
	fi

attach: $(OBJ)
	@$(SUDO) IFACE=$(IFACE) SECTION=$(SECTION) OBJ=$(OBJ) MAP_PATH=$(MAP_PATH) MAP_NAME=$(MAP_NAME) scripts/attach_tc.sh

cleanup:
	@$(SUDO) IFACE=$(IFACE) MAP_PATH=$(MAP_PATH) CLEAN_MAP=$(CLEAN_MAP) scripts/cleanup.sh

threshold:
	@if [ -z "$(VALUE)" ]; then \
		echo "VALUE is required. Example: make threshold VALUE=1000"; \
		exit 1; \
	fi
	@$(SUDO) CONGESTION_MAP_PATH=$(MAP_PATH) python3 $(CONTROLLER) --set-threshold $(VALUE)
	@$(SUDO) CONGESTION_MAP_PATH=$(MAP_PATH) python3 $(CONTROLLER) --get-threshold

validate:
	@$(SUDO) IFACE=$(IFACE) CONGESTION_MAP_PATH=$(MAP_PATH) scripts/validate.sh

docker-build:
	docker build -t $(DOCKER_IMAGE) -f docker/Dockerfile .

docker-shell:
	docker run --rm -it -v "$(PWD)":/workspace $(DOCKER_IMAGE) /bin/bash

docker-compile:
	docker run --rm -v "$(PWD)":/workspace $(DOCKER_IMAGE) make build
