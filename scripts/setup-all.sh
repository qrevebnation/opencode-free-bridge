#!/usr/bin/env bash
# Setup sekali jalan: opencode-free-bridge (Bun) + service systemd + registrasi
# ke 9Router + verifikasi.
#
#   bash scripts/setup-all.sh
#
# Semua langkah idempoten — aman dijalankan berulang kali.
#
# Opsi env:
#   TUNNEL_HOST=host-ssh  # disarankan: pindahkan egress lewat jaringan host lain (SSH)
#   ENABLE_RELAY=1      # alternatif: rotasi relay (eksperimental, lihat SETUP.md)
#   RELAY_URLS="..."    # daftar relay; default auto-deteksi dari 9Router
#   PORT=20129          # port bridge
#   SHIM_PORT=20140     # port relay shim
#   SKIP_9ROUTER=1      # jangan sentuh 9Router
#   BRIDGE_DIR=...      # lokasi instalasi bridge

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BRIDGE_DIR="${BRIDGE_DIR:-$HOME/.opencode-free-bridge}"
PORT="${PORT:-20129}"
HOST="${HOST:-127.0.0.1}"
SHIM_PORT="${SHIM_PORT:-20140}"
NINE_ROUTER_DB="${NINE_ROUTER_DB:-$HOME/.9router/db/data.sqlite}"

step() { printf "\n\033[1m== %s\033[0m\n" "$1"; }
info() { printf "   %s\n" "$1"; }
warn() { printf "   \033[33m%s\033[0m\n" "$1"; }

# Bun diutamakan: gate free-tier upstream memeriksa TLS ClientHello dan menolak
# Node dengan 403 FreeTierError.
RUNTIME=""
for candidate in "$HOME/.bun/bin/bun" "$(command -v bun || true)" "$(command -v node || true)"; do
  if [[ -n "$candidate" && -x "$candidate" ]]; then RUNTIME="$candidate"; break; fi
done
[[ -n "$RUNTIME" ]] || {
  echo "Butuh Bun (disarankan) atau Node.js. Install Bun: curl -fsSL https://bun.sh/install | bash" >&2
  exit 1
}
if [[ "$(basename "$RUNTIME")" != "bun" ]]; then
  warn "Bun tidak ditemukan; memakai $(basename "$RUNTIME"). Upstream menolak Node dengan 403 FreeTierError."
fi

# ---------------------------------------------------------------------------
step "1/5  Install bridge"
# ---------------------------------------------------------------------------
if [[ -f "$BRIDGE_DIR/server.js" ]]; then
  info "Sudah ada di $BRIDGE_DIR ($(grep -m1 '"version"' "$BRIDGE_DIR/package.json" 2>/dev/null | tr -d ' ",' | cut -d: -f2 || echo '?'))"
elif [[ -f "$HERE/../install.sh" ]]; then
  info "Install dari installer repo ini..."
  bash "$HERE/../install.sh"
else
  info "Mengunduh installer resmi opencode-free-bridge..."
  curl -fsSL https://raw.githubusercontent.com/azrinaldi/opencode-free-bridge/main/install.sh | bash
fi

# ---------------------------------------------------------------------------
step "2/5  Pastikan service systemd memakai runtime yang benar"
# ---------------------------------------------------------------------------
BRIDGE_DIR="$BRIDGE_DIR" PORT="$PORT" HOST="$HOST" RUNTIME="$RUNTIME" bash "$HERE/fix-systemd.sh"

# ---------------------------------------------------------------------------
step "3/5  Kuota per-IP: tunnel host lain (disarankan) atau relay"
# ---------------------------------------------------------------------------
if [[ -n "${TUNNEL_HOST:-}" ]]; then
  info "Memakai tunnel ke: $TUNNEL_HOST (egress dari jaringan host itu, TLS Bun tetap utuh)"
  TUNNEL_HOST="$TUNNEL_HOST" PORT="$PORT" HOST="$HOST" BRIDGE_DIR="$BRIDGE_DIR" RUNTIME="$RUNTIME" \
    bash "$HERE/setup-tunnel.sh"
elif [[ -n "${ENABLE_RELAY:-}" || -n "${RELAY_URLS:-}" ]]; then
  if [[ -z "${RELAY_URLS:-}" && -f "$NINE_ROUTER_DB" ]] && command -v sqlite3 >/dev/null; then
    RELAY_URLS="$(sqlite3 "$NINE_ROUTER_DB" \
      "SELECT group_concat(json_extract(data,'\$.proxyUrl')) FROM proxyPools WHERE isActive=1 AND json_extract(data,'\$.proxyUrl') IS NOT NULL;" \
      2>/dev/null || true)"
    [[ -n "$RELAY_URLS" ]] && info "Relay terdeteksi dari 9Router: $RELAY_URLS"
  fi
  if [[ -n "${RELAY_URLS:-}" ]]; then
    warn "Relay memutus TLS di sisi edge; gate upstream sering menolaknya dengan 403."
    warn "Untuk hasil stabil pakai: TUNNEL_HOST=<host-ssh> bash scripts/setup-all.sh"
    RELAY_URLS="$RELAY_URLS" SHIM_PORT="$SHIM_PORT" PORT="$PORT" HOST="$HOST" \
      BRIDGE_DIR="$BRIDGE_DIR" RUNTIME="$RUNTIME" bash "$HERE/setup-relay.sh"
  else
    warn "Tidak ada relay ditemukan — dilewati."
  fi
else
  info "Dilewati. Bridge keluar langsung dari IP mesin ini."
  info "Kuota per-IP bisa ditambah lewat tunnel ke host lain (IP publik berbeda):"
  info "  TUNNEL_HOST=<host-ssh> bash scripts/setup-all.sh"
fi

# ---------------------------------------------------------------------------
step "4/5  Daftarkan ke 9Router"
# ---------------------------------------------------------------------------
if [[ -n "${SKIP_9ROUTER:-}" ]]; then
  info "Dilewati (SKIP_9ROUTER=1)"
elif [[ -f "$NINE_ROUTER_DB" ]]; then
  "$RUNTIME" "$HERE/add-9router-provider.js" || warn "Registrasi 9Router gagal — cek manual di UI 9Router."
  info "Catatan: kalau 9Router baru mengubah koneksi, restart 9Router agar terbaca."
else
  warn "9Router tidak terdeteksi (~/.9router tidak ada) — lewati."
fi

# ---------------------------------------------------------------------------
step "5/5  Verifikasi"
# ---------------------------------------------------------------------------
MODELS="$(curl -s --max-time 30 "http://$HOST:$PORT/v1/models" || true)"
COUNT="$(printf '%s' "$MODELS" | "$RUNTIME" -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{console.log((JSON.parse(s).data||[]).length)}catch{console.log(0)}})' 2>/dev/null || echo 0)"
info "Model terdeteksi: $COUNT"

if [[ "$COUNT" -gt 0 ]]; then
  MODEL_ID="$(printf '%s' "$MODELS" | "$RUNTIME" -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{console.log(JSON.parse(s).data[0].id)}catch{}})')"
  REPLY="$(curl -s --max-time 60 "http://$HOST:$PORT/v1/chat/completions" \
    -H 'Content-Type: application/json' \
    -d "{\"model\":\"$MODEL_ID\",\"messages\":[{\"role\":\"user\",\"content\":\"Say OK\"}]}" || true)"
  if printf '%s' "$REPLY" | grep -q '"choices"'; then
    info "Tes chat via bridge: OK ($MODEL_ID)"
  else
    warn "Tes chat gagal: $(printf '%s' "$REPLY" | head -c 160)"
    warn "Kalau ini 403 FreeTierError: IP ini sedang di-throttle upstream, atau bridge tidak jalan di Bun."
  fi
else
  warn "Belum ada model — tunggu ±1 menit lalu cek: curl -s http://$HOST:$PORT/v1/models"
fi

echo
echo "Selesai."
echo "  Bridge  : http://$HOST:$PORT/v1  (runtime $(basename "$RUNTIME"))"
echo "  Model   : zen/<id> lewat 9Router (http://127.0.0.1:20128/v1)"
echo "  Verifikasi lengkap: $RUNTIME $BRIDGE_DIR/verify.js"
echo "  Cek     : systemctl --user status opencode-free-bridge"
