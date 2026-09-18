# `bootstrap/`

`make bootstrap` (`install.sh`) installs Docker, containerlab, the kernel
modules (`sch_netem`, `tcp_vegas`, `tcp_bbr`), and the Python venv. Idempotent
— safe to re-run.

**After it finishes:** log out and back in once (or `newgrp docker`) so your
new `docker` group membership takes effect.

`make check` (`preflight.sh`) verifies all of it — sudo, tools, the Docker
daemon, the kernel modules, a live `tc netem` test, which congestion-control
algorithms are loaded — and prints `ENV OK` or lists what's missing. Safe to
run anytime; run it whenever something misbehaves.
