#!/usr/bin/env python3
"""SKELETON — load one results run and plot it.

    ../.venv/bin/python plot_example.py ../results/<run-dir>

Copy this and build whatever figures your report needs. Column meanings for
flows.csv / ss.csv / qdisc.csv: ../analysis/SCHEMA.md.
"""
import sys
from pathlib import Path

import matplotlib
matplotlib.use("Agg")  # save to a file instead of opening a window
import matplotlib.pyplot as plt
import pandas as pd


def main() -> int:
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    run = Path(sys.argv[1])

    flows = pd.read_csv(run / "flows.csv")
    ss = pd.read_csv(run / "ss.csv")
    qdisc = pd.read_csv(run / "qdisc.csv")
    print(flows)

    # Example: congestion window vs time, one line per flow.
    fig, ax = plt.subplots()
    for flow, g in ss.groupby("flow"):
        ax.plot(pd.to_datetime(g["timestamp"]), g["cwnd"], label=flow)
    ax.set_xlabel("time")
    ax.set_ylabel("cwnd (segments)")
    ax.legend()

    out = run / "plot.png"
    fig.savefig(out)
    print(f"wrote {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
