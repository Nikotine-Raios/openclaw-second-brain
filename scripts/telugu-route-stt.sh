#!/usr/bin/env bash
# Stop Telugu being transcribed as Tamil.
#
# Plain "-l auto" picks from ~99 languages and keeps choosing Tamil for Telugu
# speech, because this whisper build has no --language-candidates to constrain
# it. Instead of forcing "-l te" (which would wreck English voice notes the same
# way "-l en" wrecked Telugu), detect first and then route:
#
#   detected en            -> transcribe as English
#   detected any Indic lang -> transcribe as Telugu
#
# A Tamil/Kannada/Malayalam/Hindi guess is treated as "this is Telugu", because
# those are exactly the languages Whisper confuses Telugu with.
#
# Run once as root:  sudo bash /home/admin/telugu-route-stt.sh
set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root: sudo bash $0" >&2
  exit 1
fi

STATE=/home/openclaw/.openclaw
ROOT="$STATE/opt/whisper-bin-ubuntu-x64"
SCRIPT="$STATE/bin/transcribe-audio.sh"
MODEL="$STATE/models/ggml-base.bin"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"

for p in "$ROOT/whisper-cli" "$SCRIPT" "$MODEL"; do
  [[ -e "$p" ]] || { echo "missing required path: $p" >&2; exit 1; }
done

echo "=== check for language-detection support ==="
if ! sudo -u openclaw -H "$ROOT/whisper-cli" --help 2>&1 | grep -qE -- '(-dl|--detect-language)'; then
  echo "This whisper build has no --detect-language, so two-pass routing is not" >&2
  echo "possible. Falling back to forcing Telugu; English voice notes will suffer." >&2
  FALLBACK=1
else
  echo "--detect-language is available; using two-pass routing"
  FALLBACK=0
fi

echo "=== patch transcribe-audio.sh ==="
cp -a "$SCRIPT" "$SCRIPT.bak-$STAMP"
echo "backup: $SCRIPT.bak-$STAMP"

NEWSCRIPT="$(mktemp /tmp/transcribe-audio.XXXXXX.sh)"

if [[ "$FALLBACK" -eq 1 ]]; then
  cat >"$NEWSCRIPT" <<EOF
#!/bin/bash
set -euo pipefail
INPUT="\${1:?missing audio path}"
OUTDIR="\${2:-\${TMPDIR:-$STATE/tmp}}"
ROOT="$ROOT"
MODEL="$MODEL"
BIN="\$ROOT/whisper-cli"
WAV="\$OUTDIR/stt.wav"
mkdir -p "\$OUTDIR"
export LD_LIBRARY_PATH="\$ROOT\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
cd "\$ROOT"
/usr/bin/ffmpeg -hide_banner -loglevel error -y -i "\$INPUT" -ar 16000 -ac 1 -c:a pcm_s16le "\$WAV"
# No detect-language support in this build: force Telugu.
"\$BIN" -m "\$MODEL" -f "\$WAV" -t 1 -nt -np -ng -l te
EOF
else
  cat >"$NEWSCRIPT" <<EOF
#!/bin/bash
set -euo pipefail
INPUT="\${1:?missing audio path}"
OUTDIR="\${2:-\${TMPDIR:-$STATE/tmp}}"
ROOT="$ROOT"
MODEL="$MODEL"
BIN="\$ROOT/whisper-cli"
WAV="\$OUTDIR/stt.wav"
mkdir -p "\$OUTDIR"
export LD_LIBRARY_PATH="\$ROOT\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
cd "\$ROOT"
/usr/bin/ffmpeg -hide_banner -loglevel error -y -i "\$INPUT" -ar 16000 -ac 1 -c:a pcm_s16le "\$WAV"

# Pass 1: ask whisper which language it thinks this is.
DETECTED="\$("\$BIN" -m "\$MODEL" -f "\$WAV" -t 1 -ng -dl 2>&1 \\
  | sed -n 's/.*auto-detected language: \\([a-z][a-z]*\\).*/\\1/p' | head -1)"

# Pass 2: Whisper confuses Telugu with its Dravidian and Indic neighbours, so
# treat any of those guesses as Telugu. Anything else is taken at face value.
case "\$DETECTED" in
  te|ta|kn|ml|hi|mr|bn|gu|pa|or|sa|ne|ur) LANG=te ;;
  "")                                     LANG=en ;;
  *)                                      LANG="\$DETECTED" ;;
esac

"\$BIN" -m "\$MODEL" -f "\$WAV" -t 1 -nt -np -ng -l "\$LANG"
EOF
fi

bash -n "$NEWSCRIPT" || { echo "generated script failed syntax check; original untouched" >&2; rm -f "$NEWSCRIPT"; exit 1; }
install -m 700 -o openclaw -g openclaw "$NEWSCRIPT" "$SCRIPT"
rm -f "$NEWSCRIPT"

echo "--- new script ---"
cat "$SCRIPT"
echo
echo "Rollback: cp -a $SCRIPT.bak-$STAMP $SCRIPT"
echo "Next: send one Telugu voice note, then one English voice note."
