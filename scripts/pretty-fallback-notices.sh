#!/usr/bin/env bash
# Make Telegram fallback notices human:
#   ⚠️ Groq depleted — fallback responding: Gemini
# OpenClaw hardcodes the old "Model Fallback:" line; this patches the local install.
set -euo pipefail
if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root: sudo bash $0" >&2
  exit 1
fi

python3 - <<'PY'
from pathlib import Path
root = Path("/home/openclaw/.openclaw")
helper = r'''function prettyFallbackModel(ref) {
  const r = String(ref || "");
  if (/groq/i.test(r)) return "Groq";
  if (/gemini|^google\//i.test(r)) return "Gemini";
  if (/^openai\//i.test(r) || /gpt-5/i.test(r)) return "GPT";
  const parts = r.split("/");
  return parts[parts.length - 1] || r;
}
function prettyFallbackReason(reason) {
  const x = String(reason || "").toLowerCase();
  if (x.includes("rate") || x.includes("quota") || x.includes("429") || x.includes("usage limit")) return "depleted";
  if (x.includes("not found") || x.includes("unavailable")) return "unavailable";
  if (x.includes("auth")) return "sign-in failed";
  return "unavailable";
}
'''
old = "return `↪️ Model Fallback: ${active} (selected ${selected}; ${reasonSummary})`;"
new = "return `⚠️ ${prettyFallbackModel(selected)} ${prettyFallbackReason(reasonSummary)} — fallback responding: ${prettyFallbackModel(active)}`;"
old_clear_a = "return `↪️ Model Fallback cleared: ${selected} (was ${previous})`;"
new_clear_a = "return `✅ Back on ${prettyFallbackModel(selected)}`;"
old_clear_b = "return `↪️ Model Fallback cleared: ${selected}`;"
new_clear_b = "return `✅ Back on ${prettyFallbackModel(selected)}`;"
hits = []
for p in root.rglob("*.js"):
    try:
        text = p.read_text(encoding="utf-8")
    except Exception:
        continue
    if "Model Fallback:" not in text:
        continue
    orig = text
    if "function prettyFallbackModel" not in text:
        if "function buildFallbackNotice" in text:
            text = text.replace("function buildFallbackNotice", helper + "function buildFallbackNotice", 1)
        elif "export function buildFallbackNotice" in text:
            text = text.replace("export function buildFallbackNotice", helper + "export function buildFallbackNotice", 1)
    text = text.replace(old, new)
    text = text.replace(old_clear_a, new_clear_a)
    text = text.replace(old_clear_b, new_clear_b)
    if text != orig:
        p.write_text(text, encoding="utf-8")
        hits.append(str(p))
if not hits:
    raise SystemExit("could not find Model Fallback formatter; OpenClaw update may have changed the string")
print("patched:")
for h in hits:
    print(" ", h)
PY

systemctl restart openclaw-gateway
for i in $(seq 1 20); do
  curl -fsS --max-time 3 http://127.0.0.1:18789/healthz >/dev/null 2>&1 && break
  sleep 2
done
curl -fsS --max-time 5 http://127.0.0.1:18789/healthz; echo
echo "Fallback notices will look like:  ⚠️ Groq depleted — fallback responding: Gemini"
echo "To survive upgrades: sudo bash ~/install-persistent-fallback-notices.sh"
