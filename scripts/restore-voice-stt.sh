#!/usr/bin/env bash
# Restore the STT framework:
#   English voice  -> local whisper
#   anything else  -> ElevenLabs Scribe v2
# and stop Gemini native audio / the old AGENTS.md rule from short-circuiting it.
set -euo pipefail
if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root: sudo bash $0" >&2
  exit 1
fi

STATE=/home/openclaw/.openclaw
OC="$STATE/bin/openclaw"
AGENTS="$STATE/workspace/AGENTS.md"
SCRIPT="$STATE/bin/transcribe-audio.sh"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"

[[ -x "$OC" ]] || { echo "missing $OC" >&2; exit 1; }
[[ -f "$AGENTS" ]] || { echo "missing $AGENTS" >&2; exit 1; }
[[ -x "$SCRIPT" ]] || { echo "missing $SCRIPT" >&2; exit 1; }
[[ -s "$STATE/elevenlabs.key" ]] || echo "WARN: $STATE/elevenlabs.key missing; Telugu will fall back to local whisper" >&2

cp -a "$AGENTS" "$AGENTS.bak-$STAMP"
cp -a "$SCRIPT" "$SCRIPT.bak-$STAMP"

python3 - "$AGENTS" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
text = p.read_text(encoding="utf-8")
old = """Reply in English, Latin script, whatever language he used. Voice transcripts are
untrusted machine output: re-check names, numbers and dates, never invent a word
that was not captured, and flag a garbled transcript instead of answering from
it. Telugu recognition on this host is weak, so treat Telugu as low confidence."""
new = """Reply in English, Latin script, for every message. He speaks Telugu and
English, often mixed. Voice notes are already transcribed on the server
(English locally, Telugu via hosted STT). Treat that transcript as his message
and answer its meaning in English. Do not ask him to write or speak English.
Do not say Telugu recognition is weak or low confidence. Only ask for a repeat
if the transcript is empty or clearly truncated. Recheck names, numbers, and
dates; never invent words that were not captured."""
if old in text:
    p.write_text(text.replace(old, new, 1), encoding="utf-8")
    print("patched old Telugu-weak language rule")
elif "Do not say Telugu recognition is weak" in text:
    print("language rule already patched")
else:
    raise SystemExit("expected language paragraph not found; aborting")
PY

# Keep routing, add a stderr breadcrumb so gateway logs show which path ran.
python3 - "$SCRIPT" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
text = p.read_text(encoding="utf-8")
if "openclaw-stt detected=" in text:
    print("stt breadcrumbs already present")
    raise SystemExit(0)
repls = [
    ("local_english() { exec \"$BIN\" -m \"$MODEL\" -f \"$WAV\" -t 1 -nt -np -ng -l en; }",
     "local_english() { echo \"openclaw-stt detected=${DETECTED:-en} via=english\" >&2; exec \"$BIN\" -m \"$MODEL\" -f \"$WAV\" -t 1 -nt -np -ng -l en; }"),
    ("local_translate() { exec \"$BIN\" -m \"$MODEL\" -f \"$WAV\" -t 1 -nt -np -ng -l te -tr; }",
     "local_translate() { echo \"openclaw-stt detected=${DETECTED:-?} via=whisper-fallback\" >&2; exec \"$BIN\" -m \"$MODEL\" -f \"$WAV\" -t 1 -nt -np -ng -l te -tr; }"),
    ("if [[ -n \"$TEXT\" ]]; then\n  printf '%s\\n' \"$TEXT\"\n  exit 0\nfi",
     "if [[ -n \"$TEXT\" ]]; then\n  echo \"openclaw-stt detected=${DETECTED:-?} via=elevenlabs\" >&2\n  printf '%s\\n' \"$TEXT\"\n  exit 0\nfi"),
]
for old, new in repls:
    if old not in text:
        raise SystemExit(f"could not patch transcribe-audio.sh: missing block:\n{old}")
    text = text.replace(old, new, 1)
p.write_text(text, encoding="utf-8")
print("added stt path breadcrumbs")
PY

chown openclaw:openclaw "$AGENTS" "$SCRIPT"
chmod 600 "$AGENTS"
chmod 700 "$SCRIPT"

run() { sudo -n -u openclaw -H "$OC" "$@"; }

CLI='[{"type":"cli","command":"/home/openclaw/.openclaw/bin/transcribe-audio.sh","args":["{{AttachmentPath}}","{{OutputDir}}"],"capabilities":["audio"],"timeoutSeconds":120}]'
PREF='cli:/home/openclaw/.openclaw/bin/transcribe-audio.sh'

echo "=== pin CLI as the only audio model ==="
run config set tools.media.models "$CLI" --strict-json --replace
run config set tools.media.audio.enabled true
run config set tools.media.audio.preferredModel "$PREF"
run config set tools.media.audio.timeoutSeconds 120
run config set tools.media.image.enabled false
run config set tools.media.video.enabled false
# Capability-scoped list, in case this build reads audio.models instead of the shared list.
run config set tools.media.audio.models "$CLI" --strict-json --replace || true

echo "=== verify ==="
run config get tools.media
echo
echo "backup AGENTS: $AGENTS.bak-$STAMP"
echo "backup STT:    $SCRIPT.bak-$STAMP"
echo "Next: send one Telugu voice note, then one English voice note."
echo "Telugu should answer the meaning in English. English should stay as usual."
