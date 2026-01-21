# Demo script (5 steps)

1) Build the eBPF object
```
make build
```

2) Attach on loopback
```
sudo make attach IFACE=lo
```

3) Baseline with a high threshold
```
sudo make threshold VALUE=1000000
iperf3 -s -1 &
iperf3 -c 127.0.0.1 -t 10
```

4) Trigger drops with a low threshold
```
sudo make threshold VALUE=1000
iperf3 -s -1 &
iperf3 -c 127.0.0.1 -t 10
```

5) Cleanup
```
sudo make cleanup IFACE=lo
```
