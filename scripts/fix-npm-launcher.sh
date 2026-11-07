#!/usr/bin/env bash
# Fix OpenClaw's npm launcher, then install the Groq plugin.
#
# Two separate faults:
#   1. Manual `plugins install` from /home/admin fails with EACCES because
#      the openclaw user cannot traverse that cwd. Always install from /tmp.
#   2. Gateway startup npm hits EROFS because systemd ProtectHome=read-only
#      and ReadWritePaths does not include /home/openclaw/.npm.
#
# Groq is NOT added to the model policy until the plugin is on disk, so a
# failed install cannot crash-loop the gateway. Voice stays on the CLI
# transcriber (English local, Telugu ElevenLabs) — Groq's STT is not used.
#
# Run once as root:  sudo bash /home/admin/fix-npm-launcher.sh
set -uo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root: sudo bash $0" >&2
  exit 1
fi

STATE=/home/openclaw/.openclaw
OC="$STATE/bin/openclaw"
ENVFILE="$STATE/.env"
UNIT=openclaw-gateway
UNITFILE=/etc/systemd/system/${UNIT}.service
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
NPMDIR=/home/openclaw/.npm
PRIMARY_NOW="google/gemini-3.5-flash-lite"
GROQ_MODEL="groq/openai/gpt-oss-120b"
FALLBACKS='["google/gemini-3.5-flash-lite","openai/gpt-5.6-terra"]'
CLI_AUDIO='[{"type":"cli","command":"/home/openclaw/.openclaw/bin/transcribe-audio.sh","args":["{{AttachmentPath}}","{{OutputDir}}"],"capabilities":["audio"],"timeoutSeconds":120}]'
CLI_PREF='cli:/home/openclaw/.openclaw/bin/transcribe-audio.sh'

oc() { sudo -n -u openclaw -H "$OC" "$@"; }

wait_healthy() {
  local i
  for i in $(seq 1 30); do
    if systemctl is-active --quiet "$UNIT" \
      && curl -fsS --max-time 3 http://127.0.0.1:18789/healthz >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  return 1
}

restore_unit() {
  if [[ -f "$UNITFILE.bak-$STAMP" ]]; then
    cp -a "$UNITFILE.bak-$STAMP" "$UNITFILE"
    systemctl daemon-reload
  fi
}

echo "=== 0. gateway must be healthy first ==="
wait_healthy || { echo "gateway is not healthy; aborting" >&2; exit 1; }
echo "gateway healthy"

echo "=== 1. make ~/.npm writable inside the gateway sandbox ==="
[[ -f "$UNITFILE" ]] || { echo "missing $UNITFILE" >&2; exit 1; }
cp -a "$UNITFILE" "$UNITFILE.bak-$STAMP"
echo "backup: $UNITFILE.bak-$STAMP"

install -d -m 755 -o openclaw -g openclaw "$NPMDIR"
install -d -m 755 -o openclaw -g openclaw "$NPMDIR/_logs"
install -d -m 755 -o openclaw -g openclaw "$NPMDIR/_cacache"
install -d -m 755 -o openclaw -g openclaw /home/openclaw/.cache

python3 - "$UNITFILE" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
text = p.read_text(encoding="utf-8")
old = "ReadWritePaths=/home/openclaw/.openclaw /home/openclaw/.cache/openclaw-1001"
new = "ReadWritePaths=/home/openclaw/.openclaw /home/openclaw/.cache /home/openclaw/.npm"
if old in text:
    text = text.replace(old, new, 1)
    p.write_text(text, encoding="utf-8")
    print("updated ReadWritePaths")
elif "/home/openclaw/.npm" in text:
    print("ReadWritePaths already includes ~/.npm")
else:
    raise SystemExit("could not find expected ReadWritePaths line")
PY

systemctl daemon-reload
systemctl restart "$UNIT"
wait_healthy || {
  echo "gateway unhealthy after unit change; reverting unit" >&2
  restore_unit
  systemctl reset-failed "$UNIT"
  systemctl restart "$UNIT"
  wait_healthy || echo "revert also failed; journalctl -u $UNIT" >&2
  exit 1
}
echo "gateway healthy with writable ~/.npm"

echo "=== 2. install @openclaw/groq-provider from /tmp (not /home/admin) ==="
cd /tmp
set +e
INSTALL_OUT="$(sudo -n -u openclaw -H env HOME=/home/openclaw \
  npm_config_cache="$NPMDIR" \
  "$OC" plugins install npm:@openclaw/groq-provider 2>&1)"
INSTALL_RC=$?
set -e
printf '%s\n' "$INSTALL_OUT" | tail -n 40
if [[ "$INSTALL_RC" -ne 0 ]]; then
  echo "plugin install failed (exit $INSTALL_RC). Gateway left on Gemini. Unit change kept so future npm can write." >&2
  exit 1
fi
echo "plugin install exit 0"

echo "=== 3. Groq API key ==="
if grep -q '^GROQ_API_KEY=.' "$ENVFILE" 2>/dev/null; then
  echo "GROQ_API_KEY already in $ENVFILE"
  GROQ_OK=1
else
  echo "Paste the Groq API key from console.groq.com/keys. It will not be echoed."
  echo "Enter skips Groq as a chat model (plugin stays installed)."
  read -r -s GROQ_KEY </dev/tty; echo
  GROQ_OK=0
  if [[ -n "${GROQ_KEY:-}" ]]; then
    cfg="$(mktemp)"; chmod 600 "$cfg"
    printf 'url = "https://api.groq.com/openai/v1/models"\nheader = "Authorization: Bearer %s"\n' "$GROQ_KEY" >"$cfg"
    CODE="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 30 --config "$cfg" 2>/dev/null || echo 000)"
    rm -f "$cfg"
    if [[ "$CODE" == "200" ]]; then
      cp -a "$ENVFILE" "$ENVFILE.bak-$STAMP"
      sed -i '/^GROQ_API_KEY=/d' "$ENVFILE"
      printf 'GROQ_API_KEY=%s\n' "$GROQ_KEY" >>"$ENVFILE"
      chown openclaw:openclaw "$ENVFILE"
      chmod 600 "$ENVFILE"
      GROQ_OK=1
      echo "Groq key accepted and stored"
    else
      echo "Groq key rejected (HTTP $CODE); plugin installed, chat stays on Gemini" >&2
    fi
  fi
  unset GROQ_KEY
fi

echo "=== 4. allowlist groq, keep Gemini primary until catalog proves live ==="
oc config set plugins.allow \
  '["memory-core","openai","telegram","device-pair","ollama","google","groq"]' \
  --strict-json --replace
oc config set agents.defaults.modelPolicy.allow \
  '["openai/*","google/*","groq/*"]' --strict-json --replace
oc config set tools.media.models "$CLI_AUDIO" --strict-json --replace
oc config set tools.media.audio.preferredModel "$CLI_PREF"

systemctl restart "$UNIT"
if ! wait_healthy; then
  echo "gateway unhealthy after enabling groq; reverting policy to Gemini-only" >&2
  oc config set plugins.allow \
    '["memory-core","openai","telegram","device-pair","ollama","google"]' \
    --strict-json --replace
  oc config set agents.defaults.modelPolicy.allow \
    '["openai/*","google/*"]' --strict-json --replace
  oc config set agents.defaults.model.primary "$PRIMARY_NOW"
  systemctl reset-failed "$UNIT"
  systemctl restart "$UNIT"
  wait_healthy || echo "revert failed; journalctl -u $UNIT" >&2
  exit 1
fi
echo "gateway healthy with groq plugin loaded"

if [[ "$GROQ_OK" -eq 1 ]]; then
  echo "=== 5. groq catalog ==="
  oc models list --provider groq 2>&1 | tail -n 20
  if oc models list --provider groq 2>&1 | grep -q 'gpt-oss-120b'; then
    echo "=== 6. primary groq, Gemini then GPT as fallbacks ==="
    oc config set agents.defaults.model.primary "$GROQ_MODEL"
    oc config set agents.defaults.model.fallbacks "$FALLBACKS" --strict-json --replace
    oc config get agents.defaults.model
    systemctl restart "$UNIT"
    if ! wait_healthy; then
      echo "unhealthy after primary switch; restoring Gemini primary" >&2
      oc config set agents.defaults.model.primary "$PRIMARY_NOW"
      oc config set agents.defaults.model.fallbacks '["openai/gpt-5.6-terra"]' --strict-json --replace
      systemctl reset-failed "$UNIT"
      systemctl restart "$UNIT"
      wait_healthy || true
      exit 1
    fi
  else
    echo "gpt-oss-120b not in catalog; leaving primary on Gemini" >&2
  fi
else
  echo "no Groq key; plugin is installed, chat stays on Gemini"
fi

echo "=== verify CLI audio still pinned ==="
oc config get tools.media.audio.preferredModel
echo
echo "healthz=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1:18789/healthz)"
echo "primary now:"
oc config get agents.defaults.model
echo
echo "Rollback unit: sudo cp -a $UNITFILE.bak-$STAMP $UNITFILE && sudo systemctl daemon-reload && sudo systemctl restart $UNIT"
echo "Rollback model: sudo -n -u openclaw -H $OC config set agents.defaults.model.primary $PRIMARY_NOW"
echo "Next: send Telegram hi. Voice notes should still route English/local, Telugu/ElevenLabs."
