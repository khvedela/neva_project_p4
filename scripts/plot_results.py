#!/usr/bin/env python3
import argparse
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


def parse_iperf_mbps(path):
    if not path.exists():
        return None
    text = path.read_text(errors="ignore")
    regex = re.compile(r"([0-9.]+)\\s*([KMG]?)bits/sec")

    mbps = None
    for line in text.splitlines():
        if "sender" not in line:
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


def parse_packet_counts(path):
    if not path.exists():
        return {}
    regex = re.compile(r"^(\\S+):\\s*counter=(\\d+)\\s+threshold=(\\d+)")
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


def plot_bar(ax, labels, values, title, ylabel):
    ax.bar(labels, values, color=["#2c7fb8", "#f03b20"])
    ax.set_title(title)
    ax.set_ylabel(ylabel)
    ax.set_ylim(bottom=0)
    for idx, val in enumerate(values):
        ax.text(idx, val, f"{val:.2f}", ha="center", va="bottom", fontsize=8)


def main():
    parser = argparse.ArgumentParser(description="Plot NEVA validation results")
    parser.add_argument(
        "--results-dir",
        help="Results directory (defaults to latest under results/)",
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

    baseline_mbps = parse_iperf_mbps(results_dir / "iperf_baseline.txt")
    drop_mbps = parse_iperf_mbps(results_dir / "iperf_drop.txt")

    baseline_pcap = results_dir / "baseline.pcap"
    drop_pcap = results_dir / "drop.pcap"
    baseline_pcap_mb = baseline_pcap.stat().st_size / (1024 * 1024) if baseline_pcap.exists() else None
    drop_pcap_mb = drop_pcap.stat().st_size / (1024 * 1024) if drop_pcap.exists() else None

    counts = parse_packet_counts(results_dir / "packet_counts.txt")

    fig, axes = plt.subplots(1, 3, figsize=(12, 4))

    if baseline_mbps is not None and drop_mbps is not None:
        plot_bar(
            axes[0],
            ["baseline", "drop"],
            [baseline_mbps, drop_mbps],
            "Throughput",
            "Mbps",
        )
    else:
        axes[0].set_title("Throughput")
        axes[0].text(0.5, 0.5, "missing data", ha="center", va="center")
        axes[0].set_axis_off()

    if baseline_pcap_mb is not None and drop_pcap_mb is not None:
        plot_bar(
            axes[1],
            ["baseline", "drop"],
            [baseline_pcap_mb, drop_pcap_mb],
            "PCAP size",
            "MB",
        )
    else:
        axes[1].set_title("PCAP size")
        axes[1].text(0.5, 0.5, "missing data", ha="center", va="center")
        axes[1].set_axis_off()

    if counts:
        labels = []
        values = []
        for label in ["baseline_before", "baseline_after", "drop_before", "drop_after"]:
            if label in counts:
                labels.append(label.replace("_", "\\n"))
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

    fig.tight_layout()
    charts_dir = results_dir / "charts"
    charts_dir.mkdir(exist_ok=True)
    output = charts_dir / "summary.png"
    fig.savefig(output, dpi=150)
    print(f"Saved chart: {output}")


if __name__ == "__main__":
    main()
