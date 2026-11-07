#!/usr/bin/env bash
# Make Telugu voice notes and Telugu text work on the second brain.
#
# Two problems this fixes:
#   1. transcribe-audio.sh hardcoded "-l en", so Telugu audio was force-decoded
#      as English. That is what destroyed the transliteration.
#   2. ggml-tiny.bin is too weak for Telugu even with the right language flag.
#
# Run once as root:  sudo bash /home/admin/setup-telugu-stt.sh
set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root: sudo bash $0" >&2
  exit 1
fi

STATE=/home/openclaw/.openclaw
ROOT="$STATE/opt/whisper-bin-ubuntu-x64"
MODELS="$STATE/models"
SCRIPT="$STATE/bin/transcribe-audio.sh"
WS="$STATE/workspace"
NEW_MODEL="$MODELS/ggml-base.bin"
MODEL_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"

for p in "$ROOT/whisper-cli" "$SCRIPT" "$WS"; do
  [[ -e "$p" ]] || { echo "missing required path: $p" >&2; exit 1; }
done

echo "=== 1. swap (protects the gateway from an out-of-memory kill) ==="
if [[ "$(swapon --show --noheadings | wc -l)" -gt 0 ]]; then
  echo "swap already present:"
  swapon --show
else
  fallocate -l 2G /swapfile
  chmod 600 /swapfile
  mkswap /swapfile >/dev/null
  swapon /swapfile
  grep -q '^/swapfile ' /etc/fstab || printf '/swapfile none swap sw 0 0\n' >>/etc/fstab
  echo "created 2G /swapfile"
fi
free -m

echo "=== 2. multilingual model ==="
if [[ -s "$NEW_MODEL" ]] && [[ "$(stat -c %s "$NEW_MODEL")" -gt 100000000 ]]; then
  echo "already present: $NEW_MODEL ($(stat -c %s "$NEW_MODEL") bytes)"
else
  TMP="$(mktemp /tmp/ggml-base.XXXXXX.bin)"
  curl -fL --retry 3 --connect-timeout 20 -o "$TMP" "$MODEL_URL"
  SIZE="$(stat -c %s "$TMP")"
  if [[ "$SIZE" -lt 100000000 ]]; then
    rm -f "$TMP"
    echo "download looks wrong ($SIZE bytes); aborting without touching the script" >&2
    exit 1
  fi
  install -m 600 -o openclaw -g openclaw "$TMP" "$NEW_MODEL"
  rm -f "$TMP"
  echo "installed $NEW_MODEL ($SIZE bytes)"
fi

echo "=== 3. language flag support in this whisper build ==="
# Newer whisper.cpp can constrain autodetect. Use it when available so accented
# English is not misdetected as some unrelated language.
LANG_ARGS='-l auto'
if sudo -u openclaw -H "$ROOT/whisper-cli" --help 2>&1 | grep -q -- '--language-candidates'; then
  LANG_ARGS='-l auto --language-candidates en,te'
  echo "build supports --language-candidates; constraining to en,te"
else
  echo "build has no --language-candidates; using plain -l auto"
fi

echo "=== 4. patch transcribe-audio.sh ==="
cp -a "$SCRIPT" "$SCRIPT.bak-$STAMP"
echo "backup: $SCRIPT.bak-$STAMP"

NEWSCRIPT="$(mktemp /tmp/transcribe-audio.XXXXXX.sh)"
cat >"$NEWSCRIPT" <<EOF
#!/bin/bash
set -euo pipefail
INPUT="\${1:?missing audio path}"
OUTDIR="\${2:-\${TMPDIR:-$STATE/tmp}}"
ROOT="$ROOT"
MODEL="$NEW_MODEL"
BIN="\$ROOT/whisper-cli"
WAV="\$OUTDIR/stt.wav"
mkdir -p "\$OUTDIR"
export LD_LIBRARY_PATH="\$ROOT\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
cd "\$ROOT"
/usr/bin/ffmpeg -hide_banner -loglevel error -y -i "\$INPUT" -ar 16000 -ac 1 -c:a pcm_s16le "\$WAV"
# Autodetect the language instead of assuming English, so Telugu stays Telugu.
"\$BIN" -m "\$MODEL" -f "\$WAV" -t 1 -nt -np -ng $LANG_ARGS
EOF

bash -n "$NEWSCRIPT" || { echo "generated script failed syntax check; original left untouched" >&2; rm -f "$NEWSCRIPT"; exit 1; }
install -m 700 -o openclaw -g openclaw "$NEWSCRIPT" "$SCRIPT"
rm -f "$NEWSCRIPT"

echo "--- new script ---"
cat "$SCRIPT"

echo "=== 5. script-preservation rule for the agent ==="
AGENTS="$WS/AGENTS.md"
if grep -q 'BEGIN LANGUAGE RULE' "$AGENTS" 2>/dev/null; then
  echo "language rule already present in AGENTS.md"
else
  cp -a "$AGENTS" "$AGENTS.bak-$STAMP"
  cat >>"$AGENTS" <<'EOF'

<!-- BEGIN LANGUAGE RULE -->
## Language and script

The owner writes and speaks English and Telugu, sometimes mixed in one message.

- Reply in the same language and the same script he used. Telugu script in,
  Telugu script out. Romanized Telugu (Telugu written in English letters) in,
  romanized Telugu out. Mixed in, mirror the mix.
- Never silently translate his words into English, and never convert between
  Telugu script and romanized Telugu unless he asks.
- When a voice note transcript looks garbled or the language looks misdetected,
  say so plainly and ask him to confirm or resend. Do not guess at the meaning
  and answer as if the transcript were correct.
- Keep proper nouns, names, and technical terms in the form he used.
<!-- END LANGUAGE RULE -->
EOF
  chown openclaw:openclaw "$AGENTS"
  chmod 600 "$AGENTS"
  echo "appended language rule to AGENTS.md (backup: $AGENTS.bak-$STAMP)"
fi

echo
echo "Done. Old model ggml-tiny.bin was left in place for rollback."
echo "Rollback: cp -a $SCRIPT.bak-$STAMP $SCRIPT"
echo "Next: send the bot a Telugu voice note and a romanized Telugu text."
