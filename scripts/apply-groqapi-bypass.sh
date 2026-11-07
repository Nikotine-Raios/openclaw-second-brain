#!/usr/bin/env bash
# One-shot: talk to Groq over OpenAI-compatible HTTP so the gateway
# does not need the groq plugin loaded in its 6-plugin process.
# Uses GROQ_API_KEY already in /home/openclaw/.openclaw/.env.
set -euo pipefail
cd /tmp
python3 - <<'PY'
from pathlib import Path
Path("/tmp/groqapi-prov.json").write_text(
    '{"baseUrl":"https://api.groq.com/openai/v1","api":"openai-completions",'
    '"apiKey":"${GROQ_API_KEY}","models":[{"id":"llama-3.3-70b-versatile","name":"Llama 3.3 70B"}]}\n'
)
Path("/tmp/groqapi-policy.json").write_text('["openai/*","google/*","groq/*","groqapi/*"]\n')
Path("/tmp/groqapi-fallbacks.json").write_text('["google/gemini-3.5-flash-lite","openai/gpt-5.6-terra"]\n')
print("wrote json helpers")
PY
OC=/home/openclaw/.openclaw/bin/openclaw
sudo -u openclaw -H "$OC" config set models.providers.groqapi "$(cat /tmp/groqapi-prov.json)" --strict-json --replace
sudo -u openclaw -H "$OC" config set agents.defaults.modelPolicy.allow "$(cat /tmp/groqapi-policy.json)" --strict-json --replace
sudo -u openclaw -H "$OC" models set groqapi/llama-3.3-70b-versatile
sudo -u openclaw -H "$OC" config set agents.defaults.model.fallbacks "$(cat /tmp/groqapi-fallbacks.json)" --strict-json --replace
sudo -u openclaw -H "$OC" config get agents.defaults.model
rm -f /tmp/groqapi-prov.json /tmp/groqapi-policy.json /tmp/groqapi-fallbacks.json
echo "Then in Telegram: /new   then   hi"
