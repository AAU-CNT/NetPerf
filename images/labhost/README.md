# `labhost` image

The one container image every host node runs — sources, destinations, all of
them. The bridges (`b1`/`b2`) aren't containers, so they don't use this image.

| Tool | Used for |
|---|---|
| `iperf3` | generating TCP flows, reporting throughput as JSON |
| `iproute2` (`ss`, `tc`) | `ss -tin` for cwnd/RTT/retransmits; `tc` for Task 2 |
| `tcpdump` | packet capture |
| `iputils-ping` | reachability checks |
| `bwm-ng` | quick per-interface bandwidth read |

```bash
make build                                          # builds netperf25/labhost:latest
docker run --rm netperf25/labhost iperf3 --version  # verify
```
