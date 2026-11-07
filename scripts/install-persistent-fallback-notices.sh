#!/usr/bin/env bash
# Keep custom fallback notices across OpenClaw upgrades.
# Installs a patcher and runs it as ExecStartPre (+) so every gateway start
# rewrites the stock "Model Fallback:" line after an upgrade replaces the JS.
set -euo pipefail
if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root: sudo bash $0" >&2
  exit 1
fi

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
PATCHER_SRC="$SRC_DIR/openclaw-pretty-fallback-notices"
if [[ ! -f "$PATCHER_SRC" ]]; then
  PATCHER_SRC="/home/admin/openclaw-pretty-fallback-notices"
fi
[[ -f "$PATCHER_SRC" ]] || { echo "missing patcher next to this script" >&2; exit 1; }

install -d /usr/local/sbin
install -m 755 "$PATCHER_SRC" /usr/local/sbin/openclaw-pretty-fallback-notices
# Strip Windows CRLF if the file was scp'd from PowerShell.
sed -i 's/\r$//' /usr/local/sbin/openclaw-pretty-fallback-notices
# File may have been uploaded without a shebang after copy; python3 is explicit in the unit.

install -d /etc/systemd/system/openclaw-gateway.service.d
cat >/etc/systemd/system/openclaw-gateway.service.d/pretty-fallback.conf <<'EOF'
[Service]
# + = run as root even though the service User=openclaw
ExecStartPre=+/usr/bin/python3 /usr/local/sbin/openclaw-pretty-fallback-notices
EOF

systemctl daemon-reload
/usr/bin/python3 /usr/local/sbin/openclaw-pretty-fallback-notices
systemctl restart openclaw-gateway
for i in $(seq 1 25); do
  curl -fsS --max-time 3 http://127.0.0.1:18789/healthz >/dev/null 2>&1 && break
  sleep 2
done
curl -fsS --max-time 5 http://127.0.0.1:18789/healthz; echo
echo "Installed. Every gateway start re-applies: ⚠️ Groq depleted — fallback responding: Gemini"
echo "Drop-in: /etc/systemd/system/openclaw-gateway.service.d/pretty-fallback.conf"
echo "Patcher: /usr/local/sbin/openclaw-pretty-fallback-notices"
