# Results schema (frozen)

Every experiment — Task 2, 3, 4, or 5 — writes **one directory** under
`results/`. Nothing else in the repo defines a results format; if you write your
own analysis, read these files.

## Directory name

```
results/<ts>__task<t>__<cc>__n<n>__loss<l>/
```

e.g. `results/20260908T141230Z__task3__cubic__n4__loss0/`. `<ts>` is UTC,
`YYYYMMDDThhmmssZ`. The name is a convenience only — the authoritative
parameters live in `run.json`.

## Files

### `run.json`

The full parameter set plus the environment it ran in. One JSON object:

| key | type | meaning |
|---|---|---|
| `timestamp` | string | UTC ISO-8601, start of the run |
| `task` | int | 2–5 |
| `cc` | string | congestion control: `reno` \| `vegas` \| `cubic` \| `bbr` |
| `n` | int | source/destination pairs in the dumbbell |
| `loss` | float | bottleneck loss percent (0 or 1 for the assignment) |
| `rate_kbit` | int | bottleneck egress rate applied, kbit/s |
| `delay` | string | bottleneck one-way delay applied (e.g. `5ms`) |
| `limit_pkts` | int | bottleneck queue length applied, packets |
| `duration_s` | int | measured flow duration |
| `flows` | list | `[{name, src, dst, port, cc, send_rate, streams, client_cmd}]` — `cc`/`send_rate`/`streams` are the *effective* per-flow values (node `vars` override the run default; `send_rate` is `null` when unset), `client_cmd` is the exact `iperf3 -c …` line |
| `sample_interval_s` | float | `ss` / `qdisc` poll period |
| `bottleneck_ifaces` | list | interfaces `qdisc.csv` covers |
| `tools` | object | `{iperf3, tc, ss, clab, kernel}` version strings |
| `host` | object | `{arch, os}` |

### `flows.csv` — one row per flow, end-of-run summary

```
timestamp,task,cc,n,loss,flow,throughput_mbps
```

`throughput_mbps` is the mean of the receiver-side `sum_received` bits/s from
iperf3 JSON, in Mbit/s (10^6). `timestamp` is the run start (identical on every
row) so the file self-joins with the others.

### `ss.csv` — congestion-window / RTT time series

```
timestamp,flow,cwnd,rtt_ms,retrans
```

One row per flow per poll. Produced by `sample_cwnd.sh` parsing `ss -tin`:

| column | source | notes |
|---|---|---|
| `timestamp` | wall clock at poll | UTC ISO-8601 with fractional seconds |
| `flow` | matched from `run.json` `flows` by dst:port | `s1->d1` style |
| `cwnd` | `cwnd:` field of `ss -ti` | **segments**, not bytes (multiply by MSS for bytes) |
| `rtt_ms` | `rtt:<srtt>/<rttvar>` — the srtt part | milliseconds |
| `retrans` | `retrans:X/Y` — cumulative `Y` | total retransmits on the socket so far |

Empty `cwnd`/`rtt_ms` (socket gone, or not yet established) are written as blank.

### `qdisc.csv` — bottleneck queue time series

```
timestamp,iface,backlog_bytes,backlog_pkts,drops,overlimits
```

One row per bottleneck interface per poll. Produced by `sample_qdisc.sh`
parsing `tc -s qdisc show dev <iface>`:

| column | meaning |
|---|---|
| `backlog_bytes` / `backlog_pkts` | queue occupancy **at the instant of the poll** |
| `drops` | cumulative packets dropped by the qdisc (tail drop when the `limit` is hit) |
| `overlimits` | cumulative htb rate-limit events |

`drops` and `overlimits` are cumulative counters — differentiate for a rate.

## Deriving the assignment's answers

`../plotting/plot_example.py` is a starting point for these — load a run
directory into pandas DataFrames and extend it into the figure you need.

* **"how does the congestion window change?"** → plot `ss.csv` `cwnd` vs
  `timestamp`, one line per `flow`, faceted by `n` (compare runs).
* **"how does the delay change?"** → plot `ss.csv` `rtt_ms`; cross-check against
  `qdisc.csv` `backlog_bytes / rate` (standing queue delay).
* **fairness across `n`** → `flows.csv` `throughput_mbps` per flow; Jain's index.
* **Task 2 bufferbloat** → `qdisc.csv` `backlog_bytes` and the RTT inflation in
  `ss.csv` for large vs small `limit_pkts`.
* **Task 4 (1% loss)** → `ss.csv` `retrans` climbs; compare `cwnd` shape between
  loss-based (Reno/Cubic) and delay/rate-based (Vegas/BBR) control.
