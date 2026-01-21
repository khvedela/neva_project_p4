#!/usr/bin/env python3
import argparse
import json
import os
import subprocess
import sys
import time

DEFAULT_MAP_PATH = "/sys/fs/bpf/tc/globals/congestion_reg"


def run_bpftool(args):
    cmd = ["bpftool"] + args
    try:
        result = subprocess.run(cmd, capture_output=True, text=True)
    except FileNotFoundError:
        print("Error: bpftool is not installed or not in PATH.", file=sys.stderr)
        sys.exit(1)

    if result.returncode != 0:
        err = result.stderr.strip() or result.stdout.strip()
        print(f"bpftool error: {err}", file=sys.stderr)
        return None

    return result.stdout


def parse_value_bytes(val_list):
    if not isinstance(val_list, list) or not val_list:
        return None

    byte_list = []
    for item in val_list:
        if isinstance(item, str):
            item = item.strip()
            if item.startswith("0x"):
                item = item[2:]
            try:
                byte_list.append(int(item, 16))
            except ValueError:
                return None
        elif isinstance(item, int):
            if item < 0 or item > 255:
                return None
            byte_list.append(item)
        else:
            return None

    return int.from_bytes(bytes(byte_list), "little", signed=False)


def key_hex_list(key_id):
    return [f"{b:02x}" for b in key_id.to_bytes(4, "little")]


def ensure_map_path(map_path):
    if not os.path.exists(map_path):
        print(f"Error: pinned map not found at {map_path}", file=sys.stderr)
        return False
    return True


def get_map_value(map_path, key_id):
    key_hex = key_hex_list(key_id)
    output = run_bpftool(
        ["map", "lookup", "pinned", map_path, "key", "hex"]
        + key_hex
        + ["--json"]
    )
    if not output:
        return None

    try:
        data = json.loads(output)
    except json.JSONDecodeError:
        print("Error: failed to parse bpftool JSON output.", file=sys.stderr)
        return None

    return parse_value_bytes(data.get("value", []))


def set_map_value(map_path, key_id, new_value):
    if new_value < 0 or new_value > 0xFFFFFFFF:
        print("Error: value must fit in uint32.", file=sys.stderr)
        return False

    key_hex = key_hex_list(key_id)
    val_hex = [f"{b:02x}" for b in new_value.to_bytes(4, "little")]
    args = [
        "map",
        "update",
        "pinned",
        map_path,
        "key",
        "hex",
    ] + key_hex + ["value", "hex"] + val_hex

    output = run_bpftool(args)
    return output is not None


def set_threshold(map_path, new_limit):
    print(f"[*] Setting threshold to: {new_limit}")
    if set_map_value(map_path, 1, new_limit):
        print("[+] Threshold updated.")
        return True
    return False


def monitor_mode(map_path, interval):
    print("--- Monitor mode (Ctrl+C to quit) ---")
    try:
        while True:
            counter = get_map_value(map_path, 0)
            threshold = get_map_value(map_path, 1)
            if counter is None or threshold is None:
                print("\nError: failed to read map values.")
                break
            print(
                f"\r[counter={counter}] [threshold={threshold}] ",
                end="",
                flush=True,
            )
            time.sleep(interval)
    except KeyboardInterrupt:
        print("\nMonitoring stopped.")


def resolve_map_path(cli_map_path):
    if cli_map_path:
        return cli_map_path
    return os.environ.get("CONGESTION_MAP_PATH", DEFAULT_MAP_PATH)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="NEVA P4-eBPF controller")
    parser.add_argument("--set-threshold", type=int, help="Set drop threshold")
    parser.add_argument("--monitor", action="store_true", help="Monitor map values")
    parser.add_argument("--get-counter", action="store_true", help="Get packet counter")
    parser.add_argument("--get-threshold", action="store_true", help="Get drop threshold")
    parser.add_argument("--get", action="store_true", help="Get counter and threshold")
    parser.add_argument(
        "--map-path",
        help="Override pinned map path (default or CONGESTION_MAP_PATH)",
    )
    parser.add_argument(
        "--interval",
        type=float,
        default=0.5,
        help="Monitor interval seconds (default: 0.5)",
    )

    args = parser.parse_args()

    if len(sys.argv) == 1:
        parser.print_help()
        sys.exit(1)

    map_path = resolve_map_path(args.map_path)

    if (
        args.set_threshold is not None
        or args.monitor
        or args.get
        or args.get_counter
        or args.get_threshold
    ):
        if not ensure_map_path(map_path):
            sys.exit(1)

    if args.set_threshold is not None:
        if not set_threshold(map_path, args.set_threshold):
            sys.exit(1)

    if args.get:
        counter = get_map_value(map_path, 0)
        threshold = get_map_value(map_path, 1)
        if counter is None or threshold is None:
            sys.exit(1)
        print(f"counter={counter} threshold={threshold}")

    if args.get_counter:
        counter = get_map_value(map_path, 0)
        if counter is None:
            sys.exit(1)
        print(counter)

    if args.get_threshold:
        threshold = get_map_value(map_path, 1)
        if threshold is None:
            sys.exit(1)
        print(threshold)

    if args.monitor:
        monitor_mode(map_path, args.interval)
