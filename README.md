# NetPerf26 — Communication Networks Mini-Project Labs

Everything you need to complete the NetPerf26 mini-project.  
The repo is tested on a **fresh Ubuntu 26 install**.  
The networking labs run on **[Containerlab](https://containerlab.dev)** over Docker.  

## Requirements

- A fresh Ubuntu install (native, Pi, or WSL2) with `sudo` access.
- Internet access to pull packages and container images.
- ~2 GB free RAM for a small dumbbell; more if you push `n` high.

## Quickstart

Assumes you are on a system using a system with the `apt` package manager.

```bash
git clone <this-repo-url> netperf26-labs && cd netperf26-labs
make bootstrap      # installs Docker, containerlab, Python venv
make check          # verifies your environment  → prints "ENV OK"
make build          # build the labhost container image (once per machine)
```

Then to run your first run, e.g.:

```bash
make deploy              # compile topology/dumbbell.clab.yml + bring the lab up
make run TASK=3 CC=cubic # run the Task 3 experiment → results/<run>/
make destroy             # tear the lab down
```

You can then see the results and make your figures from `results/<run>/`

The network topology is based on a **containerlab file you write**. You can
start from `topology/dumbbell.clab.yml`, edit it directly, or build it visually
at <https://srl-labs.github.io/containerlab-app/> or inside VS Code with the
[containerlab extension](https://containerlab.dev/manual/gui/vsc-extension/).

When you are builing your own topoligies look at 
[`topology/README.md`](topology/README.md) for the file structure and the `vars:`
keywords available to set limits.

## What each experiment run produces

`make run` writes one directory per run:

```
results/<UTC-timestamp>__<information>/
├── run.json      all parameters + tool versions for this run
├── flows.csv     one row per TCP flow — its mean throughput
├── ss.csv        time series: congestion window, RTT, retransmits (per flow)
├── qdisc.csv     time series: bottleneck queue backlog, drops, overlimits
└── iperf3/       the raw iperf3 --json for each flow
```

| File | Columns | From |
|---|---|---|
| `run.json` | `task, cc, n, loss, rate_kbit, delay, limit_pkts, duration_s, flows, bottleneck_ifaces, tools, host` | the run's parameters |
| `flows.csv` | `timestamp, task, cc, n, loss, flow, throughput_mbps` | iperf3 receiver totals |
| `ss.csv` | `timestamp, flow, cwnd, rtt_ms, retrans` | `ss -tin` polled every 0.5 s in each source |
| `qdisc.csv` | `timestamp, iface, backlog_bytes, backlog_pkts, drops, overlimits` | `tc -s qdisc` polled every 0.5 s on the bottleneck |

`cwnd` is in **segments** (× MSS for bytes).  
`rtt_ms` is smoothed RTT.  
`drops` and `overlimits` are **cumulative** counters — differentiate for a rate.  
Blank `cwnd`/`rtt_ms` rows mean the socket was gone or not yet established at that poll.

Full semantics of the data can be found in `analysis/SCHEMA.md`.

The `plotting/` folder has an example script you can extend into the figures
your report needs.

## Other information

Here is more information you don't need to get started — read it only if
you're curious or something isn't working.

## Make help

`make help` lists every target. The repo ships the data collectors and a frozen
CSV schema; producing the report figures is your job (`plotting/` is a
starting point).

### What's in here

This gives an overview of the full repo, only if you want to see more about
the setup.

| Path | What it is |
|---|---|
| `bootstrap/` | One-shot installer (`install.sh`) + environment verifier (`preflight.sh`) |
| `images/labhost/` | The single multi-arch container image every lab node runs |
| `topology/` | The dumbbell `*.clab.yml` + the compiler, bridge, and `tc` shaping scripts |
| `analysis/` | Experiment runner + `ss`/`qdisc` samplers + the frozen results schema (`SCHEMA.md`) |
| `plotting/` | Data loader + skeleton figure scripts (you extend these) |
| `docs/environments.md` | Setup + troubleshooting for WSL, native Linux, and Raspberry Pi |
| `docs/mininet-mapping.md` | Mininet → Containerlab concept mapping |

### Environment matrix

| Environment | Difficulty | Read first |
|---|---|---|
| **Native Linux (Ubuntu)** | Easy — reference setup | — |
| **Raspberry Pi (Ubuntu arm64)** | Easy–moderate — watch RAM as `n` grows | `docs/environments.md` |
| **WSL2** | Moderate — **the default kernel may lack `sch_netem` / CC modules** | `docs/environments.md` (custom-kernel section) |

`make check` will tell you immediately whether your machine is ready. On WSL,
if it reports missing kernel modules, follow the custom-kernel steps in
`docs/environments.md` — or run the labs on native Linux / a Pi instead.

### Mininet version

If you've used the Mininet version before: `docs/mininet-mapping.md` shows how
every Mininet concept maps onto this setup.

*This setup was developed with the assistance of Claude (Anthropic).*
