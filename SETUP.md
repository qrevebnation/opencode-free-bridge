# Setup: bridge + 9Router (fork)

Fork dari [azrinaldi/opencode-free-bridge](https://github.com/azrinaldi/opencode-free-bridge),
mengikuti upstream **v2.3.11**, dengan tambahan otomasi:

- **Registrasi 9Router** otomatis (custom provider prefix `zen`).
- **Pembersih proxy pool** — proxy pool di connection localhost membuat error
  `FUNCTION_INVOCATION_FAILED`.
- **Rotasi relay** (opsional/eksperimental) untuk menyebar limit per-IP tanpa
  mesin tambahan.

Dokumentasi bridge-nya sendiri ada di [README.md](./README.md).
Penjelasan teknis & troubleshooting menyeluruh: [DETAIL.md](./DETAIL.md).

> Butuh **Bun**. Upstream menolak request dari Node dengan `403 FreeTierError`
> karena gate-nya memeriksa TLS `ClientHello` (Bun identik dengan CLI, Node tidak).
> Installer upstream akan memasang Bun kalau belum ada.

---

## Quick start (satu perintah)

```bash
git clone https://github.com/qrevebnation/opencode-free-bridge.git
cd opencode-free-bridge
bash scripts/setup-all.sh
```

Yang dikerjakan:

1. Install/upgrade bridge lewat installer upstream (memasang Bun, menulis unit
   systemd, cek `/health`)
2. Pastikan unit systemd memakai runtime Bun
3. Registrasi ke 9Router sebagai provider `zen`, sekaligus bersihkan proxy pool
4. Verifikasi: jumlah model + tes chat satu model

Relay **tidak** aktif secara default — lihat "Soal rate limit" di bawah.
Mengaktifkannya: `ENABLE_RELAY=1 bash scripts/setup-all.sh`.

Semua langkah idempoten — aman dijalankan berulang.

## Cara pakai

Model tersedia sebagai `zen/<id>`:

| Setting  | Nilai                        |
| -------- | ---------------------------- |
| Base URL | `http://127.0.0.1:20128/v1`  |
| API key  | API key 9Router kamu         |
| Model    | `zen/big-pickle`, `zen/glm-5.3-flash-free`, … |

Tes langsung ke bridge:

```bash
curl -s http://127.0.0.1:20129/v1/models
curl -s http://127.0.0.1:20129/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"big-pickle","messages":[{"role":"user","content":"Say OK"}]}'
```

Verifikasi lengkap (semua model):

```bash
bun ~/.opencode-free-bridge/verify.js
```

## Soal rate limit

Limit free-tier OpenCode dihitung **per IP mesin yang menjalankan bridge** — bukan
IP 9Router. Ada dua cara menyebarnya:

### 1. Multiple hosts (disarankan — jalur stabil)

Jalankan bridge di beberapa mesin dengan IP publik berbeda, daftarkan masing-masing
sebagai connection terpisah di 9Router (prefix sama, `zen`). 9Router otomatis
round-robin dan failover antar connection.

```bash
# di mesin lain
git clone https://github.com/qrevebnation/opencode-free-bridge.git
cd opencode-free-bridge && bash scripts/setup-all.sh

# dari laptop, buka port bridge mesin itu
ssh -N -L 127.0.0.1:20130:127.0.0.1:20129 user@remote-host
```

Lalu daftarkan `http://127.0.0.1:20130/v1` sebagai connection tambahan di UI 9Router.

Catatan: host harus di **jaringan/IP publik berbeda**. Dua mesin di rumah yang sama
berbagi IP → tidak ada gunanya.

### 2. Rotasi relay (eksperimental — satu mesin)

`relay-shim.js` meneruskan request bridge lewat relay proxy pool 9Router, sehingga
egress keluar dari IP relay:

```
bridge :20129 ──▶ relay-shim :20140 ──▶ relay (Vercel) ──▶ opencode.ai
```

```bash
ENABLE_RELAY=1 bash scripts/setup-all.sh
# atau pilih relay sendiri:
RELAY_URLS="https://relay-a.vercel.app,https://relay-b.vercel.app" bash scripts/setup-relay.sh
```

Kenapa eksperimental: gate upstream memeriksa TLS `ClientHello`, sedangkan relay
Vercel/edge tidak menjalankan Bun, sehingga sebagian relay ditolak
`403 FreeTierError`. Rotasi + failover menyembunyikan itu (relay yang ditolak
otomatis dilewati), tapi hasil akhirnya bergantung pada relay mana yang lolos.
Jalur multi-host di atas tidak punya masalah ini.

## Kalau bermasalah

```bash
journalctl --user -u opencode-free-bridge -n 50 --no-pager
systemctl --user status opencode-free-bridge
```

| Gejala | Sebab & solusi |
| ------ | -------------- |
| `403 FreeTierError` | (a) Bridge tidak jalan di Bun — cek `/health`; (b) IP sedang di-throttle upstream (CLI resmi pun dapat 403 yang sama). `verify.js` keluar dengan kode `2` untuk kasus ini |
| `ECONNREFUSED 127.0.0.1:20129` | Bridge mati → `systemctl --user restart opencode-free-bridge` |
| `FUNCTION_INVOCATION_FAILED` lewat 9Router | Proxy pool terpasang di connection bridge localhost → `node scripts/add-9router-provider.js`, lalu restart 9Router |
| Sebagian model `FAIL` / timeout | Model itu memang bermasalah di upstream (mis. `nemotron-3.5-lightning-free`) |
| Service gagal start | `WorkingDirectory` bukan path absolut / runtime salah → `bash scripts/fix-systemd.sh` |
| `Bun is required but not found` | `curl -fsSL https://bun.sh/install \| bash`, lalu buka shell baru |

## Isi tambahan di fork ini

| File | Fungsi |
| ---- | ------ |
| `scripts/setup-all.sh` | **Mulai dari sini** — setup idempoten sekali jalan |
| `scripts/add-9router-provider.js` | Daftarkan bridge ke 9Router (prefix `zen`), bersihkan proxy pool |
| `scripts/fix-systemd.sh` | Tulis ulang unit systemd dengan format yang diterima + runtime Bun |
| `scripts/relay-shim.js` | Rotasi + failover relay (eksperimental) |
| `scripts/setup-relay.sh` | Pasang relay shim sebagai service |
| `DETAIL.md` | Penjelasan teknis, cara kerja, troubleshooting |

## Lisensi

Mengikuti upstream: MIT (lihat [LICENSE](./LICENSE)).
