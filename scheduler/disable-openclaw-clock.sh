#!/usr/bin/env bash
# Turn off OpenClaw's built-in clock: heartbeat cadence and user automations.
# The owner-owned systemd timer becomes the only scheduler.
set -euo pipefail

OC=/home/openclaw/.openclaw/bin/openclaw
run() { sudo -n -u openclaw -H "$OC" "$@"; }

echo "=== disable heartbeat cadence ==="
run config set agents.defaults.heartbeat.every 0m

echo "=== disable user automations ==="
json="$(run automations list --json 2>/dev/null || true)"
ids="$(printf '%s' "$json" | python3 -c '
import json, sys
raw = sys.stdin.read().strip()
if not raw:
    raise SystemExit(0)
data = json.loads(raw)
jobs = data if isinstance(data, list) else data.get("jobs") or data.get("items") or []
for job in jobs:
    decl = str(job.get("declaration") or "")
    if decl.startswith("heartbeat:"):
        continue
    job_id = job.get("id")
    if job_id:
        print(job_id)
')"

if [[ -z "$ids" ]]; then
  echo "no user automations parsed; raw list:"
  run automations list || true
else
  while read -r id; do
    [[ -z "$id" ]] && continue
    echo "disable $id"
    run automations disable "$id" || run automations edit "$id" --disable || true
  done <<<"$ids"
fi

echo "=== remaining jobs ==="
run automations list --all || run cron list --all
echo "=== heartbeat config ==="
run config get agents.defaults.heartbeat.every || true
