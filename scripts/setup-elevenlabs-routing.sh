#!/usr/bin/env bash
# Route voice notes by language:
#   English  -> local whisper, free, unlimited
#   anything else -> ElevenLabs Scribe v2, accurate Telugu, metered credits
#
# ElevenLabs is called directly with curl from inside transcribe-audio.sh, which
# OpenClaw already invokes as its audio model. That means no plugin-allowlist
# change, no modelPolicy change, and no gateway restart: the hardening stays as
# it is.
#
# The API key is stored in a 0600 file owned by openclaw and passed to curl via
# a temporary curl config, never on the command line, so it cannot be seen in
# `ps` output or shell history.
#
# Run once as root:  sudo bash /home/admin/setup-elevenlabs-routing.sh
set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root: sudo bash $0" >&2
  exit 1
fi

STATE=/home/openclaw/.openclaw
ROOT="$STATE/opt/whisper-bin-ubuntu-x64"
SCRIPT="$STATE/bin/transcribe-audio.sh"
MODEL="$STATE/models/ggml-base.bin"
KEYFILE="$STATE/elevenlabs.key"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"

for p in "$ROOT/whisper-cli" "$SCRIPT" "$MODEL"; do
  [[ -e "$p" ]] || { echo "missing required path: $p" >&2; exit 1; }
done
command -v curl >/dev/null || { echo "curl is required" >&2; exit 1; }
command -v python3 >/dev/null || { echo "python3 is required" >&2; exit 1; }

echo "=== 1. ElevenLabs API key ==="
if [[ -s "$KEYFILE" ]]; then
  echo "key file already exists: $KEYFILE"
  read -r -p "Replace it? [y/N] " REPLACE </dev/tty
else
  REPLACE=y
fi

if [[ "$REPLACE" == "y" || "$REPLACE" == "Y" ]]; then
  echo "Paste the ElevenLabs API key. It will not be echoed."
  read -r -s NEWKEY </dev/tty
  echo
  [[ -n "$NEWKEY" ]] || { echo "empty key, aborting" >&2; exit 1; }

  # Validate without spending credits. /v1/user needs the user_read permission,
  # which a correctly scoped Speech-to-Text-only key does NOT have. So a 401
  # carrying "missing_permissions" still proves the key authenticated — that is
  # a pass, not a failure. Only a genuinely bad key gets rejected here.
  VCFG="$(mktemp)"; chmod 600 "$VCFG"
  printf 'header = "xi-api-key: %s"\n' "$NEWKEY" >"$VCFG"
  CODE="$(curl -sS -o /tmp/el-validate.json -w '%{http_code}' --max-time 30 \
    --config "$VCFG" https://api.elevenlabs.io/v1/user || echo 000)"
  rm -f "$VCFG"

  BODY="$(cat /tmp/el-validate.json 2>/dev/null || true)"
  rm -f /tmp/el-validate.json

  if [[ "$CODE" == "200" ]]; then
    echo "key accepted by ElevenLabs (full access)"
  elif [[ "$CODE" == "401" ]] && printf '%s' "$BODY" | grep -q 'missing_permissions'; then
    echo "key authenticated and correctly scoped (Speech to Text only)"
  else
    echo "key rejected by ElevenLabs (HTTP $CODE). Nothing was stored." >&2
    printf '%s\n' "${BODY:0:300}" >&2
    exit 1
  fi

  umask 077
  printf '%s' "$NEWKEY" >"$KEYFILE"
  chown openclaw:openclaw "$KEYFILE"
  chmod 600 "$KEYFILE"
  unset NEWKEY
  echo "stored $KEYFILE (mode 600, owner openclaw)"
fi

echo "=== 2. patch transcribe-audio.sh ==="
cp -a "$SCRIPT" "$SCRIPT.bak-$STAMP"
echo "backup: $SCRIPT.bak-$STAMP"

NEWSCRIPT="$(mktemp /tmp/transcribe-audio.XXXXXX.sh)"
cat >"$NEWSCRIPT" <<'INNER_EOF'
#!/bin/bash
# English stays local and free. Everything else goes to ElevenLabs Scribe v2.
set -euo pipefail

INPUT="${1:?missing audio path}"
OUTDIR="${2:-${TMPDIR:-/home/openclaw/.openclaw/tmp}}"
ROOT="/home/openclaw/.openclaw/opt/whisper-bin-ubuntu-x64"
MODEL="/home/openclaw/.openclaw/models/ggml-base.bin"
KEYFILE="/home/openclaw/.openclaw/elevenlabs.key"
BIN="$ROOT/whisper-cli"
WAV="$OUTDIR/stt.wav"

mkdir -p "$OUTDIR"
export LD_LIBRARY_PATH="$ROOT${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
cd "$ROOT"

/usr/bin/ffmpeg -hide_banner -loglevel error -y -i "$INPUT" \
  -ar 16000 -ac 1 -c:a pcm_s16le "$WAV"

local_english() { exec "$BIN" -m "$MODEL" -f "$WAV" -t 1 -nt -np -ng -l en; }
local_translate() { exec "$BIN" -m "$MODEL" -f "$WAV" -t 1 -nt -np -ng -l te -tr; }

# Cheap local pass: only needs to answer "English or not".
DETECTED="$("$BIN" -m "$MODEL" -f "$WAV" -t 1 -ng -dl 2>&1 \
  | sed -n 's/.*auto-detected language: \([a-z][a-z]*\).*/\1/p' | head -1)"

case "${DETECTED:-en}" in
  en) local_english ;;
esac

# Not English. Use ElevenLabs if a key is present, else fall back locally.
[[ -s "$KEYFILE" ]] || local_translate

CFG="$(mktemp)"; chmod 600 "$CFG"
printf 'header = "xi-api-key: %s"\n' "$(cat "$KEYFILE")" >"$CFG"

RESP="$(curl -sS --max-time 120 --config "$CFG" \
  -X POST https://api.elevenlabs.io/v1/speech-to-text \
  -F "model_id=scribe_v2" \
  -F "file=@${WAV};type=audio/wav" 2>/dev/null || true)"
rm -f "$CFG"

TEXT="$(printf '%s' "$RESP" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
text = (data.get("text") or "").strip()
if text:
    print(text)
' 2>/dev/null || true)"

if [[ -n "$TEXT" ]]; then
  printf '%s\n' "$TEXT"
  exit 0
fi

# ElevenLabs unreachable, out of credits, or returned nothing usable.
local_translate
INNER_EOF

bash -n "$NEWSCRIPT" || { echo "generated script failed syntax check; original untouched" >&2; rm -f "$NEWSCRIPT"; exit 1; }
install -m 700 -o openclaw -g openclaw "$NEWSCRIPT" "$SCRIPT"
rm -f "$NEWSCRIPT"

echo "--- new script ---"
cat "$SCRIPT"

echo
echo "=== 3. live test ==="
LATEST="$(find "$STATE" -type f \( -iname '*.ogg' -o -iname '*.oga' -o -iname '*.m4a' \) \
  -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2- || true)"
if [[ -n "$LATEST" ]]; then
  echo "transcribing newest voice note: $LATEST"
  sudo -u openclaw -H "$SCRIPT" "$LATEST" /tmp || echo "(test run failed)"
else
  echo "no voice note found to test with; send one and it will use the new path"
fi

echo
echo "Rollback: cp -a $SCRIPT.bak-$STAMP $SCRIPT"
echo "Remove key: rm -f $KEYFILE   (routing then falls back to local whisper)"
