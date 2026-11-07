#!/usr/bin/env bash
# Install the owner-owned Island scheduler. Run once as root:
#   sudo bash /home/admin/island-scheduler/install.sh
set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root: sudo bash $0" >&2
  exit 1
fi

SRC="$(cd "$(dirname "$0")" && pwd)"
DEST=/home/admin/island-scheduler
UNIT_DIR=/etc/systemd/system

install -d -m 750 -o admin -g admin "$DEST" "$DEST/locks" "$DEST/logs" "$DEST/prompts"
if [[ "$SRC" != "$DEST" ]]; then
  install -m 750 -o admin -g admin "$SRC/run-workflow.sh" "$DEST/run-workflow.sh"
  install -m 750 -o admin -g admin "$SRC/disable-openclaw-clock.sh" "$DEST/disable-openclaw-clock.sh"
  install -m 640 -o admin -g admin "$SRC/prompts/"*.txt "$DEST/prompts/"
else
  chmod 750 "$DEST/run-workflow.sh" "$DEST/disable-openclaw-clock.sh"
  chmod 640 "$DEST/prompts/"*.txt
fi

if [[ ! -f "$DEST/scheduler.env" ]]; then
  if [[ -f "$SRC/scheduler.env" ]]; then
    install -m 600 -o admin -g admin "$SRC/scheduler.env" "$DEST/scheduler.env"
  else
    install -m 600 -o admin -g admin "$SRC/scheduler.env.example" "$DEST/scheduler.env"
    echo "Wrote $DEST/scheduler.env from example. Confirm TELEGRAM_TO before enabling timers." >&2
  fi
fi

install -m 440 "$SRC/sudoers.d/island-scheduler" /etc/sudoers.d/island-scheduler
visudo -cf /etc/sudoers.d/island-scheduler

install -m 644 "$SRC/systemd/island-scheduler.service" "$UNIT_DIR/island-scheduler.service"
install -m 644 "$SRC/systemd/island-scheduler.timer" "$UNIT_DIR/island-scheduler.timer"
systemctl daemon-reload
systemctl enable --now island-scheduler.timer
systemctl list-timers island-scheduler.timer --no-pager

echo "=== disable OpenClaw clock ==="
sudo -u admin -H bash "$DEST/disable-openclaw-clock.sh"

echo "Installed. Clock owner is systemd timer island-scheduler.timer."
echo "OpenClaw main is handoff-only. Heartbeat cadence is 0m."
