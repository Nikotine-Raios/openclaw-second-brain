#!/usr/bin/env bash
# Owner-owned clock. Fires each workflow at most once per local window.
# Does not wait for a Telegram reply and does not retry a missed window.
set -euo pipefail

ROOT="${ISLAND_SCHEDULER_ROOT:-/home/admin/island-scheduler}"
# shellcheck disable=SC1091
source "$ROOT/scheduler.env"

: "${OPENCLAW:?OPENCLAW is required}"
: "${TELEGRAM_TO:?TELEGRAM_TO is required}"
: "${TZ_NAME:=UTC}"

LOCK_DIR="$ROOT/locks"
LOG_DIR="$ROOT/logs"
PROMPT_DIR="$ROOT/prompts"
mkdir -p "$LOCK_DIR" "$LOG_DIR"

local_stamp() {
  TZ="$TZ_NAME" date +"$1"
}

weekday="$(local_stamp %u)"   # 1=Mon .. 7=Sun
hour="$(local_stamp %H)"
minute="$(local_stamp %M)"
dom="$(local_stamp %d)"
today="$(local_stamp %F)"

jobs=()
if [[ "$weekday" -le 5 && "$hour" == "08" && "$minute" == "00" ]]; then
  jobs+=(daily-planning)
fi
if [[ "$weekday" == "7" && "$hour" == "22" && "$minute" == "00" ]]; then
  jobs+=(weekly-reflection)
fi
if [[ "$dom" == "01" && "$hour" == "10" && "$minute" == "00" ]]; then
  jobs+=(career-development)
fi
if [[ "$dom" == "01" && "$hour" == "10" && "$minute" == "15" ]]; then
  jobs+=(personal-project)
fi

if [[ "${1:-}" == "--force" && -n "${2:-}" ]]; then
  jobs=("$2")
fi

if [[ ${#jobs[@]} -eq 0 ]]; then
  echo "$(date -u +%FT%TZ) skip window weekday=$weekday hour=$hour minute=$minute tz=$TZ_NAME"
  exit 0
fi

run_job() {
  local name="$1"
  local lock="$LOCK_DIR/${name}-${today}.lock"
  local prompt="$PROMPT_DIR/${name}.txt"
  local log="$LOG_DIR/${name}-${today}.log"

  if [[ ! -f "$prompt" ]]; then
    echo "missing prompt: $prompt" >&2
    return 1
  fi

  if [[ -e "$lock" ]]; then
    echo "$(date -u +%FT%TZ) already sent $name for $today" | tee -a "$log"
    return 0
  fi

  echo "$(date -u +%FT%TZ) start $name" | tee -a "$log"
  # OpenClaw runs as user openclaw and cannot read /home/admin (mode 750).
  tmp="$(mktemp /tmp/island-scheduler.XXXXXX.txt)"
  cp "$prompt" "$tmp"
  chmod 644 "$tmp"
  if sudo -n -u openclaw -H "$OPENCLAW" agent \
    --agent main \
    --message-file "$tmp" \
    --channel telegram \
    --to "$TELEGRAM_TO" \
    --deliver \
    --session-key "island-scheduler:${name}:${today}" \
    --timeout 180 \
    >>"$log" 2>&1; then
    rm -f "$tmp"
    printf '%s\n' "$(date -u +%FT%TZ)" >"$lock"
    echo "$(date -u +%FT%TZ) delivered $name" | tee -a "$log"
  else
    rm -f "$tmp"
    echo "$(date -u +%FT%TZ) failed $name" | tee -a "$log"
    return 1
  fi
}

status=0
for job in "${jobs[@]}"; do
  run_job "$job" || status=1
done
exit "$status"
