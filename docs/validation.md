# Validation guide

## Acceptance criteria
- `make build` produces `ebpf/build/main.o` without errors.
- `sudo make attach IFACE=lo` attaches a tc ingress filter.
- The pinned map exists at `/sys/fs/bpf/tc/globals/congestion_reg`.
- Baseline run (high threshold) shows normal throughput in `iperf_baseline.txt`.
- Drop run (low threshold) shows reduced throughput in `iperf_drop.txt`.
- `packet_counts.txt` shows the counter increasing and exceeding the drop threshold.
- `baseline.pcap` and `drop.pcap` exist, with less traffic in the drop capture.
- `cpu_baseline.txt` and `cpu_drop.txt` exist (pidstat output or placeholder).

## Interpreting outputs
- `iperf_baseline.txt` vs `iperf_drop.txt`: compare bandwidth and retransmits.
- `iperf_baseline.json` and `iperf_drop.json`: structured iperf output for plotting.
- `packet_counts.txt`: look for `counter` values and ensure drops occur when
  `counter > threshold`.
- `tc_before.txt` and `tc_after.txt`: confirm the tc filter is attached to ingress.
- `bpftool_before.txt` and `bpftool_after.txt`: inspect map contents.
- `baseline.pcap` and `drop.pcap`: use Wireshark or tcpdump to compare packet volume.
- `validate.log` and `system.txt`: detailed run log and system snapshot.

## Notes
- If no drop is observed, lower `DROP_THRESHOLD` or reset the counter.
- If map access fails, verify you are running as root and that the program is
  attached to the correct interface.

## Safe defaults and knobs
- `AUTO_THRESHOLD=1` (default) computes `DROP_THRESHOLD` from baseline packet count.
- `TCPDUMP_COUNT=20000` and `TCPDUMP_SNAPLEN=96` cap pcap size by default.
- `TCPDUMP_FILTER` defaults to `tcp and port <iperf_port>` to limit capture noise.
- `IPERF_PORT` and `IPERF_PORT_RANGE` pick a free port if 5201 is busy.
- `KILL_IPERF=1` terminates stale iperf3 processes before running.
- `AUTO_ATTACH=1` re-attaches the program if the pinned map is missing.
- `SKIP_TCPDUMP=1` or `SKIP_PIDSTAT=1` disable optional captures.
- `NO_COLOR=1` disables ANSI colors in logs.

The run metadata is stored in `meta.json` inside the results directory.

## Charts (optional)
Generate a summary chart from a results directory:

```
python3 scripts/plot_results.py --results-dir results/results_YYYYMMDD_HHMMSS
```

This creates `results/results_YYYYMMDD_HHMMSS/charts/summary.png`. You may need:

```
pip3 install matplotlib
```

## Time-series charts (optional)
If `COUNTER_SAMPLE_SECS` is enabled (default `1`), the script writes
`counter_baseline.csv` and `counter_drop.csv`. You can generate a time-series
plot with:

```
python3 scripts/plot_timeseries.py --results-dir results/results_YYYYMMDD_HHMMSS
```

This creates `results/results_YYYYMMDD_HHMMSS/charts/timeseries.png`.

## Auto-tune (optional)
To compute a safe drop threshold for the current machine, run:

```
sudo scripts/auto_tune.sh
```

It prints a `make validate` command with a tuned `DROP_THRESHOLD`.
