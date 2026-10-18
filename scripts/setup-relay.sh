#!/usr/bin/env bash
# [EKSPERIMENTAL] Pasang relay shim sebagai service systemd user dan arahkan
# bridge melewatinya, supaya egress ke opencode.ai keluar dari IP relay.
#
# Baca dulu: sejak upstream v2.3.x, gate free-tier memeriksa TLS ClientHello dan
# hanya Bun yang menyamai CLI. Relay (Vercel/edge) tidak bisa meniru fingerprint
# itu, sehingga sebagian relay ditolak `403 FreeTierError`. Rotasi + failover di
# relay-shim.js menutupi itu, tapi jalur yang stabil tetap "Multiple hosts"
# (lihat SETUP.md).
#
# Pemakaian:
#   RELAY_URLS="https://relay-a.vercel.app,https://relay-b.vercel.app" \
#     bash scripts/setup-relay.sh
#
# Ambil URL relay dari: 9Router → Proxy Pools (kolom proxyUrl), atau:
#   sqlite3 ~/.9router/db/data.sqlite "SELECT json_extract(data,'$.proxyUrl') FROM proxyPools;"

set -euo pipefail

BRIDGE_DIR="${BRIDGE_DIR:-$HOME/.opencode-free-bridge}"
SHIM_PORT="${SHIM_PORT:-20140}"
PORT="${PORT:-20129}"
HOST="${HOST:-127.0.0.1}"
SHIM_SRC="${SHIM_SRC:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/relay-shim.js}"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"

if [[ -z "${RELAY_URLS:-}" ]]; then
  echo 'RELAY_URLS wajib diisi (dipisah koma).' >&2
  echo 'Contoh: RELAY_URLS="https://relay-a.vercel.app,https://relay-b.vercel.app"' >&2
  exit 1
fi

[[ -f "$SHIM_SRC" ]] || { echo "relay-shim.js tidak ditemukan: $SHIM_SRC" >&2; exit 1; }
[[ -f "$BRIDGE_DIR/server.js" ]] || { echo "server.js tidak ditemukan di $BRIDGE_DIR" >&2; exit 1; }

# Bun diutamakan untuk bridge (gate TLS); shim sendiri bebas runtime.
RUNTIME="${RUNTIME:-}"
if [[ -z "$RUNTIME" ]]; then
  for candidate in "$HOME/.bun/bin/bun" "$(command -v bun || true)" "$(command -v node || true)"; do
    if [[ -n "$candidate" && -x "$candidate" ]]; then RUNTIME="$candidate"; break; fi
  done
fi
[[ -n "$RUNTIME" ]] || { echo "bun/node tidak ditemukan." >&2; exit 1; }

mkdir -p "$UNIT_DIR"
mkdir -p "$HOME/.local/state/opencode-free-bridge"

cat >"$UNIT_DIR/opencode-free-bridge-relay.service" <<EOF
[Unit]
Description=OpenCode Free Bridge relay shim (rotasi proxy pool 9Router)
After=network-online.target

[Service]
Type=simple
Environment=PORT=$SHIM_PORT
Environment=HOST=127.0.0.1
Environment=RELAY_URLS=$RELAY_URLS
Environment=RELAY_COOLDOWN_MS=${RELAY_COOLDOWN_MS:-60000}
Environment=RELAY_FALLBACK_DIRECT=${RELAY_FALLBACK_DIRECT:-1}
Environment=DEBUG_LOG=$HOME/.local/state/opencode-free-bridge/relay-shim.log
ExecStart=$RUNTIME $SHIM_SRC
Restart=always
RestartSec=3
MemoryMax=256M

[Install]
WantedBy=default.target
EOF

cat >"$UNIT_DIR/opencode-free-bridge.service" <<EOF
[Unit]
Description=OpenCode Free Bridge (OpenAI-compatible, free-tier models)
After=network-online.target opencode-free-bridge-relay.service
Wants=opencode-free-bridge-relay.service

[Service]
Type=simple
WorkingDirectory=$BRIDGE_DIR
Environment=PORT=$PORT
Environment=HOST=$HOST
Environment=OPENCODE_CHAT_URL=http://127.0.0.1:$SHIM_PORT/inference/v1/chat/completions
Environment=OPENCODE_RESPONSES_URL=http://127.0.0.1:$SHIM_PORT/inference/v1/responses
Environment=OPENCODE_MODELS_URL=http://127.0.0.1:$SHIM_PORT/inference/v1/models
ExecStart=$RUNTIME $BRIDGE_DIR/server.js
Restart=always
RestartSec=3
MemoryMax=512M

[Install]
WantedBy=default.target
EOF

echo "Unit files ditulis di $UNIT_DIR"

systemctl --user daemon-reload
systemctl --user enable opencode-free-bridge-relay.service >/dev/null 2>&1 || true
# Restart wajib: service yang sudah jalan tidak memuat unit/kode baru dengan enable --now.
systemctl --user restart opencode-free-bridge-relay.service

echo "Menunggu relay shim aktif..."
for _ in $(seq 1 20); do
  if systemctl --user is-active --quiet opencode-free-bridge-relay.service; then break; fi
  sleep 1
done

systemctl --user restart opencode-free-bridge.service
systemctl --user enable opencode-free-bridge.service >/dev/null

echo "Menunggu bridge aktif..."
for _ in $(seq 1 30); do
  if systemctl --user is-active --quiet opencode-free-bridge.service; then break; fi
  sleep 1
done

echo
echo "Relay shim : http://127.0.0.1:$SHIM_PORT"
echo "Bridge     : http://127.0.0.1:$PORT"
echo "Relay      : $RELAY_URLS"
echo
echo "Cek: curl -s http://127.0.0.1:$PORT/v1/models | head -c 120"
echo "Log shim: journalctl --user -u opencode-free-bridge-relay -f"
