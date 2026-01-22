#!/usr/bin/env python3
import argparse
import json
import re
import sys
from pathlib import Path


def to_mbps(value, unit):
    val = float(value)
    unit = unit.upper()
    if unit == "K":
        return val / 1000.0
    if unit == "M":
        return val
    if unit == "G":
        return val * 1000.0
    return val / 1_000_000.0


def parse_iperf_text_mbps(path):
    if not path.exists():
        return None
    text = path.read_text(errors="ignore")
    regex = re.compile(r"([0-9.]+)\s*([KMG]?)bits/sec", re.IGNORECASE)

    mbps = None
    for line in text.splitlines():
        if "sender" not in line.lower():
            continue
        match = regex.search(line)
        if match:
            mbps = to_mbps(match.group(1), match.group(2))

    if mbps is None:
        for line in text.splitlines():
            match = regex.search(line)
            if match:
                mbps = to_mbps(match.group(1), match.group(2))

    return mbps


def parse_iperf_json_mbps(path):
    if not path.exists():
        return None
    try:
        data = json.loads(path.read_text())
    except json.JSONDecodeError:
        return None

    if "error" in data:
        return None

    end = data.get("end", {})
    for key in ("sum_sent", "sum_received", "sum"):
        section = end.get(key, {})
        if "bits_per_second" in section:
            return section["bits_per_second"] / 1_000_000.0

    streams = end.get("streams", [])
    if streams:
        bps = 0.0
        for stream in streams:
            summary = stream.get("sender", {})
            if "bits_per_second" in summary:
                bps += summary["bits_per_second"]
        if bps > 0:
            return bps / 1_000_000.0

    return None


def parse_packet_counts(path):
    if not path.exists():
        return {}
    regex = re.compile(r"^(\S+):\s*counter=(\d+)\s+threshold=(\d+)")
    counts = {}
    for line in path.read_text(errors="ignore").splitlines():
        match = regex.search(line)
        if match:
            label = match.group(1)
            counts[label] = {
                "counter": int(match.group(2)),
                "threshold": int(match.group(3)),
            }
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


def estimate_mbps_from_pcap(pcap_path, duration_sec):
    if duration_sec <= 0:
        return None
    if not pcap_path.exists():
        return None
    size_bytes = pcap_path.stat().st_size
    if size_bytes == 0:
        return None
    return (size_bytes * 8.0) / (duration_sec * 1_000_000.0)


def plot_bar(ax, labels, values, title, ylabel, notes=None):
    plot_values = [v if v is not None else 0 for v in values]
    ax.bar(labels, plot_values, color=["#2c7fb8", "#f03b20"])
    ax.set_title(title)
    ax.set_ylabel(ylabel)
    ax.set_ylim(bottom=0)

    max_val = max(plot_values) if plot_values else 1.0
    if max_val == 0:
        max_val = 1.0

    for idx, val in enumerate(values):
        if val is None:
            ax.text(idx, max_val * 0.05, "missing", ha="center", va="bottom", fontsize=8)
            continue
        label = f"{val:.2f}"
        if notes and notes[idx]:
            label += notes[idx]
        ax.text(idx, val, label, ha="center", va="bottom", fontsize=8)


def main():
    parser = argparse.ArgumentParser(description="Plot NEVA validation results")
    parser.add_argument(
        "--results-dir",
        help="Results directory (defaults to latest under results/)",
    )
    parser.add_argument(
        "--duration",
        type=float,
        help="Override duration seconds for throughput estimation",
    )
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
    duration_sec = args.duration or float(meta.get("duration", 0) or 0)

    baseline_json = results_dir / "iperf_baseline.json"
    drop_json = results_dir / "iperf_drop.json"
    baseline_txt = results_dir / "iperf_baseline.txt"
    drop_txt = results_dir / "iperf_drop.txt"

    baseline_mbps = parse_iperf_json_mbps(baseline_json)
    drop_mbps = parse_iperf_json_mbps(drop_json)

    if baseline_mbps is None:
        baseline_mbps = parse_iperf_text_mbps(baseline_txt)
    if drop_mbps is None:
        drop_mbps = parse_iperf_text_mbps(drop_txt)

    baseline_note = ""
    drop_note = ""

    baseline_pcap = results_dir / "baseline.pcap"
    drop_pcap = results_dir / "drop.pcap"
    baseline_pcap_mb = baseline_pcap.stat().st_size / (1024 * 1024) if baseline_pcap.exists() else None
    drop_pcap_mb = drop_pcap.stat().st_size / (1024 * 1024) if drop_pcap.exists() else None

    if baseline_mbps is None:
        estimate = estimate_mbps_from_pcap(baseline_pcap, duration_sec)
        if estimate is not None:
            baseline_mbps = estimate
            baseline_note = "*"

    if drop_mbps is None:
        estimate = estimate_mbps_from_pcap(drop_pcap, duration_sec)
        if estimate is not None:
            drop_mbps = estimate
            drop_note = "*"

    counts = parse_packet_counts(results_dir / "packet_counts.txt")

    fig, axes = plt.subplots(1, 3, figsize=(12, 4))

    plot_bar(
        axes[0],
        ["baseline", "drop"],
        [baseline_mbps, drop_mbps],
        "Throughput",
        "Mbps",
        [baseline_note, drop_note],
    )

    plot_bar(
        axes[1],
        ["baseline", "drop"],
        [baseline_pcap_mb, drop_pcap_mb],
        "PCAP size",
        "MB",
        [None, None],
    )

    if counts:
        labels = []
        values = []
        for label in ["baseline_before", "baseline_after", "drop_before", "drop_after"]:
            if label in counts:
                labels.append(label.replace("_", "\n"))
                values.append(counts[label]["counter"])
        if labels:
            axes[2].bar(labels, values, color="#41ab5d")
            axes[2].set_title("Packet counter")
            axes[2].set_ylabel("count")
        else:
            axes[2].set_title("Packet counter")
            axes[2].text(0.5, 0.5, "missing data", ha="center", va="center")
            axes[2].set_axis_off()
    else:
        axes[2].set_title("Packet counter")
        axes[2].text(0.5, 0.5, "missing data", ha="center", va="center")
        axes[2].set_axis_off()

    if baseline_note == "*" or drop_note == "*":
        fig.text(0.02, 0.02, "* throughput estimated from pcap size", fontsize=8)

    fig.tight_layout()
    charts_dir = results_dir / "charts"
    charts_dir.mkdir(exist_ok=True)
    output = charts_dir / "summary.png"
    fig.savefig(output, dpi=150)
    print(f"Saved chart: {output}")


if __name__ == "__main__":
    main()
