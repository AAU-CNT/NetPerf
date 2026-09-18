# Environments — setup & troubleshooting

The labs need a Linux kernel with **`sch_netem`** and the TCP congestion-control
modules (`tcp_vegas`, `tcp_bbr`), Docker, and root/`sudo`. Three environments
are supported, in decreasing order of "just works".

Run `make check` (⇒ `bootstrap/preflight.sh`) at any point — it tells you
exactly what's missing.

---

## 1. Native Linux (Ubuntu) — reference

The setup everything is tested against.

```bash
git clone <repo> netperf25-labs && cd netperf25-labs
make bootstrap      # Docker, containerlab, venv, kernel modules
make check          # → ENV OK
```

`make bootstrap` is non-interactive. It adds you to the `docker` group — log out
and back in (or `newgrp docker`) once, afterwards.

Ubuntu 22.04 or 24.04, amd64. Debian 12 works too. Other distros: install
Docker + containerlab yourself, `pip install jinja2 pyyaml pytest` into `.venv/`,
ensure the three kernel modules load, then `make check`.

Disk: the `labhost` image is ~150 MB; each container adds little. RAM: see the
table below.

---

## 2. Raspberry Pi (Ubuntu arm64) — works, watch RAM

Use **Ubuntu Server 24.04 arm64** (not Raspberry Pi OS — its kernel is missing
modules). A Pi 4 / Pi 5 with **4 GB+** is fine for small `n`.

```bash
make bootstrap && make check
```

The `labhost` image is multi-arch, so `make build` produces an arm64 image
automatically. Everything else is identical.

**RAM budget** (rough, whole dumbbell):

| `n` | containers | approx RAM |
|---|---|---|
| 1 | 2 | ~120 MB |
| 4 | 8 | ~400 MB |
| 8 | 16 | ~800 MB |
| 16 | 32 | ~1.6 GB |

Add ~300 MB for Docker + the host. On a 4 GB Pi, keep `n ≤ 12`. If deploys start
failing, `docker system prune` and drop `n`.

SD-card wear: put Docker's data-root on an SSD/USB3 drive if you run many
experiments (`/etc/docker/daemon.json` → `"data-root"`).

---

## 3. WSL2 — moderate; the default kernel is the problem

The stock WSL2 kernel is built **without `sch_netem`** and often without the
extra CC modules. `make check` will show:

```
✗ unavailable: sch_netem  (WSL? see docs/environments.md)
✗ tc netem failed — sch_netem not usable on this kernel
```

You have three options.

### Option A — run the labs on native Linux or a Pi instead

Fastest path. Task 1 (compression) runs fine on WSL regardless; only Tasks 2–5
need netem.

### Option B — build a custom WSL kernel with the modules

1. On Windows, find your kernel version: `wsl --version` / `uname -r` in WSL.
2. In WSL, get the matching source and config:
   ```bash
   sudo apt-get install -y build-essential flex bison libssl-dev libelf-dev bc dwarves
   git clone --depth 1 --branch linux-msft-wsl-$(uname -r | cut -d- -f1) \
     https://github.com/microsoft/WSL2-Linux-Kernel.git
   cd WSL2-Linux-Kernel
   cp Microsoft/config-wsl .config
   ```
3. Enable the modules — set these in `.config` (or via `make menuconfig`):
   ```
   CONFIG_NET_SCH_NETEM=y
   CONFIG_NET_SCH_HTB=y
   CONFIG_NET_SCH_FQ_CODEL=y
   CONFIG_TCP_CONG_VEGAS=y
   CONFIG_TCP_CONG_BBR=y
   CONFIG_NET_SCH_FQ=y
   ```
4. Build and install:
   ```bash
   make -j"$(nproc)"
   mkdir -p /mnt/c/Users/<you>/wsl-kernel
   cp arch/x86/boot/bzImage /mnt/c/Users/<you>/wsl-kernel/bzImage
   ```
5. On Windows, create `C:\Users\<you>\.wslconfig`:
   ```ini
   [wsl2]
   kernel=C:\\Users\\<you>\\wsl-kernel\\bzImage
   ```
6. `wsl --shutdown` from PowerShell, reopen WSL, `make check`.

### Option C — a Linux VM inside WSL

Run a real Ubuntu VM (multipass, or Hyper-V) and use that. Heavier but no kernel
build.

### WSL notes

- Docker Desktop's WSL integration works, but `systemctl` may not — start
  `dockerd` manually or use Docker Desktop.
- `make bootstrap` detects WSL and won't fail on the missing
  `linux-modules-extra` package; it just warns.
- **CI does not assume WSL can run the suite** — a green CI run does not mean
  your WSL box will work. Trust `make check`, not CI, for your machine.

---

## Common failures

| Symptom | Fix |
|---|---|
| `docker: permission denied` | `newgrp docker` or log out/in after `make bootstrap` |
| `make deploy` hangs pulling `netperf25/labhost` | `make build` first, or check internet/registry access |
| `cc not loaded yet: vegas/bbr` in `make check` | `sudo modprobe tcp_vegas tcp_bbr` (bootstrap persists this in `/etc/modules-load.d/netperf25.conf`) |
| `bridges.sh: bridge b1 already exists` after a crash | harmless (idempotent); `make destroy` or `sudo ip link del b1` to clean |
| `prepare_topology.py: bridge interface … > 15 chars` | shorten a bridge-side interface name in your `*.clab.yml` `endpoints` (keep bridge + peer names short) |
| `prepare_topology.py: … used twice` | two links gave a bridge the same interface name — each veth needs a unique name |
| `ss.csv` empty | flows never established — check `docker exec clab-dumbbell-s1 ping <d1>`; bridges up? shaping too aggressive (`loss` 100)? |
| Pi: deploy fails at ~`n=14` | out of RAM — lower `n`, `docker system prune` |
| everything is slow / `iperf3` far below the rate cap | offload not disabled on a veth — `impair.sh` tries `ethtool -K`; install `ethtool` |
