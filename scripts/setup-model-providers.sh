#!/usr/bin/env bash
# Get the bot off the exhausted ChatGPT free plan and onto working providers.
#
# Decision, based on limits checked directly against each vendor:
#   Groq   llama-3.3-70b-versatile : 1000 requests/day  -> PRIMARY
#   Gemini 2.5 flash-lite          :   20 requests/day  -> fallback
#   OpenAI gpt-5.6-terra           : exhausted ~18 days -> stays allowed
#
# Groq is configured as a custom OpenAI-compatible provider under
# models.providers, because it is not one of the 59 bundled plugins. Gemini uses
# the bundled google plugin, which only needs allowlisting. Neither needs an
# install, so the earlier npm EACCES problem is irrelevant here.
#
# Keys are read from hidden prompts, stored only in the gateway EnvironmentFile,
# and referenced from config as ${VAR} so no secret is written into config JSON.
# Either key may be skipped by pressing Enter.
#
# Run once as root:  sudo bash /home/admin/setup-model-providers.sh
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

[[ -x "$OC" ]] || { echo "openclaw CLI not found at $OC" >&2; exit 1; }

echo "=== keys ==="
echo "Groq API key from console.groq.com (Enter to skip):"
read -r -s GROQ_KEY </dev/tty; echo
echo "Google AI Studio key from aistudio.google.com/apikey (Enter to skip):"
read -r -s GEM_KEY </dev/tty; echo

if [[ -z "$GROQ_KEY" && -z "$GEM_KEY" ]]; then
  echo "no keys supplied, nothing to do" >&2
  exit 1
fi

validate() { # $1=url  -> prints HTTP code
  local cfg; cfg="$(mktemp)"; chmod 600 "$cfg"
  printf 'url = "%s"\n' "$1" >"$cfg"
  curl -sS -o /dev/null -w '%{http_code}' --max-time 30 --config "$cfg" 2>/dev/null || echo 000
  rm -f "$cfg"
}

GROQ_OK=0
if [[ -n "$GROQ_KEY" ]]; then
  cfg="$(mktemp)"; chmod 600 "$cfg"
  printf 'url = "https://api.groq.com/openai/v1/models"\nheader = "Authorization: Bearer %s"\n' "$GROQ_KEY" >"$cfg"
  CODE="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 30 --config "$cfg" 2>/dev/null || echo 000)"
  rm -f "$cfg"
  if [[ "$CODE" == "200" ]]; then GROQ_OK=1; echo "Groq key: accepted"; else echo "Groq key: REJECTED (HTTP $CODE), skipping Groq" >&2; fi
fi

GEM_OK=0
if [[ -n "$GEM_KEY" ]]; then
  CODE="$(validate "https://generativelanguage.googleapis.com/v1beta/models?key=$GEM_KEY")"
  if [[ "$CODE" == "200" ]]; then GEM_OK=1; echo "Gemini key: accepted"; else echo "Gemini key: REJECTED (HTTP $CODE), skipping Gemini" >&2; fi
fi

[[ "$GROQ_OK" -eq 1 || "$GEM_OK" -eq 1 ]] || { echo "no key validated, nothing changed" >&2; exit 1; }

echo "=== store keys in $ENVFILE ==="
touch "$ENVFILE"; cp -a "$ENVFILE" "$ENVFILE.bak-$STAMP"
echo "backup: $ENVFILE.bak-$STAMP"
umask 077
[[ "$GROQ_OK" -eq 1 ]] && { sed -i '/^GROQ_API_KEY=/d' "$ENVFILE"; printf 'GROQ_API_KEY=%s\n' "$GROQ_KEY" >>"$ENVFILE"; }
[[ "$GEM_OK"  -eq 1 ]] && { sed -i '/^GEMINI_API_KEY=/d' "$ENVFILE"; printf 'GEMINI_API_KEY=%s\n' "$GEM_KEY" >>"$ENVFILE"; }
chown openclaw:openclaw "$ENVFILE"; chmod 600 "$ENVFILE"
unset GROQ_KEY GEM_KEY
echo "variables now present:"; awk -F= '{print "  " $1}' "$ENVFILE"

echo "=== plugin allowlist ==="
if [[ "$GEM_OK" -eq 1 ]]; then
  oc config set plugins.allow '["memory-core","openai","telegram","device-pair","ollama","google"]' --strict-json --replace
else
  echo "(unchanged)"
fi

echo "=== model policy ==="
POLICY='["openai/*","groq/*","google/*"]'
oc config set agents.defaults.modelPolicy.allow "$POLICY" --strict-json --replace
oc config get agents.defaults.modelPolicy

if [[ "$GROQ_OK" -eq 1 ]]; then
  echo "=== custom Groq provider ==="
  oc config set models.providers.groq '{"baseUrl":"https://api.groq.com/openai/v1","api":"openai-completions","apiKey":"${GROQ_API_KEY}","models":[{"id":"llama-3.3-70b-versatile"},{"id":"openai/gpt-oss-120b"},{"id":"llama-3.1-8b-instant"}]}' --strict-json --replace \
    && echo "groq provider written" || echo "groq provider write FAILED" >&2
fi

echo "=== restart gateway ==="
systemctl restart "$UNIT"
HEALTHY=0
for i in $(seq 1 30); do
  if systemctl is-active --quiet "$UNIT" && curl -fsS --max-time 3 http://127.0.0.1:18789/healthz >/dev/null; then
    HEALTHY=1; echo "gateway: healthy"; break
  fi
  sleep 2
done
[[ "$HEALTHY" -eq 1 ]] || { echo "gateway unhealthy; see journalctl -u $UNIT" >&2; exit 1; }

echo "=== what the runtime now sees ==="
GROQ_LIVE=0
if [[ "$GROQ_OK" -eq 1 ]]; then
  if oc models list --provider groq 2>&1 | grep -q 'llama-3.3-70b-versatile'; then
    GROQ_LIVE=1; echo "groq provider is live in the catalog"
  else
    echo "groq provider did NOT register; falling back to Gemini" >&2
    oc models list --provider groq 2>&1 | head -5
  fi
fi

echo "=== choose primary and fallbacks ==="
# Groq carries the daily volume (1000 req/day). gpt-5.6-terra is the better
# model, so it sits first in the fallback chain and takes over automatically the
# moment its quota resets. Gemini is last because 20 req/day is a thin cushion.
if [[ "$GROQ_LIVE" -eq 1 ]]; then
  PRIMARY="groq/llama-3.3-70b-versatile"
  if [[ "$GEM_OK" -eq 1 ]]; then
    FALLBACKS='["openai/gpt-5.6-terra","google/gemini-2.5-flash-lite"]'
  else
    FALLBACKS='["openai/gpt-5.6-terra"]'
  fi
elif [[ "$GEM_OK" -eq 1 ]]; then
  PRIMARY="google/gemini-2.5-flash-lite"
  FALLBACKS='["openai/gpt-5.6-terra"]'
else
  echo "nothing usable became available; leaving the primary model unchanged" >&2
  exit 1
fi

oc config set agents.defaults.model.primary "$PRIMARY"
oc config set agents.defaults.model.fallbacks "$FALLBACKS" --strict-json --replace
echo "primary:   $PRIMARY"
echo "fallbacks: $FALLBACKS"
oc config get agents.defaults.model

systemctl restart "$UNIT"
for i in $(seq 1 30); do
  curl -fsS --max-time 3 http://127.0.0.1:18789/healthz >/dev/null && break || sleep 2
done

echo "=== live turn ==="
oc agent --agent main --local --message 'Reply with exactly: PROVIDER_OK' --timeout 120 2>&1 | tail -20

echo
echo "Rollback:"
echo "  sudo -n -u openclaw -H $OC config set agents.defaults.model.primary openai/gpt-5.6-terra"
echo "  sudo -n -u openclaw -H $OC config set agents.defaults.model.fallbacks '[]' --strict-json --replace"
echo "  sudo -n -u openclaw -H $OC config set agents.defaults.modelPolicy.allow '[\"openai/*\"]' --strict-json --replace"
echo "  sudo -n -u openclaw -H $OC config set plugins.allow '[\"memory-core\",\"openai\",\"telegram\",\"device-pair\",\"ollama\"]' --strict-json --replace"
echo "  cp -a $ENVFILE.bak-$STAMP $ENVFILE; sudo systemctl restart $UNIT"
