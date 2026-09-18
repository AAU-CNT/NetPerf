# containerlab web-editor node templates

The [containerlab web editor](https://srl-labs.github.io/containerlab-app/)'s
default palette has NOS nodes (Nokia SRL, Arista, …), not the two kinds these
labs use: a Linux host (`kind: linux`) and a bridge (`kind: bridge`).

**You usually don't need this.** The editor opens an existing `*.clab.yml` and
puts every node on the canvas — open `topology/dumbbell.clab.yml`, copy-paste a
node to add one, edit the YAML pane for names and `vars:`, save. You only need
a template to add a node kind from a blank canvas.

If you do: **Node Templates → template editor** (the browser sandbox can't
import a file, so enter these by hand):

| field | `labhost` node | `bridge` node |
|---|---|---|
| kind | `linux` | `bridge` |
| image | `netperf25/labhost:latest` | *(none)* |
| interfacePattern | `eth{n}` | rename each interface by hand to `<bridge>-<peer>`, ≤15 chars |

(`netperf25-templates.json` in this folder has the same values for the VS Code
containerlab extension, which can import templates.)
