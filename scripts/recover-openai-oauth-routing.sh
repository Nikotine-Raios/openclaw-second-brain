#!/usr/bin/env bash
# Recover ChatGPT/Codex OAuth routing on a host that uses a custom
# systemd unit (openclaw-gateway) and user `openclaw`.
# Prints no tokens, emails, or profile ids.
set -euo pipefail

OC=/home/openclaw/.openclaw/bin/openclaw
UNIT=openclaw-gateway
MSG='Reply exactly: OPENCLAW_MODEL_OK'

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root: sudo bash $0" >&2
  exit 1
fi

if [[ ! -x "$OC" ]]; then
  echo "OpenClaw CLI not found at $OC" >&2
  exit 1
fi

run() {
  sudo -u openclaw -H "$OC" "$@"
}

wait_health() {
  local i
  for i in $(seq 1 30); do
    if systemctl is-active --quiet "$UNIT" && curl -fsS --max-time 3 http://127.0.0.1:18789/healthz >/dev/null; then
      echo "gateway: healthy"
      return 0
    fi
    sleep 2
  done
  echo "gateway: not healthy after restart wait" >&2
  systemctl --no-pager --full status "$UNIT" || true
  return 1
}

echo "=== Codex trust ==="
TRUST="$(run plugins inspect codex --json 2>/dev/null || true)"
if printf '%s' "$TRUST" | grep -Eq 'archive|provenance-invalid'; then
  echo "codex: untrusted archive overlay; reinstalling official catalog copy"
  run plugins uninstall codex --force || true
  run plugins install @openclaw/codex --accept-capabilities
  run plugins enable codex || true
  systemctl restart "$UNIT"
  wait_health
else
  echo "codex: inspect did not report archive provenance"
fi

echo "=== Policy ==="
run config set agents.defaults.modelPolicy.allow '["openai/*"]' --strict-json --replace
run config set agents.entries.main.modelPolicy.allow '["openai/*"]' --strict-json --replace

echo "=== Auth order (profile id not printed) ==="
if run models auth order get --provider openai >/tmp/openclaw-auth-order.out 2>/tmp/openclaw-auth-order.err; then
  echo "auth.order.openai: present or default"
else
  echo "auth.order.openai: get failed; operator must set it locally from models auth list"
fi
rm -f /tmp/openclaw-auth-order.out /tmp/openclaw-auth-order.err

wait_health

CANDIDATES=(
  openai/gpt-5.6-sol
  openai/gpt-5.6-terra
  openai/gpt-5.6-luna
  openai/gpt-5.5
  openai/gpt-5.3-codex-spark
)

WINNER=""
for model in "${CANDIDATES[@]}"; do
  echo "=== Probe $model ==="
  set +e
  OUT="$(run agent --agent main --model "$model" --message "$MSG" --timeout 180 2>&1)"
  RC=$?
  set -e
  if printf '%s' "$OUT" | grep -q 'ECONNREFUSED'; then
    echo "result: gateway not ready; waiting and retrying once"
    wait_health
    set +e
    OUT="$(run agent --agent main --model "$model" --message "$MSG" --timeout 180 2>&1)"
    RC=$?
    set -e
  fi
  if printf '%s' "$OUT" | grep -q 'OPENCLAW_MODEL_OK'; then
    echo "result: PASS"
    WINNER="$model"
    break
  elif printf '%s' "$OUT" | grep -q 'not found by the provider'; then
    echo "result: model_not_found"
  elif printf '%s' "$OUT" | grep -q 'No route-compatible authentication source'; then
    echo "result: route_incompatible"
  elif printf '%s' "$OUT" | grep -q 'not allowed'; then
    echo "result: model_policy_denied"
  else
    echo "result: other_failure rc=$RC"
    printf '%s\n' "$OUT" | sed -E '/@|token|sk-|Bearer|profile/Id' | tail -n 20
  fi
done

if [[ -n "$WINNER" ]]; then
  echo "=== Persist $WINNER ==="
  if ! run models set "$WINNER"; then
    echo "models set failed; writing agents.defaults.model.primary instead"
    run config set agents.defaults.model.primary "$WINNER"
  fi
  echo "WORKING_MODEL=$WINNER"
  exit 0
fi

echo "WORKING_MODEL="
echo "No candidate returned OPENCLAW_MODEL_OK. Re-check Codex trust and OAuth profile locally."
exit 2
