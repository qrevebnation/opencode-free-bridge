#!/usr/bin/env bash
# Cek berkala apakah relay masih bisa melayani request bergerbang (chat), bukan
# sekadar hidup. Penting: GET /inference/v1/models lewat relay tetap 200 walau
# chat-nya ditolak 403, karena endpoint models tidak melewati gate.
#
# Karena itu probe ini menjalankan rantai sungguhan:
#   bridge sementara -> relay-shim (satu relay) -> opencode.ai
# sehingga status yang tercatat adalah jawaban upstream atas request ber-fingerprint.
#
# Pemakaian:
#   bash scripts/check-relays.sh                 # semua relay aktif dari 9Router
#   RELAY_URLS="https://a.vercel.app" bash scripts/check-relays.sh
#
# Log: ~/.local/state/opencode-free-bridge/relay-health.log (satu baris per relay)

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BRIDGE_DIR="${BRIDGE_DIR:-$HOME/.opencode-free-bridge}"
NINE_ROUTER_DB="${NINE_ROUTER_DB:-$HOME/.9router/db/data.sqlite}"
STATE_DIR="$HOME/.local/state/opencode-free-bridge"
LOG="$STATE_DIR/relay-health.log"
SHIM_PORT="${SHIM_PORT:-20141}"
BRIDGE_PORT="${BRIDGE_PORT:-20132}"
MODEL="${MODEL:-big-pickle}"
WAIT_SECS="${WAIT_SECS:-15}"

mkdir -p "$STATE_DIR"
[[ -f "$BRIDGE_DIR/server.js" ]] || { echo "server.js tidak ditemukan di $BRIDGE_DIR" >&2; exit 1; }

RUNTIME=""
for candidate in "$HOME/.bun/bin/bun" "$(command -v bun || true)" "$(command -v node || true)"; do
  if [[ -n "$candidate" && -x "$candidate" ]]; then RUNTIME="$candidate"; break; fi
done
[[ -n "$RUNTIME" ]] || { echo "bun/node tidak ditemukan." >&2; exit 1; }

if [[ -z "${RELAY_URLS:-}" ]]; then
  if [[ -f "$NINE_ROUTER_DB" ]] && command -v sqlite3 >/dev/null; then
    RELAY_URLS="$(sqlite3 "$NINE_ROUTER_DB" \
      "SELECT group_concat(json_extract(data,'\$.proxyUrl')) FROM proxyPools WHERE isActive=1 AND json_extract(data,'\$.proxyUrl') IS NOT NULL;" \
      2>/dev/null || true)"
  fi
fi
[[ -n "${RELAY_URLS:-}" ]] || { echo "Tidak ada relay. Set RELAY_URLS atau tambah proxy pool di 9Router." >&2; exit 1; }

PIDS=()
cleanup() {
  for p in "${PIDS[@]:-}"; do kill "$p" 2>/dev/null || true; done
}
trap cleanup EXIT

probe_one() {
  local relay="$1" log="$2"
  rm -f "$log"

  PORT="$SHIM_PORT" RELAY_URLS="$relay" RELAY_FALLBACK_DIRECT=0 DEBUG_LOG="$log" \
    "$RUNTIME" "$HERE/relay-shim.js" >/dev/null 2>&1 &
  local shim_pid=$!
  PIDS+=("$shim_pid")

  PORT="$BRIDGE_PORT" HOST=127.0.0.1 \
    OPENCODE_CHAT_URL="http://127.0.0.1:$SHIM_PORT/inference/v1/chat/completions" \
    OPENCODE_RESPONSES_URL="http://127.0.0.1:$SHIM_PORT/inference/v1/responses" \
    OPENCODE_MODELS_URL="http://127.0.0.1:$SHIM_PORT/inference/v1/models" \
    "$RUNTIME" "$BRIDGE_DIR/server.js" >/dev/null 2>&1 &
  local bridge_pid=$!
  PIDS+=("$bridge_pid")

  for _ in $(seq 1 "$WAIT_SECS"); do
    curl -s -o /dev/null --max-time 2 "http://127.0.0.1:$SHIM_PORT/inference/v1/models" && break
    sleep 1
  done

  curl -s -o /dev/null --max-time 60 -X POST "http://127.0.0.1:$BRIDGE_PORT/v1/chat/completions" \
    -H 'Content-Type: application/json' \
    -d "{\"model\":\"$MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"Say OK\"}]}" || true

  kill "$shim_pid" "$bridge_pid" 2>/dev/null || true
  sleep 0.3

  # status relay diambil dari log shim (jawaban upstream atas request ber-fingerprint)
  if [[ -s "$log" ]]; then
    "$RUNTIME" -e '
      const fs=require("fs");
      const lines=fs.readFileSync(process.argv[1],"utf8").trim().split("\n");
      for(const l of lines){
        try{const r=JSON.parse(l); if(r.status!==undefined){console.log(r.status); break;}}catch{}
      }
    ' "$log" 2>/dev/null || true
  fi
}

echo "Probe relay (model $MODEL) — $(date -Is)"
printf "  %-46s %-8s %s\n" "RELAY" "STATUS" "ARTI"

OK=0; BAD=0
for url in ${RELAY_URLS//,/ }; do
  [[ -z "$url" ]] && continue
  host="$(echo "$url" | sed -E 's#https?://##' | cut -d/ -f1)"
  log="/tmp/relay-health-$host.log"
  status="$(probe_one "$url" "$log" | tail -1)"

  case "$status" in
    200) arti="sehat — bisa dipakai"; OK=$((OK+1)) ;;
    429) arti="kuota IP relay habis"; BAD=$((BAD+1)) ;;
    403) arti="ditolak gate (IP datacenter)"; BAD=$((BAD+1)) ;;
    "")  arti="tidak menjawab / tidak terjangkau" ;;
    5*)  arti="error upstream"; BAD=$((BAD+1)) ;;
    *)   arti="?" ;;
  esac

  printf "  %-46s %-8s %s\n" "${host:0:46}" "${status:--}" "$arti"
  echo "$(date -Is) relay=$host status=${status:-none}" >> "$LOG"
done

echo
echo "Ringkasan: $OK sehat, $BAD bermasalah. Log: $LOG"
[[ "$OK" -gt 0 ]] && echo "Ada relay sehat — shim akan memakainya lebih dulu (relay yang cooldown dilewati)."
