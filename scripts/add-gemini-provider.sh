#!/usr/bin/env bash
# Add Google Gemini as a second model provider so the bot is not dead whenever
# one provider rate-limits. OpenAI stays allowed, so when the ChatGPT quota
# resets it remains usable.
#
# Three coordinated changes are required, because the host was hardened:
#   1. plugins.allow                     - the google plugin is not loaded today
#   2. agents.defaults.modelPolicy.allow - currently restricted to openai/*
#   3. GEMINI_API_KEY in the gateway EnvironmentFile (/home/openclaw/.openclaw/.env)
#
# This script does NOT set the primary model. It first enables the provider and
# then lists the real Gemini model ids from the installed OpenClaw catalog, so
# the model id is chosen from fact instead of guessed. Setting the primary is a
# one-line follow-up.
#
# Run once as root:  sudo bash /home/admin/add-gemini-provider.sh
set -euo pipefail

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

[[ -x "$OC" ]] || { echo "openclaw CLI not found at $OC" >&2; exit 1; }

echo "=== 1. Gemini API key ==="
echo "Paste the Google AI Studio API key. It will not be echoed."
read -r -s GKEY </dev/tty
echo
[[ -n "$GKEY" ]] || { echo "empty key, aborting" >&2; exit 1; }

# Validate for free: listing models costs nothing. Key goes in a curl config so
# it never appears in argv or in `ps` output.
VCFG="$(mktemp)"; chmod 600 "$VCFG"
printf 'url = "https://generativelanguage.googleapis.com/v1beta/models?key=%s"\n' "$GKEY" >"$VCFG"
CODE="$(curl -sS -o /tmp/gem-validate.json -w '%{http_code}' --max-time 30 --config "$VCFG" || echo 000)"
rm -f "$VCFG"

if [[ "$CODE" != "200" ]]; then
  echo "key rejected by Google (HTTP $CODE). Nothing was changed." >&2
  head -c 400 /tmp/gem-validate.json 2>/dev/null || true
  rm -f /tmp/gem-validate.json
  exit 1
fi
echo "key accepted by Google"

echo "--- model names Google reports for this key (flash-lite has the 500/day quota) ---"
python3 - </tmp/gem-validate.json <<'PY' || true
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    raise SystemExit(0)
for m in data.get("models", []):
    name = (m.get("name") or "").replace("models/", "")
    methods = m.get("supportedGenerationMethods") or []
    if "generateContent" in methods and "flash" in name:
        print(" ", name)
PY
rm -f /tmp/gem-validate.json

echo "=== 2. store key in the gateway EnvironmentFile ==="
touch "$ENVFILE"
cp -a "$ENVFILE" "$ENVFILE.bak-$STAMP"
echo "backup: $ENVFILE.bak-$STAMP"
# Replace an existing entry rather than adding a duplicate.
sed -i '/^GEMINI_API_KEY=/d; /^GOOGLE_API_KEY=/d' "$ENVFILE"
umask 077
printf 'GEMINI_API_KEY=%s\n' "$GKEY" >>"$ENVFILE"
chown openclaw:openclaw "$ENVFILE"
chmod 600 "$ENVFILE"
unset GKEY
echo "GEMINI_API_KEY written to $ENVFILE (mode 600, owner openclaw)"
echo "variable names present:"
awk -F= '{print "  " $1}' "$ENVFILE"

echo "=== 3. allow the google plugin ==="
oc config set plugins.allow '["memory-core","openai","telegram","device-pair","ollama","google"]' --strict-json --replace
oc config get plugins.allow

echo "=== 4. widen the model policy ==="
oc config set agents.defaults.modelPolicy.allow '["openai/*","google/*"]' --strict-json --replace
oc config get agents.defaults.modelPolicy

echo "=== 5. restart the gateway ==="
systemctl restart "$UNIT"
for i in $(seq 1 30); do
  if systemctl is-active --quiet "$UNIT" && curl -fsS --max-time 3 http://127.0.0.1:18789/healthz >/dev/null; then
    echo "gateway: healthy"
    break
  fi
  sleep 2
  [[ "$i" -eq 30 ]] && { echo "gateway did not become healthy; check journalctl -u $UNIT" >&2; exit 1; }
done

echo "=== 6. Gemini models in the OpenClaw catalog ==="
oc models list --provider google 2>&1 | head -40 || true

echo
echo "Provider enabled but NOT yet primary. Nothing about your current model changed."
echo "Pick a flash-lite id from the lists above, then run:"
echo "  sudo -n -u openclaw -H $OC config set agents.defaults.model.primary google/<model-id>"
echo "  sudo systemctl restart $UNIT"
echo
echo "Rollback:"
echo "  sudo -n -u openclaw -H $OC config set plugins.allow '[\"memory-core\",\"openai\",\"telegram\",\"device-pair\",\"ollama\"]' --strict-json --replace"
echo "  sudo -n -u openclaw -H $OC config set agents.defaults.modelPolicy.allow '[\"openai/*\"]' --strict-json --replace"
echo "  cp -a $ENVFILE.bak-$STAMP $ENVFILE && sudo systemctl restart $UNIT"
