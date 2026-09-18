# Mininet → Containerlab mapping

The original NetPerf exercise (and the Task 2 bufferbloat lab it links to) was
written for **Mininet**. Mininet is effectively unmaintained — frozen at 2.3.0
since February 2021 — and awkward to install on a current Ubuntu. This repo
rebuilds the same lab on **Containerlab + Docker**. This page is the concept
dictionary between the two.

## At a glance

| Mininet | Here (Containerlab) |
|---|---|
| `Topo` subclass; `addHost` / `addSwitch` / `addLink` in Python | a `*.clab.yml` you edit by hand or in the [containerlab web editor](https://srl-labs.github.io/containerlab-app/): `topology.nodes` + `topology.links` |
| `net = Mininet(topo=…)`; `net.start()` | `make deploy` (compiles the file, brings up bridges, `clab deploy`, applies shaping) |
| `net.stop()` | `make destroy` (`clab destroy --cleanup` + bridges down) |
| Host = a bare network namespace, no filesystem | full container (`kind: linux`) running the **`labhost`** image |
| OVS switch + OpenFlow controller | `kind: bridge` — a plain Linux bridge = one shared L2 segment, no controller |
| The two "R" nodes in Fig. 1 | two Linux bridges `b1`, `b2`, wired `b1—b2`; that link is the bottleneck |
| `TCLink(bw=10, delay='5ms', loss=1, max_queue_size=100)` | a link's `vars: {rate: 10mbit, delay: 5ms, loss: 1, limit: 100}` in the `*.clab.yml` → applied as per-interface `tc` (`htb rate` + `netem delay/jitter/loss` + `limit N`), egress-only ⇒ both ends |
| `CLI(net)` interactive prompt | `docker exec -it clab-<lab>-<node> bash` |
| `mininet> h1 ping h2` | `docker exec clab-dumbbell-s1 ping <d1 ip>` |
| `host.cmd('iperf3 -s &')` | `docker exec -d clab-dumbbell-d1 iperf3 -s` |
| Automatic `10.0.0.0/8`, hosts `10.0.0.1…` | flat `10.0.0.0/16`; `prepare_topology.py` assigns `.11+` in an injected `exec:` block |
| `sysctl -w net.ipv4.tcp_congestion_control=…` (global) | same sysctl per netns, or `iperf3 -C` per flow; `make run CC=` sets the default, a source node's `vars: {cc, send_rate, streams}` overrides it for that flow |
| cwnd via the `tcp_probe` module / `monitor.py` | `tcp_probe` is removed from modern kernels — poll `ss -tin` instead (`analysis/sample_cwnd.sh`); queue state via `tc -s qdisc show` (`analysis/sample_qdisc.sh`) |
| `popen()` loop over `n` host pairs in the `Topo` | add `s*`/`d*` nodes + links to the `*.clab.yml` by hand (or in the web editor) — one file per `n` |
| `python bufferbloat.py -q 100` | set `limit: 100` in the bottleneck `vars` of `tasks/task2_bufferbloat/topology.clab.yml`, `make deploy TOPO=…`, then `tasks/task2_bufferbloat/monitor.sh` |

## Why the differences matter

### Hosts are containers, not bare namespaces

Mininet hosts share the host filesystem and just get their own netns. `labhost`
containers are isolated images with the tools baked in (`iperf3`, `ss`, `tc`,
`tcpdump`, `ping`, `bwm-ng`). Upside: reproducible, arch-portable (x86 + arm64),
no "works on my machine". Difference to remember: a process in `s1` sees `s1`'s
filesystem, not yours — copy files with `docker cp`.

### Bridges instead of OVS + controller

The exercise never uses OpenFlow; it just needs a shared L2 segment with shaped
links. A `kind: bridge` Linux bridge is exactly that and has no controller to
run or crash. **Containerlab does not create these bridges** — `make deploy`
runs `topology/bridges.sh up` first (STP and forwarding delay off, so links pass
traffic immediately), `make destroy` tears them down.

### Shaping lives in the topology file; `tc` applies it, on both ends

`TCLink` took `bw`, `delay`, `loss`, and `max_queue_size` in one call. Here the
equivalent goes in a link's `vars:` map in the `*.clab.yml`:

```yaml
- endpoints: ["b1:b1-b2", "b2:b2-b1"]
  vars: {rate: 10mbit, delay: 5ms, loss: 1, limit: 1000}
```

`clab tools netem` can't do this — it (a) has no queue-size knob and (b) can
only enter a *container's* netns, not the root-netns veth of a `kind: bridge`,
which is where our bottleneck lives. So `prepare_topology.py` reads the `vars`
into a plan and `impair.sh` drives `tc` directly: `htb` for the rate, `netem`
for delay/jitter/loss, `netem … limit N` for the bounded queue, all as **one**
qdisc chain. `tc` shapes egress only, so every link is shaped on **both** of its
interfaces.

### cwnd without `tcp_probe`

The Mininet bufferbloat lab reads the congestion window from the `tcp_probe`
kernel module. That module is gone. `ss -tin` reports `cwnd:` (in segments),
`rtt:` (srtt/rttvar), and `retrans:` per socket; polling it on a fixed interval
gives the same time series. `analysis/sample_cwnd.sh` does this inside each
source container.

## Naming

| Thing | Convention |
|---|---|
| source containers | `s1`, `s2`, … `sN` |
| destination containers | `d1`, `d2`, … `dN` |
| bridges | `b1`, `b2` |
| container in `docker` | `clab-<labname>-<node>` (e.g. `clab-dumbbell-s1`) |
| bridge-side interface | `<bridge>-<peer>` (`b1-s1`, `b1-b2`, …), ≤15 chars — you name these in `endpoints:` |
| container-side interface | `eth1`, `eth2`, … in link order |

`prepare_topology.py` compiles the topology into `topology/.deploy.shape.json`,
which `bridges.sh`, `impair.sh` and the samplers all read — nothing discovers
interfaces at runtime.
