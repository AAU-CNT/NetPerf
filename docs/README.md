# `docs/`

Background and setup material. Neither file is needed to *run* the labs, but
`environments.md` is the first stop when `make check` complains.

| File | What |
|---|---|
| `environments.md` | Native Linux, Raspberry Pi, and WSL2 setup + a troubleshooting table. Includes the WSL custom-kernel build for `sch_netem`. |
| `mininet-mapping.md` | Concept dictionary: every Mininet idea (`Topo`, `TCLink`, `tcp_probe`, …) and its equivalent here. Read this if you've done the Mininet version before. |

The student-facing entry point is the repo-root `README.md`. Design decisions
and conventions live in `CLAUDE.md`; the build plan in `PLAN.md`.
