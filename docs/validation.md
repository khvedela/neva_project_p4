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
- `packet_counts.txt`: look for `counter` values and ensure drops occur when
  `counter > threshold`.
- `tc_before.txt` and `tc_after.txt`: confirm the tc filter is attached to ingress.
- `bpftool_before.txt` and `bpftool_after.txt`: inspect map contents.
- `baseline.pcap` and `drop.pcap`: use Wireshark or tcpdump to compare packet volume.

## Notes
- If no drop is observed, lower `DROP_THRESHOLD` or reset the counter.
- If map access fails, verify you are running as root and that the program is
  attached to the correct interface.
