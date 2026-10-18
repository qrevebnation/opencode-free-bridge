#!/usr/bin/env bash
# Rantai egress bertingkat otomatis:
#   tingkat 1: IP sendiri (langsung)
#   tingkat 2: SSH ke host lain  (dipakai saat tingkat 1 habis)
#   tingkat 3: relay 9Router     (dipakai saat tingkat 1 & 2 habis)
#
# Tiap tingkat adalah instance bridge sendiri dengan port berbeda; 9Router
# memilih berdasarkan priority (angka kecil didahulukan) dengan strategi
# "fill-first": pakai yang pertama selama bisa, pindah otomatis saat kena
# 429/403 (connection dikunci sementara oleh 9Router).
#
# Pemakaian:
#   TUNNEL_HOST=host-ssh bash scripts/setup-chain.sh
#   TUNNEL_HOST=host-ssh bash scripts/setup-chain.sh --delete   # bongkar tingkat 2 & 3
#
# Opsi env:
#   TUNNEL_HOST   host SSH untuk tingkat 2 (lewati tingkat ini kalau kosong)
#   BASE_PORT     port bridge tingkat tambahan (default 20131, +2 per tingkat)
#   PROXY_PORT    port proxy SSH  (default 1085)
#   SOCKS_PORT    port SOCKS SSH  (default 1080)
#   SHIM_PORT     port relay shim (default 20140)

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TUNNEL_HOST="${TUNNEL_HOST:-}"
PROXY_PORT="${PROXY_PORT:-1085}"
SOCKS_PORT="${SOCKS_PORT:-1080}"
SHIM_PORT="${SHIM_PORT:-20140}"
TIER2_PORT="${TIER2_PORT:-20131}"
TIER3_PORT="${TIER3_PORT:-20133}"
NINE_ROUTER_DB="${NINE_ROUTER_DB:-$HOME/.9router/db/data.sqlite}"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"

RUNTIME=""
for candidate in "$HOME/.bun/bin/bun" "$(command -v bun || true)" "$(command -v node || true)"; do
  if [[ -n "$candidate" && -x "$candidate" ]]; then RUNTIME="$candidate"; break; fi
done
[[ -n "$RUNTIME" ]] || { echo "bun/node tidak ditemukan." >&2; exit 1; }

step() { printf "\n\033[1m== %s\033[0m\n" "$1"; }
info() { printf "   %s\n" "$1"; }

# --------------------------------------------------------------- --delete ---
if [[ "${1:-}" == "--delete" ]]; then
  NAME=ssh   bash "$HERE/add-egress-bridge.sh" --delete || true
  NAME=relay bash "$HERE/add-egress-bridge.sh" --delete || true
  systemctl --user disable --now opencode-free-bridge-relay >/dev/null 2>&1 || true
  "$RUNTIME" "$HERE/set-chain-strategy.js" reset 2>/dev/null || true
  echo "Tingkat 2 & 3 dibongkar; bridge utama tetap ada."
  exit 0
fi

# ------------------------------------------------------ tingkat 2: tunnel ---
step "Tingkat 2 — tunnel SSH"
if [[ -n "$TUNNEL_HOST" ]]; then
  TUNNEL_HOST="$TUNNEL_HOST" SOCKS_PORT="$SOCKS_PORT" PROXY_PORT="$PROXY_PORT" \
    bash "$HERE/setup-tunnel.sh" >/dev/null
  info "tunnel + proxy siap (SOCKS :$SOCKS_PORT -> proxy :$PROXY_PORT, host $TUNNEL_HOST)"
else
  info "TUNNEL_HOST kosong — tingkat 2 dilewati."
fi

# ------------------------------------------------------- tingkat 3: relay ---
step "Tingkat 3 — relay"
RELAY_URLS_COUNT=0
if [[ -f "$NINE_ROUTER_DB" ]] && command -v sqlite3 >/dev/null; then
  RELAY_URLS_COUNT="$(sqlite3 "$NINE_ROUTER_DB" "SELECT count(*) FROM proxyPools WHERE isActive=1;" 2>/dev/null || echo 0)"
fi
if [[ "$RELAY_URLS_COUNT" -gt 0 ]]; then
  if [[ ! -f "$UNIT_DIR/opencode-free-bridge-relay.service" ]]; then
    info "membuat unit relay shim..."
    bash "$HERE/setup-relay.sh" >/dev/null || true
  fi
  systemctl --user enable opencode-free-bridge-relay.service >/dev/null 2>&1 || true
  systemctl --user restart opencode-free-bridge-relay.service
  info "$RELAY_URLS_COUNT relay aktif dicadangkan untuk tingkat 3"
else
  info "tidak ada relay di 9Router — tingkat 3 dilewati."
fi

# ------------------------------------------------ tingkat 1: IP sendiri -----
step "Tingkat 1 — IP sendiri"
bash "$HERE/fix-systemd.sh" >/dev/null
info "bridge utama :20129 keluar langsung (unit ditulis ulang tanpa proxy)"

# ------------------------------------------------------- daftarkan tingkat ---
step "Mendaftarkan tingkat ke 9Router"
if [[ -n "$TUNNEL_HOST" ]]; then
  NAME=ssh PROXY_URL="http://127.0.0.1:$PROXY_PORT" BRIDGE_PORT="$TIER2_PORT" PRIORITY=2 \
    bash "$HERE/add-egress-bridge.sh"
fi
if [[ "$RELAY_URLS_COUNT" -gt 0 ]]; then
  NAME=relay SHIM_PORT="$SHIM_PORT" BRIDGE_PORT="$TIER3_PORT" PRIORITY=3 \
    bash "$HERE/add-egress-bridge.sh"
fi

# ------------------------------------------ prioritas tingkat 1 + strategi ---
step "Menyetel urutan (priority) dan strategi fill-first"
"$RUNTIME" "$HERE/set-chain-strategy.js"

info "merestart 9Router agar perubahan terbaca..."
NINE_ROUTER_CLI="${NINE_ROUTER_CLI:-$HOME/.bun/install/global/node_modules/9router/cli.js}"
NINE_ROUTER_NODE="${NINE_ROUTER_NODE:-$(command -v node)}"
if [[ -f "$NINE_ROUTER_CLI" ]]; then
  pkill -f "[9]router/cli.js" 2>/dev/null || true
  sleep 2
  DISPLAY="${DISPLAY:-:0}" XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}" \
    setsid "$NINE_ROUTER_NODE" "$NINE_ROUTER_CLI" --tray --skip-update -p 20128 >/dev/null 2>&1 &
  sleep 3
  ss -ltn 2>/dev/null | grep -q ':20128 ' && info "9Router aktif kembali" || info "9Router belum mendengarkan :20128 — cek manual"
else
  info "9Router CLI tidak ditemukan di $NINE_ROUTER_CLI — restart manual bila perlu."
fi

echo
echo "Selesai. Urutan yang dipakai:"
"$RUNTIME" "$HERE/set-chain-strategy.js" show
echo
echo "Cek: curl -s http://127.0.0.1:20128/v1/chat/completions \\"
echo "  -H 'Authorization: Bearer <API_KEY>' -H 'Content-Type: application/json' \\"
echo "  -d '{\"model\":\"zen/big-pickle\",\"messages\":[{\"role\":\"user\",\"content\":\"Say OK\"}]}'"
