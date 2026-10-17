#!/usr/bin/env bash
# Tulis ulang unit file systemd user opencode-free-bridge dengan format yang
# diterima systemd, dan pastikan jalan di runtime yang benar (Bun diutamakan).
#
# Sejak v2.3.11 installer upstream sudah menulis WorkingDirectory tanpa tanda
# kutip, jadi script ini berguna sebagai perbaikan/penulisan ulang mandiri
# (mis. unit lama dari v1.5.x yang gagal dengan "bad unit file setting").
#
# Pemakaian:
#   bash scripts/fix-systemd.sh
#   BRIDGE_DIR=/opt/opencode-free-bridge bash scripts/fix-systemd.sh
#   RUNTIME=/path/ke/node bash scripts/fix-systemd.sh   # paksa runtime

set -euo pipefail

BRIDGE_DIR="${BRIDGE_DIR:-$HOME/.opencode-free-bridge}"
UNIT_NAME="opencode-free-bridge.service"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
UNIT_FILE="$UNIT_DIR/$UNIT_NAME"
PORT="${PORT:-20129}"
HOST="${HOST:-127.0.0.1}"

if [[ ! -d "$BRIDGE_DIR" ]]; then
  echo "Direktori bridge tidak ditemukan: $BRIDGE_DIR" >&2
  exit 1
fi

if [[ ! -f "$BRIDGE_DIR/server.js" ]]; then
  echo "server.js tidak ditemukan di $BRIDGE_DIR" >&2
  exit 1
fi

# Bun diutamakan: gate free-tier upstream memeriksa TLS ClientHello, dan hanya
# Bun yang menyamai CLI (Node ditolak 403 FreeTierError).
RUNTIME="${RUNTIME:-}"
if [[ -z "$RUNTIME" ]]; then
  for candidate in "$HOME/.bun/bin/bun" "$(command -v bun || true)" "$(command -v node || true)"; do
    if [[ -n "$candidate" && -x "$candidate" ]]; then RUNTIME="$candidate"; break; fi
  done
fi
if [[ -z "$RUNTIME" ]]; then
  echo "bun/node tidak ditemukan. Install Bun: curl -fsSL https://bun.sh/install | bash" >&2
  exit 1
fi

if [[ "$(basename "$RUNTIME")" != "bun" ]]; then
  echo "PERINGATAN: runtime bukan Bun ($RUNTIME)." >&2
  echo "  Gate upstream menolak Node dengan 403 FreeTierError — pakai Bun bila ada." >&2
fi

mkdir -p "$UNIT_DIR"

cat >"$UNIT_FILE" <<EOF
[Unit]
Description=OpenCode Free Bridge (OpenAI-compatible, free-tier models)
After=network-online.target

[Service]
Type=simple
WorkingDirectory=$BRIDGE_DIR
Environment=PORT=$PORT
Environment=HOST=$HOST
ExecStart=$RUNTIME $BRIDGE_DIR/server.js
Restart=always
RestartSec=3
MemoryMax=512M

[Install]
WantedBy=default.target
EOF

echo "Unit file ditulis: $UNIT_FILE"
echo "Runtime: $RUNTIME"

systemctl --user daemon-reload
systemctl --user enable "$UNIT_NAME" >/dev/null 2>&1 || true
# Restart wajib: service yang sudah jalan tidak membaca unit baru hanya dengan
# enable --now, sehingga env lama (mis. OPENCODE_* ke relay shim) masih terpakai.
systemctl --user restart "$UNIT_NAME"

echo "Menunggu bridge aktif..."
for _ in $(seq 1 20); do
  if systemctl --user is-active --quiet "$UNIT_NAME"; then
    echo "Bridge aktif di http://$HOST:$PORT"
    exit 0
  fi
  sleep 1
done

echo "Service tidak aktif. Cek:" >&2
echo "  systemctl --user status $UNIT_NAME" >&2
echo "  journalctl --user -u $UNIT_NAME -n 50 --no-pager" >&2
exit 1
