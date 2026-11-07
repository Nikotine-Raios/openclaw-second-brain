#!/usr/bin/env bash
# Put the bot on Gemini, with gpt-5.6-terra as fallback.
#
# WHY NOT GROQ: referencing groq/* made OpenClaw try to npm-install
# @openclaw/groq-provider at gateway startup. The gateway runs with read-only
# home protections, npm failed with EROFS, plugin verification failed, and the
# gateway crash-looped 30 times until systemd gave up. Groq is an external npm
# plugin and cannot be installed on this host without weakening that hardening.
#
# The google plugin is a STOCK bundled plugin already on disk (stock:google/
# index.js), so it needs no install and cannot hit EROFS.
#
# Safety: every step is verified, and if the gateway does not come back healthy
# the script reverts everything itself and restores the previous .env.
#
# Run once as root:  sudo bash /home/admin/setup-gemini-only.sh
set -uo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root: sudo bash $0" >&2
  exit 1
fi

STATE=/home/openclaw/.openclaw
OC="$STATE/bin/openclaw"
ENVFILE="$STATE/.env"
UNIT=openclaw-gateway
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"

oc() { sudo -n -u openclaw -H "$OC" "$@"; }

wait_healthy() {
  local i
  for i in $(seq 1 25); do
    if curl -fsS --max-time 3 http://127.0.0.1:18789/healthz >/dev/null 2>&1; then return 0; fi
    sleep 3
  done
  return 1
}

restart_gateway() {
  systemctl reset-failed "$UNIT" 2>/dev/null   # clear the "repeated too quickly" block
  systemctl restart "$UNIT"
}

echo "=== 0. confirm gateway is healthy before we touch anything ==="
if ! wait_healthy; then
  echo "gateway is not healthy right now. Fix that before running this." >&2
  exit 1
fi
echo "gateway healthy"

echo "=== 1. Gemini key ==="
echo "Paste the Google AI Studio key. It will not be echoed."
read -r -s GEM_KEY </dev/tty; echo
[[ -n "$GEM_KEY" ]] || { echo "empty key, aborting" >&2; exit 1; }

VCFG="$(mktemp)"; chmod 600 "$VCFG"
printf 'url = "https://generativelanguage.googleapis.com/v1beta/models?key=%s"\n' "$GEM_KEY" >"$VCFG"
CODE="$(curl -sS -o /tmp/gem.json -w '%{http_code}' --max-time 30 --config "$VCFG" 2>/dev/null || echo 000)"
rm -f "$VCFG"
[[ "$CODE" == "200" ]] || { echo "key rejected by Google (HTTP $CODE); nothing changed" >&2; rm -f /tmp/gem.json; exit 1; }
echo "key accepted"

# Pick a real model id from Google's own list, preferring flash-lite.
# Python opens the file itself: do NOT redirect it into `python3 -`, because the
# heredoc already occupies stdin and json.load(sys.stdin) would read nothing.
cat >/tmp/pick_model.py <<'PY'
import json, sys
try:
    data = json.load(open("/tmp/gem.json"))
except Exception as e:
    print("PARSE_ERROR", e, file=sys.stderr)
    raise SystemExit(1)
names = []
for m in data.get("models", []):
    n = (m.get("name") or "").replace("models/", "")
    methods = m.get("supportedGenerationMethods") or m.get("supported_generation_methods") or []
    # Some API revisions omit the methods list; keep those rather than dropping them.
    if not methods or "generateContent" in methods:
        names.append(n)
bad = ("tts", "image", "embedding", "aqa", "vision", "live", "native-audio")
usable = [n for n in names if n and not any(b in n for b in bad)]
print("CANDIDATES:", ", ".join(usable[:40]), file=sys.stderr)
for want in ("gemini-2.5-flash-lite", "gemini-flash-lite-latest", "gemini-2.0-flash-lite"):
    if want in usable:
        print(want); raise SystemExit(0)
lite = sorted(n for n in usable if "flash-lite" in n)
if lite:
    print(lite[-1]); raise SystemExit(0)
flash = sorted(n for n in usable if "flash" in n)
if flash:
    print(flash[-1]); raise SystemExit(0)
if usable:
    print(usable[0])
PY
MODEL_ID="$(python3 /tmp/pick_model.py 2>/tmp/pick_model.err)"
echo "--- model discovery ---"
cat /tmp/pick_model.err
rm -f /tmp/gem.json /tmp/pick_model.py /tmp/pick_model.err
[[ -n "$MODEL_ID" ]] || { echo "could not determine a Gemini model id; nothing changed" >&2; exit 1; }
echo "model id: $MODEL_ID"

echo "=== 2. snapshot current state for rollback ==="
cp -a "$ENVFILE" "$ENVFILE.bak-$STAMP"
OLD_PRIMARY="$(oc config get agents.defaults.model.primary 2>/dev/null | tr -d '"' | tail -1)"
echo "backup env:   $ENVFILE.bak-$STAMP"
echo "old primary:  ${OLD_PRIMARY:-unknown}"

revert_all() {
  echo "!!! reverting !!!" >&2
  cp -a "$ENVFILE.bak-$STAMP" "$ENVFILE"
  chown openclaw:openclaw "$ENVFILE"; chmod 600 "$ENVFILE"
  oc config set plugins.allow '["memory-core","openai","telegram","device-pair","ollama"]' --strict-json --replace >/dev/null 2>&1
  oc config set agents.defaults.modelPolicy.allow '["openai/*"]' --strict-json --replace >/dev/null 2>&1
  oc config set agents.defaults.model.fallbacks '[]' --strict-json --replace >/dev/null 2>&1
  [[ -n "$OLD_PRIMARY" ]] && oc config set agents.defaults.model.primary "$OLD_PRIMARY" >/dev/null 2>&1
  restart_gateway
  if wait_healthy; then echo "reverted and healthy again" >&2; else echo "STILL UNHEALTHY after revert - run: sudo journalctl -u $UNIT -n 40 --no-pager" >&2; fi
}

echo "=== 3. write key ==="
umask 077
sed -i '/^GEMINI_API_KEY=/d; /^GOOGLE_API_KEY=/d; /^GROQ_API_KEY=/d' "$ENVFILE"
printf 'GEMINI_API_KEY=%s\n' "$GEM_KEY" >>"$ENVFILE"
chown openclaw:openclaw "$ENVFILE"; chmod 600 "$ENVFILE"
unset GEM_KEY
awk -F= '{print "  " $1}' "$ENVFILE"

echo "=== 4. enable the bundled google plugin (no npm, no install) ==="
oc config set plugins.allow '["memory-core","openai","telegram","device-pair","ollama","google"]' --strict-json --replace 2>&1 | tail -2

echo "=== 5. model policy: openai + google ONLY (never groq) ==="
oc config set agents.defaults.modelPolicy.allow '["openai/*","google/*"]' --strict-json --replace 2>&1 | tail -2

echo "=== 6. primary google, fallback gpt-5.6-terra ==="
oc config set agents.defaults.model.primary "google/$MODEL_ID" 2>&1 | tail -2
oc config set agents.defaults.model.fallbacks '["openai/gpt-5.6-terra"]' --strict-json --replace 2>&1 | tail -2

echo "=== 7. restart and verify ==="
restart_gateway
if ! wait_healthy; then
  echo "gateway did not come back healthy" >&2
  revert_all
  exit 1
fi
echo "gateway healthy"

echo "=== 8. live turn through the new model ==="
OUT="$(oc agent --agent main --local --message 'Reply with exactly: PROVIDER_OK' --timeout 150 2>&1 | tail -15)"
printf '%s\n' "$OUT"

if printf '%s' "$OUT" | grep -q 'PROVIDER_OK'; then
  echo
  echo "SUCCESS. primary=google/$MODEL_ID  fallback=openai/gpt-5.6-terra"
  echo "Send the bot a message in Telegram to confirm."
else
  echo
  echo "Gateway is healthy but the test turn did not return PROVIDER_OK." >&2
  echo "Config left in place so you can inspect it. To undo:" >&2
  echo "  sudo cp -a $ENVFILE.bak-$STAMP $ENVFILE" >&2
  echo "  sudo -n -u openclaw -H $OC config set agents.defaults.model.primary ${OLD_PRIMARY:-openai/gpt-5.6-terra}" >&2
  echo "  sudo -n -u openclaw -H $OC config set plugins.allow '[\"memory-core\",\"openai\",\"telegram\",\"device-pair\",\"ollama\"]' --strict-json --replace" >&2
  echo "  sudo systemctl reset-failed $UNIT; sudo systemctl restart $UNIT" >&2
fi
