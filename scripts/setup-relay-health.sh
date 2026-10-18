#!/usr/bin/env bash
# Pasang pengecekan relay berkala (systemd user timer) yang menjalankan
# scripts/check-relays.sh dan mencatat hasilnya ke relay-health.log.
#
# Pemakaian:
#   bash scripts/setup-relay-health.sh              # tiap 30 menit
#   INTERVAL=15min bash scripts/setup-relay-health.sh
#   bash scripts/setup-relay-health.sh --delete

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
STATE_DIR="$HOME/.local/state/opencode-free-bridge"
SERVICE="opencode-free-bridge-relay-health.service"
TIMER="opencode-free-bridge-relay-health.timer"
INTERVAL="${INTERVAL:-30min}"

mkdir -p "$UNIT_DIR" "$STATE_DIR"

if [[ "${1:-}" == "--delete" ]]; then
  systemctl --user disable --now "$TIMER" >/dev/null 2>&1 || true
  rm -f "$UNIT_DIR/$SERVICE" "$UNIT_DIR/$TIMER"
  systemctl --user daemon-reload
  echo "Pengecekan berkala dihapus."
  exit 0
fi

[[ -f "$HERE/check-relays.sh" ]] || { echo "check-relays.sh tidak ditemukan di $HERE" >&2; exit 1; }

cat >"$UNIT_DIR/$SERVICE" <<EOF
[Unit]
Description=Cek kesehatan relay opencode-free-bridge
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/bin/env bash $HERE/check-relays.sh
EOF

cat >"$UNIT_DIR/$TIMER" <<EOF
[Unit]
Description=Cek relay berkala (setiap $INTERVAL)

[Timer]
OnBootSec=3min
OnUnitActiveSec=$INTERVAL
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl --user daemon-reload
systemctl --user enable --now opencode-free-bridge-relay-health.timer >/dev/null

echo "Timer aktif (setiap $INTERVAL)."
echo "  Jadwal berikutnya : systemctl --user list-timers opencode-free-bridge-relay-health.timer"
echo "  Jalankan sekarang : systemctl --user start $SERVICE"
echo "  Hasil             : $STATE_DIR/relay-health.log"
