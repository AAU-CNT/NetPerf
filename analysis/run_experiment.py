#!/usr/bin/env python3
"""Run one NetPerf25 network experiment against an already-deployed lab.

Pipeline:

1. read the shape plan → derive flows (``s1→d1``, ``s2→d2``, …), applying any
   per-source iperf3 overrides from the topology node ``vars``
   (``send_rate`` → -b, ``cc`` → -C, ``streams`` → -P)
2. set the congestion-control algorithm in every source netns
3. start an ``iperf3 -s`` on every destination
4. start ``sample_cwnd.sh`` + ``sample_qdisc.sh`` in the background
5. start every ``iperf3 -c`` flow in parallel, ``--json``, for ``--duration`` s
6. write ``results/<ts>__task<t>__<cc>__n<n>__loss<l>/`` per ``analysis/SCHEMA.md``

Standard library only — no matplotlib/pandas/numpy import (that lives in
``plotting/``). Assumes ``make deploy`` already ran (bridges up, lab deployed,
shaping applied).
"""
from __future__ import annotations

import argparse
import json
import os
import platform
import shutil
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

REPO_ROOT = Path(__file__).resolve().parent.parent
ANALYSIS = REPO_ROOT / "analysis"
DEFAULT_PORT = 5201


# --------------------------------------------------------------------------- #
# helpers
# --------------------------------------------------------------------------- #
def _run(cmd: list[str], **kw: Any) -> subprocess.CompletedProcess[str]:
    try:
        return subprocess.run(cmd, text=True, capture_output=True, **kw)
    except FileNotFoundError:
        return subprocess.CompletedProcess(cmd, 127, "", f"{cmd[0]}: not found")


def _docker_prefix() -> list[str]:
    """`docker` if the daemon is reachable directly (user in the docker group),
    else `sudo docker`. tc inside a container works either way (the container
    has NET_ADMIN); host-side we only ever `docker inspect`/`exec`."""
    if _run(["docker", "info"]).returncode == 0:
        return ["docker"]
    if os.geteuid() != 0 and shutil.which("sudo"):
        if _run(["sudo", "-n", "docker", "info"]).returncode == 0:
            return ["sudo", "docker"]
        raise SystemExit(
            "docker is not reachable — add yourself to the 'docker' group "
            "(newgrp docker) or enable passwordless sudo for docker")
    return ["docker"]


# Resolved in main(); a plain default keeps `import run_experiment` side-effect
# free (so the offline tests don't need Docker).
DOCKER: list[str] = ["docker"]
SUDO: list[str] = [] if os.geteuid() == 0 else (
    ["sudo"] if shutil.which("sudo") else [])


def _docker(container: str, *args: str) -> list[str]:
    return [*DOCKER, "exec", container, *args]


def utc_stamp() -> str:
    return datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")


def tool_versions() -> dict[str, str]:
    def first_line(cmd: list[str]) -> str:
        try:
            out = _run(cmd)
            return (out.stdout or out.stderr).splitlines()[0].strip()
        except Exception:
            return "unknown"

    return {
        "iperf3": first_line(["iperf3", "--version"]),
        "tc": first_line([*SUDO, "tc", "-V"]),
        "ss": first_line(["ss", "--version"]),
        "clab": first_line(["clab", "version"]) if shutil.which("clab") else "n/a",
        "kernel": platform.release(),
    }


# --------------------------------------------------------------------------- #
# plan → flows
# --------------------------------------------------------------------------- #
def derive_flows(plan: dict[str, Any], default_cc: str) -> list[dict[str, Any]]:
    """Pair sources sN with destinations dN (the dumbbell convention).

    Per-source iperf3 options from the topology's node `vars` (carried in the
    shape plan's ``flow_opts``) override the run defaults: ``send_rate`` → -b,
    ``cc`` → -C, ``streams`` → -P.
    """
    containers = {
        ep["node"]: ep["container"]
        for link in plan["links"]
        for ep in link["endpoints"]
        if ep["netns"] == "container"
    }
    srcs = sorted(n for n in containers if n.startswith("s"))
    dsts = sorted(n for n in containers if n.startswith("d"))
    if not srcs or not dsts:
        # generic graph: pair container nodes in declaration order, 1st half→2nd
        nodes = list(containers)
        half = len(nodes) // 2
        srcs, dsts = nodes[:half], nodes[half:]
    opts = plan.get("flow_opts", {})
    flows = []
    for i, (s, d) in enumerate(zip(srcs, dsts)):
        o = opts.get(s, {})
        flows.append({
            "name": f"{s}->{d}",
            "src": s, "src_container": containers[s],
            "dst": d, "dst_container": containers[d],
            "dst_ip": plan["ips"][d],
            "port": DEFAULT_PORT + i,
            "cc": o.get("cc", default_cc),
            "send_rate": o.get("send_rate"),          # None → unlimited (-b omitted)
            "streams": int(o.get("streams", 1)),
        })
    return flows


def _iperf_rate(value: str) -> str:
    """Normalise a tc-style rate ("10mbit", "512kbit") to iperf3 -b form
    ("10M", "512K"). Pass anything else straight through."""
    import re
    m = re.match(r"^\s*([0-9.]+)\s*([kmgtKMGT]?)(bit|bps)?\s*$", str(value))
    if not m:
        return str(value).strip()
    return f"{m.group(1)}{m.group(2).upper()}"


def iperf_client_cmd(flow: dict[str, Any], duration: int) -> list[str]:
    """The `iperf3 -c` argument list for one flow (no `docker exec` prefix)."""
    cc = "reno" if flow["cc"] == "reno" else flow["cc"]
    cmd = ["iperf3", "-c", flow["dst_ip"], "-p", str(flow["port"]),
           "-t", str(duration), "-C", cc, "-J"]
    if flow.get("send_rate"):
        cmd += ["-b", _iperf_rate(flow["send_rate"])]
    if flow.get("streams", 1) > 1:
        cmd += ["-P", str(flow["streams"])]
    return cmd


# --------------------------------------------------------------------------- #
# congestion control
# --------------------------------------------------------------------------- #
def _cc_available(container: str) -> list[str]:
    return _run(_docker(container, "sysctl", "-n",
                        "net.ipv4.tcp_available_congestion_control")).stdout.split()


def set_cc(container: str, cc: str) -> None:
    """Set the default congestion control in a container's netns, and verify
    it's available. iperf3 `-C` still overrides this per flow."""
    algo = "reno" if cc == "reno" else cc  # New Reno is "reno" in Linux
    available = _cc_available(container)
    if algo not in available:
        raise SystemExit(
            f"{container}: congestion control '{algo}' not available "
            f"(have: {' '.join(available)}). On the host: modprobe tcp_{algo}"
        )
    res = _run(_docker(container, "sysctl", "-w",
                       f"net.ipv4.tcp_congestion_control={algo}"))
    if res.returncode != 0:
        raise SystemExit(f"{container}: failed to set cc: {res.stderr.strip()}")


# --------------------------------------------------------------------------- #
# experiment
# --------------------------------------------------------------------------- #
def start_servers(flows: list[dict[str, Any]]) -> list[subprocess.Popen[str]]:
    procs = []
    for f in flows:
        _run(_docker(f["dst_container"], "pkill", "-f", "iperf3 -s"))
        p = subprocess.Popen(
            _docker(f["dst_container"], "iperf3", "-s", "-1", "-p", str(f["port"])),
            text=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        procs.append(p)
    time.sleep(1.0)
    return procs


def start_samplers(shape: Path, out_dir: Path, duration: int,
                   interval: float) -> list[subprocess.Popen[str]]:
    common = ["--shape", str(shape), "--duration", str(duration + 3),
              "--interval", str(interval)]
    return [
        subprocess.Popen(
            ["bash", str(ANALYSIS / "sample_cwnd.sh"), *common,
             "--port", "", "--out", str(out_dir / "ss.csv")],
            text=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL),
        subprocess.Popen(
            ["bash", str(ANALYSIS / "sample_qdisc.sh"), *common,
             "--out", str(out_dir / "qdisc.csv")],
            text=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL),
    ]


def run_flows(flows: list[dict[str, Any]], duration: int) -> dict[str, dict[str, Any]]:
    clients: dict[str, subprocess.Popen[str]] = {}
    for f in flows:
        cmd = _docker(f["src_container"], *iperf_client_cmd(f, duration))
        clients[f["name"]] = subprocess.Popen(
            cmd, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    results: dict[str, dict[str, Any]] = {}
    for name, proc in clients.items():
        out, err = proc.communicate()
        if proc.returncode != 0 or not out.strip():
            print(f"  ! flow {name} failed: {err.strip()[:200]}", file=sys.stderr)
            results[name] = {}
            continue
        try:
            results[name] = json.loads(out)
        except json.JSONDecodeError:
            results[name] = {}
    return results


def throughput_mbps(iperf_json: dict[str, Any]) -> float:
    try:
        bps = iperf_json["end"]["sum_received"]["bits_per_second"]
        return round(bps / 1e6, 4)
    except (KeyError, TypeError):
        return 0.0


# --------------------------------------------------------------------------- #
# main
# --------------------------------------------------------------------------- #
def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--task", type=int, required=True)
    p.add_argument("--cc", required=True,
                   choices=["reno", "vegas", "cubic", "bbr"])
    p.add_argument("--n", type=int, default=None,
                   help="dumbbell size label for the results dir "
                        "(default: number of flows derived from the plan)")
    p.add_argument("--loss", type=float, default=0.0)
    p.add_argument("--shape", type=Path,
                   default=REPO_ROOT / "topology" / ".deploy.shape.json")
    p.add_argument("--duration", type=int, default=60)
    p.add_argument("--interval", type=float, default=0.5)
    p.add_argument("--out", type=Path, default=REPO_ROOT / "results")
    return p.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    global DOCKER
    DOCKER = _docker_prefix()
    if not args.shape.is_file():
        raise SystemExit(f"shape plan not found: {args.shape} — run 'make deploy' first")
    plan = json.loads(args.shape.read_text())
    flows = derive_flows(plan, args.cc)
    if not flows:
        raise SystemExit("no source/destination flows derivable from the plan")
    n = args.n if args.n is not None else len(flows)
    overrides = [f for f in flows if f["cc"] != args.cc or f["send_rate"]
                 or f["streams"] > 1]

    bottleneck = next(
        (lk for lk in plan["links"] if lk.get("role") == "bottleneck"),
        plan["links"][-1],
    )
    bp = bottleneck["params"]
    b_ifaces = [ep["iface"] for ep in bottleneck["endpoints"] if ep["netns"] == "host"]

    ts = utc_stamp()
    out_dir = args.out / f"{ts}__task{args.task}__{args.cc}__n{n}__loss{int(args.loss)}"
    out_dir.mkdir(parents=True, exist_ok=True)
    print(f"→ {out_dir.relative_to(REPO_ROOT)}")
    print(f"  {len(flows)} flow(s): {', '.join(f['name'] for f in flows)}")

    for f in flows:
        set_cc(f["src_container"], f["cc"])
    print(f"  congestion control: {args.cc}" + (
        " (per-flow overrides: " + ", ".join(
            f"{f['name']}={f['cc']}"
            + (f",-b{f['send_rate']}" if f["send_rate"] else "")
            + (f",-P{f['streams']}" if f["streams"] > 1 else "")
            for f in overrides) + ")" if overrides else ""))

    servers = start_servers(flows)
    samplers = start_samplers(args.shape, out_dir, args.duration, args.interval)
    print(f"  sampling ss + qdisc every {args.interval}s; running {args.duration}s ...")

    started = datetime.now(timezone.utc).isoformat()
    iperf_results = run_flows(flows, args.duration)

    for p in samplers:
        try:
            p.wait(timeout=10)
        except subprocess.TimeoutExpired:
            p.terminate()
    for p in servers:
        p.poll() is None and p.terminate()

    # flows.csv
    flows_csv = out_dir / "flows.csv"
    with flows_csv.open("w") as fh:
        fh.write("timestamp,task,cc,n,loss,flow,throughput_mbps\n")
        for f in flows:
            tput = throughput_mbps(iperf_results.get(f["name"], {}))
            fh.write(f"{started},{args.task},{args.cc},{n},"
                     f"{args.loss},{f['name']},{tput}\n")

    # raw iperf3 json, for the curious
    (out_dir / "iperf3").mkdir(exist_ok=True)
    for name, blob in iperf_results.items():
        (out_dir / "iperf3" / f"{name.replace('->', '_')}.json").write_text(
            json.dumps(blob, indent=2))

    # run.json
    run_meta = {
        "timestamp": started,
        "task": args.task, "cc": args.cc, "n": n, "loss": args.loss,
        "rate_kbit": _rate_to_kbit(bp.get("rate", "")),
        "delay": bp.get("delay", ""),
        "limit_pkts": int(bp.get("limit") or 0),
        "duration_s": args.duration,
        "sample_interval_s": args.interval,
        "bottleneck_ifaces": b_ifaces,
        "flows": [{"name": f["name"], "src": f["src"], "dst": f["dst"],
                   "port": f["port"], "cc": f["cc"],
                   "send_rate": f["send_rate"], "streams": f["streams"],
                   "client_cmd": " ".join(iperf_client_cmd(f, args.duration))}
                  for f in flows],
        "tools": tool_versions(),
        "host": {"arch": platform.machine(), "os": platform.platform()},
    }
    (out_dir / "run.json").write_text(json.dumps(run_meta, indent=2) + "\n")

    tputs = [throughput_mbps(iperf_results.get(f["name"], {})) for f in flows]
    print(f"  done. mean throughput {sum(tputs) / len(tputs):.2f} Mbit/s "
          f"(total {sum(tputs):.2f})")
    print(f"  wrote flows.csv, ss.csv, qdisc.csv, run.json under {out_dir.name}/")
    return 0


def _rate_to_kbit(rate: str) -> int:
    if not rate:
        return 0
    rate = rate.strip().lower()
    units = {"kbit": 1, "mbit": 1000, "gbit": 1_000_000,
             "kbps": 8, "mbps": 8000}
    for u, mult in units.items():
        if rate.endswith(u):
            try:
                return int(float(rate[: -len(u)]) * mult)
            except ValueError:
                return 0
    try:
        return int(float(rate)) // 1000  # bare bit/s
    except ValueError:
        return 0


if __name__ == "__main__":
    sys.exit(main())
