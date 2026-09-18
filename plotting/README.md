# `plotting/` — turn the result CSVs into figures

You make the figures for your report — this folder is just a starting point:
`requirements.txt` and one example script.

## Setup

If you ran `make bootstrap`, the repo venv at `../.venv` **already has**
matplotlib, pandas and numpy — just use it:

```bash
../.venv/bin/python plot_example.py ../results/<run-dir>
```

Prefer an isolated environment? From this folder:

```bash
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
.venv/bin/python plot_example.py ../results/<run-dir>
```

(`.venv/` here is git-ignored.)

## `plot_example.py`

Loads one run's `flows.csv` / `ss.csv` / `qdisc.csv` and plots congestion
window vs time as a starting example. Copy it and extend it into whatever
figures your report needs. Column meanings: `../analysis/SCHEMA.md`.
