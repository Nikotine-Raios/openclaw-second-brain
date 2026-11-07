#!/usr/bin/env bash
# Show what whisper actually does with the most recent voice note.
# Read-only: changes no config and writes nothing outside /tmp.
#
# Run as root:  sudo bash /home/admin/diagnose-telugu-stt.sh
set -uo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root: sudo bash $0" >&2
  exit 1
fi

STATE=/home/openclaw/.openclaw
ROOT="$STATE/opt/whisper-bin-ubuntu-x64"
BIN="$ROOT/whisper-cli"
MODEL_BASE="$STATE/models/ggml-base.bin"
MODEL_TINY="$STATE/models/ggml-tiny.bin"
WORK="$(mktemp -d /tmp/stt-diag.XXXXXX)"
chmod 755 "$WORK"

echo "=== newest audio attachments seen by OpenClaw ==="
mapfile -t FOUND < <(find "$STATE" -type f \
  \( -iname '*.ogg' -o -iname '*.oga' -o -iname '*.opus' -o -iname '*.m4a' -o -iname '*.mp3' -o -iname '*.wav' \) \
  -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -10)

if [[ "${#FOUND[@]}" -eq 0 ]]; then
  echo "No audio files found under $STATE."
  echo "Send the bot a Telugu voice note, wait for its reply, then re-run this."
  rm -rf "$WORK"
  exit 1
fi

for line in "${FOUND[@]}"; do
  ts="${line%% *}"
  path="${line#* }"
  printf '  %s  %s\n' "$(date -d "@${ts%.*}" '+%Y-%m-%d %H:%M:%S')" "$path"
done

AUDIO="${FOUND[0]#* }"
echo
echo "Using newest: $AUDIO"

echo "=== convert to 16k mono wav ==="
/usr/bin/ffmpeg -hide_banner -loglevel error -y -i "$AUDIO" -ar 16000 -ac 1 -c:a pcm_s16le "$WORK/a.wav"
ls -l "$WORK/a.wav"
echo "duration: $(/usr/bin/ffprobe -v error -show_entries format=duration -of csv=p=0 "$WORK/a.wav" 2>/dev/null || echo unknown) s"

export LD_LIBRARY_PATH="$ROOT${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
cd "$ROOT"

echo
echo "=== A. what language does -dl think this is? (this drives the routing) ==="
"$BIN" -m "$MODEL_BASE" -f "$WORK/a.wav" -t 1 -ng -dl 2>&1 | tail -5

echo
echo "=== B. base model, forced Telugu, TRANSLATED to English (current path) ==="
"$BIN" -m "$MODEL_BASE" -f "$WORK/a.wav" -t 1 -nt -np -ng -l te -tr 2>/dev/null

echo
echo "=== C. base model, forced Telugu, kept as Telugu script ==="
"$BIN" -m "$MODEL_BASE" -f "$WORK/a.wav" -t 1 -nt -np -ng -l te 2>/dev/null

echo
echo "=== D. base model, plain English (what happens if detection says en) ==="
"$BIN" -m "$MODEL_BASE" -f "$WORK/a.wav" -t 1 -nt -np -ng -l en 2>/dev/null

echo
echo "=== E. old tiny model, forced Telugu translated (for comparison) ==="
if [[ -s "$MODEL_TINY" ]]; then
  "$BIN" -m "$MODEL_TINY" -f "$WORK/a.wav" -t 1 -nt -np -ng -l te -tr 2>/dev/null
else
  echo "(tiny model not present)"
fi

rm -rf "$WORK"
echo
echo "Compare B through E against what you actually said."
echo "If none are close, local whisper cannot do your Telugu and a hosted"
echo "provider is the only real fix."
