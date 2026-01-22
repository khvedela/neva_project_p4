#!/usr/bin/env python3
import argparse
import json
import sys
from pathlib import Path


def read_json(path):
    try:
        return json.loads(path.read_text())
    except Exception:
        return None


def parse_iperf_intervals(path):
    data = read_json(path)
    if not data:
        return None
    if "error" in data:
        return None
    intervals = data.get("intervals", [])
    times = []
    mbps = []
    for interval in intervals:
        summary = interval.get("sum", {})
        start = summary.get("start")
        end = summary.get("end")
        bps = summary.get("bits_per_second")
        if start is None or end is None or bps is None:
            continue
        t = (start + end) / 2.0
        times.append(t)
        mbps.append(bps / 1_000_000.0)
    if not times:
        return None
    return times, mbps


def read_counter_csv(path):
    if not path.exists():
        return None
    times = []
    values = []
    start_ts = None
    for line in path.read_text(errors="ignore").splitlines():
        if line.startswith("timestamp_ms"):
            continue
        parts = line.strip().split(",")
        if len(parts) != 2:
            continue
        try:
            ts = int(parts[0])
            val = int(parts[1])
        except ValueError:
            continue
        if start_ts is None:
            start_ts = ts
        times.append((ts - start_ts) / 1000.0)
        values.append(val)
    if not times:
        return None
    return times, values


def parse_packet_counts(path):
    if not path.exists():
        return {}
    counts = {}
    for line in path.read_text(errors="ignore").splitlines():
        line = line.strip()
        if not line:
            continue
        if "counter=" not in line:
            continue
        label, rest = line.split(":", 1)
        fields = rest.strip().split()
        counter = None
        threshold = None
        for item in fields:
            if item.startswith("counter="):
                counter = int(item.split("=", 1)[1])
            if item.startswith("threshold="):
                threshold = int(item.split("=", 1)[1])
        if counter is not None:
            counts[label] = {"counter": counter, "threshold": threshold}
    return counts


def find_latest_results(root):
    root_path = Path(root)
    candidates = sorted(
        [p for p in root_path.glob("results_*") if p.is_dir()],
        key=lambda p: p.name,
    )
    return candidates[-1] if candidates else None


def read_meta(path):
    if not path.exists():
        return {}
    try:
        return json.loads(path.read_text())
    except json.JSONDecodeError:
        return {}


def step_from_counts(duration, before, after):
    if duration <= 0:
        duration = 1.0
    return [0.0, duration], [before, after]


def main():
    parser = argparse.ArgumentParser(description="Plot NEVA time-series results")
    parser.add_argument("--results-dir", help="Results directory (defaults to latest under results/)")
    args = parser.parse_args()

    results_dir = Path(args.results_dir) if args.results_dir else find_latest_results("results")
    if results_dir is None or not results_dir.exists():
        print("Error: results directory not found.", file=sys.stderr)
        sys.exit(1)

    try:
        import matplotlib.pyplot as plt
    except ImportError:
        print("Error: matplotlib not installed. Run: pip3 install matplotlib", file=sys.stderr)
        sys.exit(1)

    meta = read_meta(results_dir / "meta.json")
    duration = float(meta.get("duration", 0) or 0)

    baseline_ts = parse_iperf_intervals(results_dir / "iperf_baseline.json")
    drop_ts = parse_iperf_intervals(results_dir / "iperf_drop.json")

    baseline_counter = read_counter_csv(results_dir / "counter_baseline.csv")
    drop_counter = read_counter_csv(results_dir / "counter_drop.csv")

    counts = parse_packet_counts(results_dir / "packet_counts.txt")

    fig, axes = plt.subplots(1, 2, figsize=(12, 4))

    if baseline_ts:
        axes[0].plot(baseline_ts[0], baseline_ts[1], label="baseline", color="#2c7fb8")
    if drop_ts:
        axes[0].plot(drop_ts[0], drop_ts[1], label="drop", color="#f03b20")
    axes[0].set_title("Throughput over time")
    axes[0].set_xlabel("seconds")
    axes[0].set_ylabel("Mbps")
    axes[0].grid(True, alpha=0.2)
    axes[0].legend()

    if baseline_counter:
        axes[1].plot(baseline_counter[0], baseline_counter[1], label="baseline", color="#2c7fb8")
    else:
        before = counts.get("baseline_before", {}).get("counter")
        after = counts.get("baseline_after", {}).get("counter")
        if before is not None and after is not None:
            t, v = step_from_counts(duration, before, after)
            axes[1].plot(t, v, label="baseline", color="#2c7fb8")

    if drop_counter:
        axes[1].plot(drop_counter[0], drop_counter[1], label="drop", color="#f03b20")
    else:
        before = counts.get("drop_before", {}).get("counter")
        after = counts.get("drop_after", {}).get("counter")
        if before is not None and after is not None:
            t, v = step_from_counts(duration, before, after)
            axes[1].plot(t, v, label="drop", color="#f03b20")

    threshold = counts.get("drop_after", {}).get("threshold") or counts.get("drop_before", {}).get("threshold")
    if threshold is not None:
        axes[1].axhline(threshold, linestyle="--", color="#555", alpha=0.6, label="threshold")

    axes[1].set_title("Packet counter over time")
    axes[1].set_xlabel("seconds")
    axes[1].set_ylabel("count")
    axes[1].grid(True, alpha=0.2)
    axes[1].legend()

    fig.tight_layout()
    charts_dir = results_dir / "charts"
    charts_dir.mkdir(exist_ok=True)
    output = charts_dir / "timeseries.png"
    fig.savefig(output, dpi=150)
    print(f"Saved chart: {output}")


if __name__ == "__main__":
    main()
