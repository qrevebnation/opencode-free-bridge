#!/usr/bin/env bash
# Tambah satu "jalur egress": proxy CONNECT + instance bridge kedua dengan proxy
# itu, lalu daftarkan ke 9Router sebagai connection zen-<nama>.
#
# Dipakai untuk menambah kuota per-IP dari jalur yang transport-nya tetap Bun
# (mis. hotspot HP, host SSH lain). Bukan relay — relay memutus TLS di edge dan
# ditolak gate dengan 403.
#
# Pemakaian:
#   NAME=seluler SOCKS=192.168.42.10:1080 bash scripts/add-egress-bridge.sh
#   NAME=vps SOCKS=127.0.0.1:1080          bash scripts/add-egress-bridge.sh
#   NAME=langsung BRIDGE_ONLY=1            bash scripts/add-egress-bridge.sh   # tanpa proxy
#   NAME=seluler bash scripts/add-egress-bridge.sh --delete
#
# Opsi env:
#   NAME          nama jalur (wajib) — dipakai sebagai nama service & connection
#   SOCKS         host:port SOCKS5 (kosongkan + set BRIDGE_ONLY=1 untuk langsung)
#   BRIDGE_PORT   port bridge jalur ini (default: port bebas mulai 20131)
#   PROXY_PORT    port proxy CONNECT   (default: port bebas mulai 1086)
#   SKIP_9ROUTER=1  jangan daftarkan ke 9Router

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAME="${NAME:-}"
BRIDGE_DIR="${BRIDGE_DIR:-$HOME/.opencode-free-bridge}"
BRIDGE_HOST="127.0.0.1"
SOCKS="${SOCKS:-}"
PROXY_URL="${PROXY_URL:-}"   # pakai proxy yang sudah ada (mis. http://127.0.0.1:1085)
SHIM_PORT="${SHIM_PORT:-}"   # rute lewat relay shim (relay 9Router)
PRIORITY="${PRIORITY:-}"     # priority connection di 9Router (angka kecil = didahulukan)
BRIDGE_ONLY="${BRIDGE_ONLY:-}"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
NINE_ROUTER_DB="${NINE_ROUTER_DB:-$HOME/.9router/db/data.sqlite}"
DELETE=""
[[ "${1:-}" == "--delete" ]] && DELETE=1

[[ -n "$NAME" ]] || { echo "NAME wajib diisi. Contoh: NAME=seluler SOCKS=192.168.42.10:1080 bash scripts/add-egress-bridge.sh" >&2; exit 1; }

RUNTIME=""
for candidate in "$HOME/.bun/bin/bun" "$(command -v bun || true)" "$(command -v node || true)"; do
  if [[ -n "$candidate" && -x "$candidate" ]]; then RUNTIME="$candidate"; break; fi
done
[[ -n "$RUNTIME" ]] || { echo "bun/node tidak ditemukan." >&2; exit 1; }

BRIDGE_UNIT="opencode-free-bridge-egress-$NAME.service"
PROXY_UNIT="opencode-free-bridge-proxy-$NAME.service"

port_free() { ! ss -ltn 2>/dev/null | grep -q ":$1 "; }
next_free_port() { local p="$1"; while ! port_free "$p"; do p=$((p + 1)); done; echo "$p"; }

# --------------------------------------------------------------- --delete ---
if [[ -n "$DELETE" ]]; then
  systemctl --user disable --now "$BRIDGE_UNIT" "$PROXY_UNIT" >/dev/null 2>&1 || true
  rm -f "$UNIT_DIR/$BRIDGE_UNIT" "$UNIT_DIR/$PROXY_UNIT"
  systemctl --user daemon-reload
  echo "Service jalur '$NAME' dihapus."
  if [[ -z "${SKIP_9ROUTER:-}" && -f "$NINE_ROUTER_DB" ]]; then
    "$RUNTIME" "$HERE/add-bridge-connection.js" --name "$NAME" --delete || true
  fi
  exit 0
fi

[[ -f "$BRIDGE_DIR/server.js" ]] || { echo "server.js tidak ditemukan di $BRIDGE_DIR" >&2; exit 1; }
if [[ -z "$SOCKS" && -z "$PROXY_URL" && -z "$SHIM_PORT" && -z "$BRIDGE_ONLY" ]]; then
  echo "Pilih salah satu: SOCKS=host:port | PROXY_URL=http://... | SHIM_PORT=20140 | BRIDGE_ONLY=1" >&2
  exit 1
fi

PROXY_PORT="${PROXY_PORT:-}"
BRIDGE_PORT="${BRIDGE_PORT:-}"

if [[ -n "$SOCKS" ]]; then
  PROXY_PORT="${PROXY_PORT:-$(next_free_port 1086)}"
  mkdir -p "$UNIT_DIR"
  cat >"$UNIT_DIR/$PROXY_UNIT" <<EOF
[Unit]
Description=Proxy CONNECT jalur '$NAME' (SOCKS $SOCKS)
After=network-online.target

[Service]
Type=simple
Environment=PORT=$PROXY_PORT
Environment=HOST=127.0.0.1
Environment=SOCKS_HOST=${SOCKS%%:*}
Environment=SOCKS_PORT=${SOCKS##*:}
ExecStart=$RUNTIME $HERE/connect-proxy.js
Restart=always
RestartSec=3
MemoryMax=256M

[Install]
WantedBy=default.target
EOF
  systemctl --user daemon-reload
  systemctl --user enable "$PROXY_UNIT" >/dev/null 2>&1 || true
  systemctl --user restart "$PROXY_UNIT"
  PROXY_URL="http://127.0.0.1:$PROXY_PORT"
fi

BRIDGE_PORT="${BRIDGE_PORT:-$(next_free_port 20131)}"

{
  echo "[Unit]"
  echo "Description=OpenCode Free Bridge — jalur '$NAME'"
  echo "After=network-online.target"
  [[ -n "$PROXY_PORT" ]] && echo "After=$PROXY_UNIT"
  [[ -n "$PROXY_PORT" ]] && echo "Wants=$PROXY_UNIT"
  echo
  echo "[Service]"
  echo "Type=simple"
  echo "WorkingDirectory=$BRIDGE_DIR"
  echo "Environment=PORT=$BRIDGE_PORT"
  echo "Environment=HOST=$BRIDGE_HOST"
  if [[ -n "$SHIM_PORT" ]]; then
    echo "Environment=OPENCODE_CHAT_URL=http://127.0.0.1:$SHIM_PORT/inference/v1/chat/completions"
    echo "Environment=OPENCODE_RESPONSES_URL=http://127.0.0.1:$SHIM_PORT/inference/v1/responses"
    echo "Environment=OPENCODE_MODELS_URL=http://127.0.0.1:$SHIM_PORT/inference/v1/models"
  elif [[ -n "$PROXY_URL" ]]; then
    echo "Environment=HTTPS_PROXY=$PROXY_URL"
  fi
  echo "ExecStart=$RUNTIME $BRIDGE_DIR/server.js"
  echo "Restart=always"
  echo "RestartSec=3"
  echo "MemoryMax=512M"
  echo
  echo "[Install]"
  echo "WantedBy=default.target"
} >"$UNIT_DIR/$BRIDGE_UNIT"

systemctl --user daemon-reload
systemctl --user enable "$BRIDGE_UNIT" >/dev/null 2>&1 || true
systemctl --user restart "$BRIDGE_UNIT"

echo "Jalur '$NAME': bridge :$BRIDGE_PORT${PROXY_URL:+, proxy $PROXY_URL}${SHIM_PORT:+, via shim :$SHIM_PORT}"

# ------------------------------------------------------------- verifikasi ---
IP_HOME="$(curl -s --max-time 8 https://api.ipify.org || echo '?')"
if [[ -n "$PROXY_URL" ]]; then
  for _ in $(seq 1 15); do
    curl -s -o /dev/null --max-time 3 -x "$PROXY_URL" https://api.ipify.org && break
    sleep 1
  done
  IP_JALUR="$(curl -s --max-time 8 -x "$PROXY_URL" https://api.ipify.org || echo '?')"
  echo "  IP langsung : $IP_HOME"
  echo "  IP jalur    : $IP_JALUR"
  [[ "$IP_JALUR" == "$IP_HOME" ]] && echo "  PERINGATAN: IP tidak berubah — cek proxy/host jalur ini." || true
fi

for _ in $(seq 1 20); do
  curl -s -o /dev/null --max-time 3 "http://$BRIDGE_HOST:$BRIDGE_PORT/health" && break
  sleep 1
done
MODELS="$(curl -s --max-time 20 "http://$BRIDGE_HOST:$BRIDGE_PORT/v1/models" | grep -o '"id"' | wc -l)"
echo "  Model terdeteksi: $MODELS"

# ----------------------------------------------------------- daftar 9Router ---
if [[ -z "${SKIP_9ROUTER:-}" && -f "$NINE_ROUTER_DB" ]]; then
  "$RUNTIME" "$HERE/add-bridge-connection.js" --url "http://127.0.0.1:$BRIDGE_PORT/v1" --name "$NAME" \
    ${PRIORITY:+--priority "$PRIORITY"} || \
    echo "  (registrasi 9Router gagal — jalankan manual: node scripts/add-bridge-connection.js --url http://127.0.0.1:$BRIDGE_PORT/v1 --name $NAME)"
fi

echo
echo "Selesai. Ulangi dengan NAME lain untuk menambah jalur lagi."
