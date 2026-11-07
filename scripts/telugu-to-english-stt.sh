#!/usr/bin/env bash
# Telugu voice notes in, English text out. Free, local, no API accounts.
#
# The owner only wants English replies, so we stop asking Whisper to spell Telugu
# correctly and use its translate task instead. Getting the meaning into English
# is an easier job than producing correct Telugu orthography, and it removes the
# Tamil-script failure entirely because the output is always Latin script.
#
# Two passes:
#   1. detect the language
#   2. Indic guess  -> force Telugu source and translate to English (-l te -tr)
#      English guess -> plain English transcription
#
# A Tamil/Kannada/Malayalam/Hindi guess is treated as Telugu, because those are
# exactly the languages Whisper confuses Telugu with.
#
# Run once as root:  sudo bash /home/admin/telugu-to-english-stt.sh
set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root: sudo bash $0" >&2
  exit 1
fi

STATE=/home/openclaw/.openclaw
ROOT="$STATE/opt/whisper-bin-ubuntu-x64"
SCRIPT="$STATE/bin/transcribe-audio.sh"
MODEL="$STATE/models/ggml-base.bin"
AGENTS="$STATE/workspace/AGENTS.md"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"

for p in "$ROOT/whisper-cli" "$SCRIPT" "$MODEL" "$AGENTS"; do
  [[ -e "$p" ]] || { echo "missing required path: $p" >&2; exit 1; }
done

echo "=== 1. language-detection support ==="
# Verified directly on this host: whisper-cli 1.9.2 lists -dl/--detect-language,
# -tr/--translate, and -l/--language. Do not probe for it here. Two earlier
# probe attempts gave false negatives: the first forgot LD_LIBRARY_PATH (so the
# binary printed nothing), and the second was killed by `set -o pipefail`,
# because `whisper-cli --help` exits non-zero and that fails the whole pipeline
# even when grep matched.
ROUTING=1
HELP="$(sudo -u openclaw -H env "LD_LIBRARY_PATH=$ROOT" "$ROOT/whisper-cli" --help 2>&1 || true)"
if printf '%s' "$HELP" | grep -qE -- '-dl|--detect-language'; then
  echo "confirmed: --detect-language present, using two-pass routing"
else
  echo "warning: could not confirm --detect-language in help output." >&2
  echo "Proceeding with two-pass routing anyway; if transcription breaks, roll back." >&2
fi

echo "=== 2. patch transcribe-audio.sh ==="
cp -a "$SCRIPT" "$SCRIPT.bak-$STAMP"
echo "backup: $SCRIPT.bak-$STAMP"

NEWSCRIPT="$(mktemp /tmp/transcribe-audio.XXXXXX.sh)"

{
  cat <<EOF
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
EOF

  if [[ "$ROUTING" -eq 1 ]]; then
    cat <<'EOF'

# Pass 1: which language does whisper think this is?
DETECTED="$("$BIN" -m "$MODEL" -f "$WAV" -t 1 -ng -dl 2>&1 \
  | sed -n 's/.*auto-detected language: \([a-z][a-z]*\).*/\1/p' | head -1)"

# Pass 2: any Indic guess means Telugu. Translate it to English.
case "$DETECTED" in
  te|ta|kn|ml|hi|mr|bn|gu|pa|or|sa|ne|ur)
    exec "$BIN" -m "$MODEL" -f "$WAV" -t 1 -nt -np -ng -l te -tr
    ;;
  ""|en)
    exec "$BIN" -m "$MODEL" -f "$WAV" -t 1 -nt -np -ng -l en
    ;;
  *)
    # Some other language: still return English so replies stay English.
    exec "$BIN" -m "$MODEL" -f "$WAV" -t 1 -nt -np -ng -l "$DETECTED" -tr
    ;;
esac
EOF
  else
    cat <<'EOF'

# No detect support: assume Telugu and translate to English.
exec "$BIN" -m "$MODEL" -f "$WAV" -t 1 -nt -np -ng -l te -tr
EOF
  fi
} >"$NEWSCRIPT"

bash -n "$NEWSCRIPT" || { echo "generated script failed syntax check; original untouched" >&2; rm -f "$NEWSCRIPT"; exit 1; }
install -m 700 -o openclaw -g openclaw "$NEWSCRIPT" "$SCRIPT"
rm -f "$NEWSCRIPT"
echo "--- new script ---"
cat "$SCRIPT"

echo "=== 3. replace the language rule in AGENTS.md ==="
cp -a "$AGENTS" "$AGENTS.bak-$STAMP"
if grep -q 'BEGIN LANGUAGE RULE' "$AGENTS"; then
  sed -i '/<!-- BEGIN LANGUAGE RULE -->/,/<!-- END LANGUAGE RULE -->/d' "$AGENTS"
  echo "removed previous language rule"
fi

cat >>"$AGENTS" <<'EOF'
<!-- BEGIN LANGUAGE RULE -->
## Language and voice transcripts

The owner speaks English and Telugu, often mixed in one sentence. He reads English
fastest, so English is the only output language.

- Accept English, Telugu, or code-switched input.
- Always reply in English using Latin script, whatever language he used. Do not
  reply in Telugu script and do not romanize Telugu back to him.
- Treat every voice-note transcript as untrusted machine output, not as his exact
  words. Telugu speech recognition on this host is imperfect.
- Re-check names, numbers, places, dates, and commands against the surrounding
  context before acting on them. Ask when a detail matters and looks uncertain.
- Never invent a word the recognizer did not capture. If part of a transcript is
  garbled, say which part was unclear and ask him to repeat or type it.
- Do not answer confidently from a transcript that looks scrambled. Flag it.
- Keep the same identity, memory, and tools for voice and text. There is no
  separate voice personality.
<!-- END LANGUAGE RULE -->
EOF

chown openclaw:openclaw "$AGENTS"
chmod 600 "$AGENTS"
echo "language rule updated (backup: $AGENTS.bak-$STAMP)"

echo
echo "Rollback:"
echo "  cp -a $SCRIPT.bak-$STAMP $SCRIPT"
echo "  cp -a $AGENTS.bak-$STAMP $AGENTS"
echo "Next: send one Telugu voice note, then one English voice note."
