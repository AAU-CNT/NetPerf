#!/usr/bin/env python3
"""Compile a student-authored ``*.clab.yml`` into a deploy-ready pair:

* ``<out>``                     the containerlab file to ``clab deploy`` — the
                                student's nodes/links, plus injected data-plane
                                IP assignment (``exec:``), with the shaping
                                ``vars`` stripped (containerlab ignores them).
* ``<out>`` → ``.shape.json``   the per-link-end shaping plan that
                                ``bridges.sh``, ``impair.sh`` and the samplers
                                consume.

The **student format is a normal containerlab topology** (build it in the
containerlab web editor at https://srl-labs.github.io/containerlab-app/, or
edit a shipped starter). Link impairments live in a per-link ``vars`` map:

    topology:
      nodes:
        s1: {kind: linux, image: netperf25/labhost:latest}
        b1: {kind: bridge}
        b2: {kind: bridge}
        d1: {kind: linux, image: netperf25/labhost:latest}
      links:
        - endpoints: ["s1:eth1", "b1:b1-s1"]
        - endpoints: ["b1:b1-b2", "b2:b2-b1"]
          vars: {rate: 1500kbit, delay: 20ms, loss: 0, limit: 100}
        - endpoints: ["d1:eth1", "b2:b2-d1"]

Rules:
* a node with ``kind: bridge`` is a host Linux bridge (created by ``bridges.sh``);
  everything else is a container (``kind`` defaults to ``linux``, image defaults
  to the labhost image).
* interface names are taken verbatim from ``endpoints`` — pick bridge-side names
  ≤ 15 chars and unique (they become veths in the host root netns).
* a link between two bridges is auto-tagged ``bottleneck``.
* ``vars`` keys: ``rate`` (tc syntax, e.g. ``10mbit``/``512kbit``), ``delay``,
  ``jitter``, ``loss`` (percent), ``limit`` (packets). Anything unset is
  unshaped.

Usage:
    python topology/prepare_topology.py tasks/task2_bufferbloat/topology.clab.yml \\
        --out topology/.deploy.clab.yml
"""
from __future__ import annotations

import argparse
import ipaddress
import json
import re
import sys
from pathlib import Path
from typing import Any

import yaml

DEFAULT_IMAGE = "netperf25/labhost:latest"
DEFAULT_SUBNET = "10.0.0.0/16"
HOST_OFFSET = 10          # first data-plane host is .11, leaving .1-.10 free
IFNAMSIZ = 15             # Linux hard limit on interface name length

NAME_RE = re.compile(r"^[a-zA-Z][a-zA-Z0-9_-]{0,14}$")

# link-level `vars` — the tc shaping applied to that link end
SHAPE_KEYS = ("rate", "delay", "jitter", "loss", "limit")
SHAPE_DEFAULTS: dict[str, Any] = {
    "rate": "", "delay": "", "jitter": "", "loss": 0, "limit": 1000,
}

# node-level `vars` — per-flow iperf3 options for a source node
#   send_rate → iperf3 -b   (application target bitrate, e.g. "3mbit")
#   cc        → iperf3 -C   (congestion control for this flow only)
#   streams   → iperf3 -P   (parallel TCP streams in this flow)
FLOW_KEYS = ("send_rate", "cc", "streams")
KNOWN_CC = ("reno", "cubic", "vegas", "bbr")


class TopologyError(ValueError):
    """A problem with the student's *.clab.yml."""


# --------------------------------------------------------------------------- #
# parsing
# --------------------------------------------------------------------------- #
def _endpoint_parts(ep: Any) -> tuple[str, str]:
    """Accept the short form ``"node:iface"`` and the extended-format mapping
    ``{node: x, interface: y}``."""
    if isinstance(ep, str):
        if ":" not in ep:
            raise TopologyError(f"endpoint {ep!r} is not 'node:interface'")
        node, iface = ep.split(":", 1)
        return node.strip(), iface.strip()
    if isinstance(ep, dict) and "node" in ep and "interface" in ep:
        return str(ep["node"]).strip(), str(ep["interface"]).strip()
    raise TopologyError(f"cannot read endpoint {ep!r}")


def _link_endpoints(link: dict[str, Any]) -> list[tuple[str, str]]:
    eps = link.get("endpoints")
    if not isinstance(eps, list) or len(eps) != 2:
        raise TopologyError(f"link {link!r}: 'endpoints' must be a list of 2")
    return [_endpoint_parts(e) for e in eps]


def load_clab(path: Path) -> dict[str, Any]:
    doc = yaml.safe_load(path.read_text())
    if not isinstance(doc, dict) or "topology" not in doc:
        raise TopologyError(f"{path}: not a containerlab topology (no 'topology:')")
    topo = doc["topology"]
    if not isinstance(topo.get("nodes"), dict) or not topo["nodes"]:
        raise TopologyError(f"{path}: topology.nodes must be a non-empty mapping")
    if not isinstance(topo.get("links"), list) or not topo["links"]:
        raise TopologyError(f"{path}: topology.links must be a non-empty list")
    doc.setdefault("name", path.name.split(".")[0])
    return doc


# --------------------------------------------------------------------------- #
# compile
# --------------------------------------------------------------------------- #
def compile_topology(doc: dict[str, Any], *, subnet: str = DEFAULT_SUBNET,
                     image: str = DEFAULT_IMAGE) -> tuple[dict[str, Any], dict[str, Any]]:
    lab = doc["name"]
    if not NAME_RE.match(lab):
        raise TopologyError(f"lab name {lab!r} is not a valid identifier")
    net = ipaddress.ip_network(subnet, strict=False)
    topo = doc["topology"]
    defaults_kind = (topo.get("defaults") or {}).get("kind", "linux")

    raw_nodes: dict[str, Any] = topo["nodes"]
    kinds: dict[str, str] = {}
    for name, cfg in raw_nodes.items():
        if not NAME_RE.match(name):
            raise TopologyError(f"node name {name!r} is not a valid identifier "
                                "(letter first, [A-Za-z0-9_-], ≤15 chars)")
        kinds[name] = (cfg or {}).get("kind", defaults_kind)

    # --- interfaces come from the file; validate the bridge-side ones -------
    used_root_ifaces: set[str] = set()
    first_iface: dict[str, str] = {}
    parsed_links: list[dict[str, Any]] = []

    for idx, link in enumerate(topo["links"]):
        (na, ia), (nb, ib) = _link_endpoints(link)
        for n in (na, nb):
            if n not in kinds:
                raise TopologyError(f"link {idx}: unknown node {n!r}")
        for n, i in ((na, ia), (nb, ib)):
            if kinds[n] == "bridge":
                if len(i) > IFNAMSIZ:
                    raise TopologyError(
                        f"link {idx}: bridge interface {i!r} > {IFNAMSIZ} chars")
                if i in used_root_ifaces:
                    raise TopologyError(
                        f"link {idx}: bridge interface {i!r} used twice "
                        "(root-netns veth names must be unique)")
                used_root_ifaces.add(i)
            first_iface.setdefault(n, i)

        role = "bottleneck" if kinds[na] == "bridge" and kinds[nb] == "bridge" else ""
        params = dict(SHAPE_DEFAULTS)
        params.update({k: v for k, v in (link.get("vars") or {}).items()
                       if k in SHAPE_KEYS})
        params["loss"] = float(params["loss"] or 0)
        params["limit"] = int(params["limit"] or 0)
        parsed_links.append({
            "role": role, "params": params,
            "a": na, "a_iface": ia, "b": nb, "b_iface": ib,
        })

    # --- data-plane IP assignment + per-node flow options --------------- #
    hosts = net.hosts()
    for _ in range(HOST_OFFSET):
        next(hosts, None)
    ips: dict[str, str] = {}
    flow_opts: dict[str, dict[str, Any]] = {}
    for name, kind in kinds.items():
        if kind == "bridge":
            continue
        cfg = raw_nodes[name] or {}
        nvars = cfg.get("vars") or {}
        explicit = cfg.get("mgmt-ipv4") or nvars.get("ipv4")
        ips[name] = str(explicit).split("/")[0] if explicit else str(next(hosts))
        if name not in first_iface:
            raise TopologyError(f"node {name!r} has no links")
        opts = {k: nvars[k] for k in FLOW_KEYS if k in nvars}
        if opts:
            flow_opts[name] = _validate_flow_opts(name, opts)

    # --- build the deploy clab doc (inject exec, default image, drop vars) - #
    out_nodes: dict[str, Any] = {}
    for name, cfg in raw_nodes.items():
        cfg = dict(cfg or {})
        cfg.pop("vars", None)
        if kinds[name] == "bridge":
            out_nodes[name] = {"kind": "bridge"}
            continue
        cfg["kind"] = kinds[name]
        cfg.setdefault("image", image)
        dev = first_iface[name]
        exec_lines = list(cfg.get("exec") or [])
        exec_lines += [
            f"ip link set {dev} up",
            f"ip addr replace {ips[name]}/{net.prefixlen} dev {dev}",
        ]
        cfg["exec"] = exec_lines
        out_nodes[name] = cfg

    out_links = [{"endpoints": [f"{lk['a']}:{lk['a_iface']}",
                                f"{lk['b']}:{lk['b_iface']}"]}
                 for lk in parsed_links]

    deploy_doc = {"name": lab, "topology": {"nodes": out_nodes, "links": out_links}}
    for key in ("prefix", "mgmt"):
        if key in doc:
            deploy_doc[key] = doc[key]

    shape_plan = {
        "lab": lab,
        "prefix": f"clab-{lab}",
        "bridges": [n for n, k in kinds.items() if k == "bridge"],
        "ips": ips,
        "flow_opts": flow_opts,
        "links": [
            {
                "role": lk["role"],
                "params": lk["params"],
                "endpoints": [
                    _shape_endpoint(lab, lk["a"], kinds[lk["a"]], lk["a_iface"]),
                    _shape_endpoint(lab, lk["b"], kinds[lk["b"]], lk["b_iface"]),
                ],
            }
            for lk in parsed_links
        ],
    }
    return deploy_doc, shape_plan


def _shape_endpoint(lab: str, node: str, kind: str, iface: str) -> dict[str, Any]:
    if kind == "bridge":
        return {"node": node, "iface": iface, "netns": "host"}
    return {"node": node, "iface": iface, "netns": "container",
            "container": f"clab-{lab}-{node}"}


def _validate_flow_opts(node: str, opts: dict[str, Any]) -> dict[str, Any]:
    out: dict[str, Any] = {}
    if "send_rate" in opts:
        r = str(opts["send_rate"]).strip()
        if not r:
            raise TopologyError(f"node {node!r}: empty send_rate")
        out["send_rate"] = r
    if "cc" in opts:
        cc = str(opts["cc"]).strip().lower()
        if cc not in KNOWN_CC:
            raise TopologyError(
                f"node {node!r}: cc {cc!r} not one of {', '.join(KNOWN_CC)}")
        out["cc"] = cc
    if "streams" in opts:
        try:
            s = int(opts["streams"])
        except (TypeError, ValueError):
            raise TopologyError(f"node {node!r}: streams must be an integer")
        if s < 1:
            raise TopologyError(f"node {node!r}: streams must be >= 1")
        out["streams"] = s
    return out


# --------------------------------------------------------------------------- #
# cli
# --------------------------------------------------------------------------- #
def _shape_path(out: Path) -> Path:
    name = out.name
    for suffix in (".clab.yml", ".clab.yaml", ".yml", ".yaml"):
        if name.endswith(suffix):
            return out.with_name(name[: -len(suffix)] + ".shape.json")
    return out.with_suffix(".shape.json")


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("topology", type=Path, help="the student-authored *.clab.yml")
    p.add_argument("--out", type=Path, required=True,
                   help="deploy-ready clab file to write (shape.json goes beside it)")
    p.add_argument("--subnet", default=DEFAULT_SUBNET, help="data-plane L2 subnet")
    p.add_argument("--image", default=DEFAULT_IMAGE, help="default node image")
    return p.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    if not args.topology.is_file():
        raise SystemExit(f"topology not found: {args.topology}")
    try:
        doc = load_clab(args.topology)
        deploy_doc, shape_plan = compile_topology(
            doc, subnet=args.subnet, image=args.image)
    except TopologyError as exc:
        raise SystemExit(f"✗ {args.topology}: {exc}")

    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(
        "# GENERATED from %s by prepare_topology.py — do not edit.\n"
        "# Edit the source topology and re-run `make deploy`.\n"
        % args.topology.name
        + yaml.safe_dump(deploy_doc, sort_keys=False))
    shape_path = _shape_path(args.out)
    shape_path.write_text(json.dumps(shape_plan, indent=2) + "\n")

    n_nodes = len(deploy_doc["topology"]["nodes"])
    n_links = len(deploy_doc["topology"]["links"])
    n_bott = sum(1 for lk in shape_plan["links"] if lk["role"] == "bottleneck")
    print(f"wrote {args.out}  ({n_nodes} nodes, {n_links} links, "
          f"{n_bott} bottleneck)")
    print(f"wrote {shape_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
