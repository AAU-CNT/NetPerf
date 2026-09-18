# `analysis/` running experiments and collecting data

The measurement layer: **iperf3** for throughput, **`ss -tin`** polling for
congestion window / RTT / retransmits, **`tc -s qdisc`** polling for the
bottleneck queue. 

The repo collects data into a **frozen CSV schema**.

## Files

| File | Role |
|---|---|
| `run_experiment.py` | one experiment end to end: set CC → iperf3 → sample → write `results/<run>/` |
| `sample_cwnd.sh` | poll `ss -tin` in each source container → `ss.csv` |
| `sample_qdisc.sh` | poll `tc -s qdisc` on the bottleneck → `qdisc.csv` |
| `SCHEMA.md` | **the results schema — read this before writing analysis code** |

## Run one experiment

```bash
# edit topology/dumbbell.clab.yml (or a per-task starter) for the conditions you want
make deploy                           # lab must be up first
make run TASK=3 CC=cubic              # -> results/<ts>__task3__cubic__n2__loss0/
make run TASK=4 CC=reno  LOSS=1       # TASK= LOSS= is just the results-dir label
make run TOPO=<file> TASK=4 CC=reno  LOSS=1 # Specify other file than default dumbbel
make destroy
```
`make run` calls:

```bash
python analysis/run_experiment.py --task 3 --cc cubic --loss 0 \
    --shape topology/.deploy.shape.json --duration 60 --out results/
```

`n` in the results directory is the number of flows derived from the deployed
topology (pass `--n` to override the label).

It pairs `s1→d1`, `s2→d2`, … (one iperf3 flow each, staggered ports from 5201),
sets `net.ipv4.tcp_congestion_control` in every source netns, starts the two
samplers, runs the flows in parallel for `--duration` seconds, then writes the
result files.

**Per flow**, the commands are:

```
# on each destination:
iperf3 -s -1 -p <port>
# on each source, all in parallel:
iperf3 -c <dst_ip> -p <port> -t <DUR> -C <cc> -J   [-b <send_rate>] [-P <streams>]
```

TCP is greedy by default (no `-b`), single stream (no `-P`), forward direction.
`-b`/`-C`/`-P` are added when the source node sets `send_rate` / `cc` / `streams`
in its `vars:` (see `topology/README.md`) — e.g. one slow Reno background flow
next to greedy Cubic flows. The effective command for each flow is recorded in
`run.json` under `flows[].client_cmd`.

The result directory:

```
results/<ts>__task<t>__<cc>__n<n>__loss<l>/
├── run.json      parameters + tool versions        (see SCHEMA.md)
├── flows.csv     one row per flow: throughput_mbps
├── ss.csv        cwnd / rtt_ms / retrans time series, per flow
├── qdisc.csv     backlog_bytes / drops / overlimits time series, per iface
└── iperf3/       raw iperf3 --json per flow
```

## Sample a lab you're driving by hand

```bash
make sample DUR=30                    # ss.csv + qdisc.csv straight into results/
```

or the scripts directly (both take `--shape`, `--duration`, `--interval`,
`--out`):

```bash
bash analysis/sample_qdisc.sh --shape topology/.deploy.shape.json \
    --duration 30 --interval 0.5 --out results/qdisc.csv
```

## Congestion control

`reno` and `cubic` are built into every kernel. `vegas` and `bbr` need
`modprobe tcp_vegas tcp_bbr` on the **host** (`make bootstrap` sets this up and
persists it). `make check` shows which are loaded. The setting is per-netns, so
each container's flow gets the algorithm you asked for regardless of the host
default.

## Plotting

Do it yourself from the CSVs — `../plotting/plot_example.py` is a starting
point.

## Dependencies

`run_experiment.py` and the samplers are **standard library / shell only** —
they run without `matplotlib`/`pandas`/`numpy` (those live in `../plotting/`).
