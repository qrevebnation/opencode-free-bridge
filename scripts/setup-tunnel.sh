#!/usr/bin/env bash
# Pindahkan IP egress bridge lewat jaringan host lain, TANPA memasang apa pun di
# host itu — cukup SSH (yang biasanya sudah ada).
#
# Kenapa bukan relay: relay (Vercel/Cloudflare/Deno) memutus TLS di sisi edge,
# sehingga gate free-tier OpenCode menolaknya dengan 403 FreeTierError (egress
# datacenter + fingerprint bukan Bun). Proxy ini hanya memindahkan IP; TLS tetap
# end-to-end dari Bun, jadi gate lolos dan kuota per-IP host itu yang dipakai.
#
# Alur:
#   bridge ──HTTPS_PROXY──▶ connect-proxy lokal ──SOCKS5──▶ ssh -D ──▶ internet
#
# Pemakaian:
#   TUNNEL_HOST=host-ssh bash scripts/setup-tunnel.sh
#
# Opsi env:
#   TUNNEL_HOST   host SSH tujuan (wajib), mis. host-ssh / user@1.2.3.4
#   SOCKS_PORT    port SOCKS lokal       (default 1080)
#   PROXY_PORT    port proxy CONNECT     (default 1085)
#   BRIDGE_DIR    lokasi instalasi bridge (default ~/.opencode-free-bridge)
#   PORT/HOST     port/bind bridge       (default 20129 / 127.0.0.1)

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TUNNEL_HOST="${TUNNEL_HOST:-}"
SOCKS_PORT="${SOCKS_PORT:-1080}"
PROXY_PORT="${PROXY_PORT:-1085}"
BRIDGE_DIR="${BRIDGE_DIR:-$HOME/.opencode-free-bridge}"
PORT="${PORT:-20129}"
HOST="${HOST:-127.0.0.1}"
IP_LIMIT_STATUS="${IP_LIMIT_STATUS:-429}"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
STATE_DIR="$HOME/.local/state/opencode-free-bridge"

if [[ -z "$TUNNEL_HOST" ]]; then
  echo "TUNNEL_HOST wajib diisi. Contoh: TUNNEL_HOST=host-ssh bash scripts/setup-tunnel.sh" >&2
  exit 1
fi

RUNTIME=""
for candidate in "$HOME/.bun/bin/bun" "$(command -v bun || true)" "$(command -v node || true)"; do
  if [[ -n "$candidate" && -x "$candidate" ]]; then RUNTIME="$candidate"; break; fi
done
[[ -n "$RUNTIME" ]] || { echo "bun/node tidak ditemukan." >&2; exit 1; }

[[ -f "$BRIDGE_DIR/server.js" ]] || { echo "server.js tidak ditemukan di $BRIDGE_DIR" >&2; exit 1; }
command -v ssh >/dev/null || { echo "ssh tidak ditemukan." >&2; exit 1; }

mkdir -p "$UNIT_DIR" "$STATE_DIR"

# --- 1. tunnel SSH (SOCKS5) -------------------------------------------------
cat >"$UNIT_DIR/opencode-free-bridge-tunnel.service" <<EOF
[Unit]
Description=SSH SOCKS tunnel untuk opencode-free-bridge ($TUNNEL_HOST)
After=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/ssh -N -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -D 127.0.0.1:$SOCKS_PORT $TUNNEL_HOST
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
EOF

# --- 2. proxy CONNECT lokal -------------------------------------------------
cat >"$UNIT_DIR/opencode-free-bridge-connect-proxy.service" <<EOF
[Unit]
Description=Proxy CONNECT lokal bridge (SOCKS 127.0.0.1:$SOCKS_PORT)
After=network-online.target opencode-free-bridge-tunnel.service
Wants=opencode-free-bridge-tunnel.service

[Service]
Type=simple
Environment=PORT=$PROXY_PORT
Environment=HOST=127.0.0.1
Environment=SOCKS_HOST=127.0.0.1
Environment=SOCKS_PORT=$SOCKS_PORT
ExecStart=$RUNTIME $HERE/connect-proxy.js
Restart=always
RestartSec=3
MemoryMax=256M

[Install]
WantedBy=default.target
EOF

# --- 3. bridge memakai proxy itu -------------------------------------------
cat >"$UNIT_DIR/opencode-free-bridge.service" <<EOF
[Unit]
Description=OpenCode Free Bridge (OpenAI-compatible, free-tier models)
After=network-online.target opencode-free-bridge-connect-proxy.service
Wants=opencode-free-bridge-connect-proxy.service

[Service]
Type=simple
WorkingDirectory=$BRIDGE_DIR
Environment=PORT=$PORT
Environment=HOST=$HOST
Environment=HTTPS_PROXY=http://127.0.0.1:$PROXY_PORT
Environment=IP_LIMIT_STATUS=$IP_LIMIT_STATUS
ExecStart=$RUNTIME $BRIDGE_DIR/server.js
Restart=always
RestartSec=3
MemoryMax=512M

[Install]
WantedBy=default.target
EOF

echo "Unit files ditulis di $UNIT_DIR"
echo "  - opencode-free-bridge-tunnel.service"
echo "  - opencode-free-bridge-connect-proxy.service"
echo "  - opencode-free-bridge.service (HTTPS_PROXY=http://127.0.0.1:$PROXY_PORT)"

systemctl --user daemon-reload
systemctl --user enable opencode-free-bridge-tunnel.service opencode-free-bridge-connect-proxy.service opencode-free-bridge.service >/dev/null 2>&1 || true
systemctl --user restart opencode-free-bridge-tunnel.service
systemctl --user restart opencode-free-bridge-connect-proxy.service
systemctl --user restart opencode-free-bridge.service

echo "Menunggu proxy dan bridge siap..."
for _ in $(seq 1 20); do
  if curl -s -o /dev/null --max-time 3 -x "http://127.0.0.1:$PROXY_PORT" "https://api.ipify.org"; then break; fi
  sleep 1
done

IP_HOME="$(curl -s --max-time 8 https://api.ipify.org || echo '?')"
IP_TUNNEL="$(curl -s --max-time 8 -x "http://127.0.0.1:$PROXY_PORT" https://api.ipify.org || echo '?')"

echo
echo "IP langsung     : $IP_HOME"
echo "IP lewat tunnel : $IP_TUNNEL"
if [[ "$IP_TUNNEL" == "$IP_HOME" ]]; then
  echo "PERINGATAN: IP tidak berubah — host tujuan kemungkinan satu jaringan denganmu."
else
  echo "OK: egress bridge sekarang dari $TUNNEL_HOST."
fi
echo
echo "Cek   : curl -s http://$HOST:$PORT/v1/models | head -c 120"
echo "Log   : journalctl --user -u opencode-free-bridge-tunnel -f"
echo "Status: systemctl --user status opencode-free-bridge-tunnel opencode-free-bridge-connect-proxy"
