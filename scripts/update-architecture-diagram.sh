#!/usr/bin/env bash
# Refresh the Telegram ASCII architecture diagram to match live wiring:
# Groq -> Gemini -> GPT, English Whisper, Telugu ElevenLabs.
set -euo pipefail
if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root: sudo bash $0" >&2
  exit 1
fi

AGENTS=/home/openclaw/.openclaw/workspace/AGENTS.md
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
[[ -f "$AGENTS" ]] || { echo "missing $AGENTS" >&2; exit 1; }
cp -a "$AGENTS" "$AGENTS.bak-$STAMP"

python3 - "$AGENTS" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
text = p.read_text(encoding="utf-8")
old_limits = """explicitly asks. Audio is transcribed on the server and never sent outside it."""
new_limits = """explicitly asks. English audio stays on the server. Telugu audio goes to
ElevenLabs for transcription only. Replies are English text."""
old_diagram = """```
 ┌─────────────────────────────┐
 │ YOU · phone                 │
 └──────────────┬──────────────┘
 ┌──────────────▼──────────────┐
 │ TELEGRAM · delivery only    │
 └──────────────┬──────────────┘
 ┏━━━━━━━━━━━━━━▼━━━━━━━━━━━━━━┓
 ┃ YOUR SERVER · the brain     ┃
 ┃ voice -> text, local        ┃
 ┃ memory, owns all schedules  ┃
 ┗━━━━━━━━━━━━━━┳━━━━━━━━━━━━━━┛
 ┌──────────────▼──────────────┐
 │ OPENAI · writes the reply   │
 └──────────────┬──────────────┘
 ┌──────────────▼──────────────┐
 │ BACK TO YOU · English       │
 └─────────────────────────────┘
 Audio stops at YOUR SERVER.
"""
new_diagram = """```
 ┌─────────────────────────────┐
 │ YOU · phone                 │
 └──────────────┬──────────────┘
 ┌──────────────▼──────────────┐
 │ TELEGRAM · delivery only    │
 └──────────────┬──────────────┘
 ┏━━━━━━━━━━━━━━▼━━━━━━━━━━━━━━┓
 ┃ YOUR SERVER · the brain     ┃
 ┃ EN voice = Whisper          ┃
 ┃ TE voice = ElevenLabs       ┃
 ┃ memory, owns all schedules  ┃
 ┗━━━━━━━━━━━━━━┳━━━━━━━━━━━━━━┛
 ┌──────────────▼──────────────┐
 │ GROQ · writes the reply     │
 │ else Gemini, then GPT       │
 └──────────────┬──────────────┘
 ┌──────────────▼──────────────┐
 │ BACK TO YOU · English       │
 └─────────────────────────────┘
 English STT stays on the server.
 Telugu STT uses ElevenLabs.
"""
changed = 0
if old_limits in text:
    text = text.replace(old_limits, new_limits, 1)
    changed += 1
    print("updated limits")
elif "Telugu audio goes to" in text:
    print("limits already updated")
else:
    print("limits paragraph not found (left as-is)")
if old_diagram in text:
    text = text.replace(old_diagram, new_diagram, 1)
    changed += 1
    print("updated diagram")
elif "GROQ · writes the reply" in text:
    print("diagram already updated")
else:
    raise SystemExit("expected diagram not found; aborting")
p.write_text(text, encoding="utf-8")
print("wrote", p)
PY

chown openclaw:openclaw "$AGENTS"
chmod 600 "$AGENTS"
echo "backup: $AGENTS.bak-$STAMP"
echo "In Telegram: /new then ask for the architecture diagram."
