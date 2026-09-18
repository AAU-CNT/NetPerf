# `topology/` — the lab network

You describe the network in a **normal containerlab file** (`*.clab.yml`); the
toolchain here compiles it, brings up the bridges containerlab won't, and
shapes the links.

## The dumbbell

```
 s1 ┐                             ┌ d1
 s2 ┤                             ├ d2
  … ┼─ b1 ═══(bottleneck)═══ b2 ─┼ …
 sn ┘   10 Mb/s, 5 ms, queue N    └ dn
```

`s*`/`d*` are hosts (the `labhost` image), `b1`/`b2` are Linux bridges (the
assignment's two "R" nodes), and the shaped `b1—b2` link is the shared
bottleneck.

By default, each flow is a source paired with the destination of the same
number, by sorted name `s1` talks to `d1`, `s2` to `d2`, and so on. If you
add nodes, keep the numbering matched on both sides so every source has a
destination to pair with. 

## To make a `*.clab.yml`

`topology/dumbbell.clab.yml` is the shipped reference and the file `make deploy`
reads by default. It's a standard containerlab topology with **shaping in each
link's `vars:`**:

```yaml
name: dumbbell
topology:
  nodes:
    s1: {kind: linux, image: netperf25/labhost:latest}
    b1: {kind: bridge}
    b2: {kind: bridge}
    d1: {kind: linux, image: netperf25/labhost:latest}
  links:
    - endpoints: ["s1:eth1", "b1:b1-s1"]
    - endpoints: ["b1:b1-b2", "b2:b2-b1"]
      vars: {rate: 10mbit, delay: 5ms, loss: 0, limit: 1000}   # the bottleneck
    - endpoints: ["d1:eth1", "b2:b2-d1"]
```

Build or inspect it visually in the **containerlab web editor** 
<https://srl-labs.github.io/containerlab-app/> drag out nodes and links, then
add the `vars:` to the bottleneck in the YAML pane. Save the file into the repo.

> If you do drag make sure the kind and image is correct for this usage. 

**Rules**
- a `kind: bridge` node is a host Linux bridge; everything else is a container
  (`kind` defaults to `linux`, image to the labhost image).
- name every interface in `endpoints`. Bridge-side names (`b1-b2`, `b1-s1`, …)
  become veths in the host root namespace keep them ≤ 15 chars and unique.
- a link between two bridges is automatically the **bottleneck**.
- IPs are assigned for you (`10.0.0.11`, `.12`, … in node order).

**`vars:` on a link** = the `tc` shaping applied to that link:

| key | meaning |
|---|---|
| `rate` | egress rate, tc syntax (`10mbit`, `512kbit`) |
| `delay` / `jitter` | one-way delay and its variation (`5ms`, `1ms`) |
| `loss` | drop percentage |
| `limit` | queue length in **packets** (the Task 2 bufferbloat knob) |

**`vars:` on a source (`s*`) node** = per-flow `iperf3` options for that flow
(everything else uses the `make run` defaults):

| key | iperf3 flag | meaning |
|---|---|---|
| `send_rate` | `-b` | application target bitrate — pace the sender (`3mbit`); vs a link `rate`, which is a hard `tc` cap with a queue |
| `cc` | `-C` | congestion control for **this flow only** (`reno`/`cubic`/`vegas`/`bbr`) |
| `streams` | `-P` | parallel TCP streams inside the flow |

```yaml
s1: {kind: linux, image: netperf25/labhost:latest,
     vars: {send_rate: 3mbit, cc: reno}}   # a slow Reno background flow
```

## `make deploy`

How to run your own topology files: 

```bash
make deploy                                  # compiles topology/dumbbell.clab.yml
make deploy TOPO=tasks/task2_bufferbloat/topology.clab.yml # TOPO=<path-to-clab-yml-file>
make destroy # Cleanup after you have completed runs 
```

`make deploy` runs:

1. `prepare_topology.py $(TOPO)` → `topology/.deploy.clab.yml` (your file +
   injected IP `exec:`) and `topology/.deploy.shape.json` (the shaping plan).
2. `bridges.sh up` creates the `kind: bridge` bridges (containerlab doesn't).
3. `clab deploy -t .deploy.clab.yml`.
4. `impair.sh apply` — applies the `vars` shaping with `tc`.

`make prepare` does step 1 only (useful to eyeball the generated files).

```bash
for topo in dumbbell-n1 dumbbell dumbbell-n4 dumbbell-n8; do
  make deploy  TOPO=topology/$topo.clab.yml
  make run     TASK=3 CC=cubic # TASK for name and CC for congestion control algo the flows should use.
  make destroy TOPO=topology/$topo.clab.yml
done
```

## Shaping

`impair.sh` applies your link `vars:` with `tc`, egress-only on both ends of a
link, so a shaped link behaves symmetrically. More on `tc` itself:
<https://man7.org/linux/man-pages/man8/tc.8.html>.

Retune a running lab without redeploying:

```bash
bash topology/impair.sh set --rate 1mbit --delay 5ms --loss 1   # the bottleneck
bash topology/impair.sh set --match s1-b1 --rate 2mbit          # one access link
bash topology/impair.sh show                                    # tc -s qdisc, all ifaces
bash topology/impair.sh clear
```

## Files

| File | Role |
|---|---|
| `dumbbell.clab.yml` | the reference topology (`make deploy` default) — edit this |
| `prepare_topology.py` | compile a `*.clab.yml` → deploy file + shaping plan |
| `templates/` | node templates for the containerlab web editor (`labhost`, `bridge`) |
| `bridges.sh` | create/delete the `kind: bridge` bridges |
| `impair.sh` | apply / retune / show / clear `tc` shaping |
| `netlab/` | **optional** netlab track (native Linux) — see its README |
| `.deploy.clab.yml`, `.deploy.shape.json` | generated on deploy — git-ignored |

## Requirements

`sudo` (NET_ADMIN for `tc`), Docker, `clab`, `jq`, and `sch_netem`. `make check`
verifies all of it. On WSL the default kernel often lacks `sch_netem` — see
`docs/environments.md`.
