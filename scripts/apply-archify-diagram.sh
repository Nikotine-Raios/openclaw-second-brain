#!/usr/bin/env bash
# Validate architecture IR and freeze Telegram ASCII into AGENTS.md.
set -euo pipefail
if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root: sudo bash $0" >&2
  exit 1
fi

WS=/home/openclaw/.openclaw/workspace
AGENTS="$WS/AGENTS.md"
IR_SRC="${1:-/home/admin/second-brain.architecture.json}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"

[[ -f "$AGENTS" ]] || { echo "missing $AGENTS" >&2; exit 1; }
[[ -f "$IR_SRC" ]] || { echo "missing IR $IR_SRC" >&2; exit 1; }

cp -a "$AGENTS" "$AGENTS.bak-$STAMP"
install -o openclaw -g openclaw -m 600 "$IR_SRC" "$WS/architecture.json"

python3 - "$AGENTS" "$WS/architecture.json" <<'PY'
from pathlib import Path
import json
import sys

agents_path = Path(sys.argv[1])
ir_path = Path(sys.argv[2])
ir = json.loads(ir_path.read_text(encoding="utf-8"))

required = ("schema_version", "diagram_type", "meta", "components", "connections")
missing = [k for k in required if k not in ir]
if missing:
    raise SystemExit(f"IR missing keys: {missing}")
if ir["diagram_type"] != "architecture":
    raise SystemExit("apply script expects diagram_type architecture")

ids = [c["id"] for c in ir["components"]]
if len(ids) != len(set(ids)):
    raise SystemExit("duplicate component ids")
if len(ids) > 12:
    raise SystemExit("more than 12 components; put detail in cards")
idset = set(ids)
path = ir["meta"].get("primary_path") or []
if not path:
    raise SystemExit("meta.primary_path required")
for pid in path:
    if pid not in idset:
        raise SystemExit(f"primary_path unknown id: {pid}")
by_id = {c["id"]: c for c in ir["components"]}
for conn in ir["connections"]:
    if conn["from"] not in idset or conn["to"] not in idset:
        raise SystemExit(f"connection {conn.get('id')} has unknown endpoint")

INNER = 29

def wrap(lines, heavy=False):
    top = "┏" + "━" * INNER + "┓" if heavy else "┌" + "─" * INNER + "┐"
    bot = "┗" + "━" * INNER + "┛" if heavy else "└" + "─" * INNER + "┘"
    bar = "┃" if heavy else "│"
    out = [top]
    for line in lines:
        text = line[:INNER]
        out.append(f"{bar}{text:<{INNER}}{bar}")
    out.append(bot)
    return out

def arrow():
    return "└" + "─" * 14 + "┬" + "─" * 14 + "┘", "┌" + "─" * 14 + "▼" + "─" * 14 + "┐"

rows = []
for i, pid in enumerate(path):
    comp = by_id[pid]
    heavy = comp.get("tag") == "heavy"
    box = wrap(comp["telegram_lines"], heavy=heavy)
    if i == 0:
        rows.extend(box)
        continue
    join_bot, join_top = arrow()
    rows[-1] = join_bot
    box[0] = join_top
    rows.extend(box)

notes = ir.get("telegram_notes") or []
ascii_body = "\n".join(rows + notes)

new_section = f"""## Architecture diagram

When he asks for the architecture, the diagram, or how this works, print the
block below verbatim in a fenced code block. Never reformat it into steps or
prose, never widen it, never switch it to a left-to-right layout. Never add a
box or arrow that is not in workspace architecture.json.

```
{ascii_body}
```
"""

text = agents_path.read_text(encoding="utf-8")
start = text.find("## Architecture diagram")
end = text.find("<!-- END OWNER BLOCK -->")
if start >= 0 and end > start:
    text = text[:start] + new_section + "\n" + text[end:]
else:
    fence = text.find("```\n ┌")
    fence_end = text.find("```", fence + 3) if fence >= 0 else -1
    if fence < 0 or fence_end < 0:
        raise SystemExit("Architecture diagram section not found in AGENTS.md")
    text = text[:fence] + f"```\n{ascii_body}\n```" + text[fence_end + 3 :]
agents_path.write_text(text, encoding="utf-8")
print("validated", ir_path)
print("updated architecture section")
print("nodes", len(ids), "edges", len(ir["connections"]), "cards", len(ir.get("cards") or []))
PY

chown openclaw:openclaw "$AGENTS" "$WS/architecture.json"
chmod 600 "$AGENTS" "$WS/architecture.json"
echo "backup: $AGENTS.bak-$STAMP"
echo "IR: $WS/architecture.json"
echo "In Telegram: /new then ask for the architecture diagram."
