# OPTIONAL: the netlab track

**Nothing in Tasks 1–5 needs this** — the required path is Containerlab
(`make deploy`). This is a convenience for students on **native Linux** who
want a more declarative topology tool, with Ansible doing node config. Not for
WSL (same `sch_netem` gap as the main path).

## Use

```bash
pipx install networklab
netlab install ansible containerlab

cd topology/netlab
netlab up      # build + configure the dumbbell
netlab down
```

Scale `n` by editing the `s*`/`d*` nodes and links in `topology.yml`. Keep node
names ≤6 characters (interface-name length limit).

## Shaping

netlab only builds the graph — feed its output into the normal toolchain:

```bash
python topology/prepare_topology.py topology/netlab/clab.yml --out topology/.deploy.clab.yml
sudo bash topology/bridges.sh up   # if netlab didn't make the bridges
sudo bash topology/impair.sh apply
```

Add per-link `vars: {rate:, delay:, limit:}` to `clab.yml` (or to
`topology.yml` before `netlab up`), exactly as in the main path.
