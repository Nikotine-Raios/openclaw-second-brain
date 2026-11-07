#!/usr/bin/env bash
# groq/openai/gpt-oss-120b is re-parsed as provider=openai, so Telegram
# "selects" gpt-5.6-terra, 429s, and answers from Gemini.
# Use a Groq model id with no extra slash.
set -euo pipefail
if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root: sudo bash $0" >&2
  exit 1
fi
OC=/home/openclaw/.openclaw/bin/openclaw
cd /tmp
sudo -n -u openclaw -H "$OC" models set groq/llama-3.3-70b-versatile
sudo -n -u openclaw -H "$OC" config set agents.defaults.model.fallbacks \
  '["google/gemini-3.5-flash-lite","openai/gpt-5.6-terra"]' --strict-json --replace
sudo -n -u openclaw -H "$OC" config get agents.defaults.model
systemctl restart openclaw-gateway
for i in $(seq 1 20); do
  curl -fsS --max-time 3 http://127.0.0.1:18789/healthz >/dev/null 2>&1 && break
  sleep 2
done
curl -fsS --max-time 5 http://127.0.0.1:18789/healthz; echo
echo "Next in Telegram: /new then hi"
