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

Limit dihitung per IP, jadi menambah mesin = menambah jatah. Tiap host didaftarkan
sebagai connection terpisah; 9Router otomatis round-robin + failover antar connection.

**Di mesin kedua** (VPS/host dengan IP publik berbeda):

```bash
curl -fsSL https://raw.githubusercontent.com/qrevebnation/opencode-free-bridge/main/install.sh | bash
```

Installer memasang Bun + bridge. Kalau mau sekaligus registrasi 9Router di host itu,
clone repo ini dan jalankan `bash scripts/setup-all.sh` (lewati kalau 9Router tidak
ada di sana).

**Di mesin utama**, buka port bridge host kedua lewat SSH:

```bash
ssh -N -L 127.0.0.1:20130:127.0.0.1:20129 user@remote-host
```

Biarkan perintah itu jalan. Supaya otomatis, jadikan service systemd (ganti
`user@remote-host`):

```ini
# ~/.config/systemd/user/bridge-tunnel-vps1.service
[Unit]
Description=SSH tunnel ke bridge VPS-1
After=network-online.target

[Service]
ExecStart=/usr/bin/ssh -N -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 -L 127.0.0.1:20130:127.0.0.1:20129 user@remote-host
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
```

```bash
systemctl --user daemon-reload && systemctl --user enable --now bridge-tunnel-vps1
```

**Daftarkan sebagai connection tambahan** di 9Router:

```bash
node scripts/add-bridge-connection.js --url http://127.0.0.1:20130/v1 --name vps-1
```

Script ini mencari provider node ber-prefix `zen` (jalankan `setup-all.sh` dulu kalau
belum ada), membuat connection baru, mengarahkan `baseUrl` ke tunnel, dan memastikan
proxy pool kosong. Ulangi untuk host lain (`--name vps-2`, port `20131`, …).

Cek dan bersihkan:

```bash
node scripts/add-bridge-connection.js --url http://127.0.0.1:20130/v1 --name vps-1   # cek daftar
node scripts/add-bridge-connection.js --name vps-1 --delete                          # hapus
```

Catatan:
- Host harus di **jaringan/IP publik berbeda**. Dua mesin di rumah yang sama berbagi
  IP → tidak ada gunanya.
- Semua connection memakai prefix `zen`, jadi model tetap `zen/<id>` — tidak perlu
  ubah konfigurasi klien.
- Restart 9Router kalau connection baru belum terbaca.
- Kalau ada `priority` berbeda, 9Router memakai yang lebih rendah lebih dulu sebagai
  urutan fallback.

### 2. Rotasi relay (eksperimental — satu mesin, tanpa host tambahan)

`relay-shim.js` meneruskan request bridge lewat relay proxy pool 9Router, sehingga
egress keluar dari IP relay:

```
bridge :20129 ──▶ relay-shim :20140 ──▶ relay (Vercel) ──▶ opencode.ai
```

**Cara mengaktifkan** (otomatis mendeteksi relay dari 9Router):

```bash
ENABLE_RELAY=1 bash scripts/setup-all.sh
```

**Cara menambah relay** supaya rotasinya makin lebar: buka 9Router → **Proxy Pools**
→ deploy pool baru (Vercel/Cloudflare/Deno). Setiap deploy menghasilkan satu URL relay.
Lihat daftarnya:

```bash
sqlite3 ~/.9router/db/data.sqlite \
  "SELECT json_extract(data,'\$.name'), json_extract(data,'\$.proxyUrl') FROM proxyPools WHERE isActive=1;"
```

**Cara memilih relay tertentu** (mis. hanya yang terbukti jalan):

```bash
RELAY_URLS="https://relay-a.vercel.app,https://relay-b.vercel.app" bash scripts/setup-relay.sh
```

**Cara memantau** rotasi/failover:

```bash
tail -f ~/.local/state/opencode-free-bridge/relay-shim.log
# baris "relay -> status" menunjukkan relay mana yang dipakai; 403/429 otomatis dilewati
```

**Cara mematikan** dan kembali keluar dari IP mesin ini:

```bash
systemctl --user disable --now opencode-free-bridge-relay
bash scripts/fix-systemd.sh
```

Kenapa eksperimental: relay hanya mengubah **IP egress**. Kalau IP relay itu sendiri
sedang kehabisan jatah, dia membalas `403 FreeTierError`/`429` dan request dilempar ke
relay berikutnya — jadi hasilnya bergantung pada berapa relay sehat yang kamu punya.
Limit **per model** (mis. satu model tertentu di-throttle) tidak terpengaruh rotasi
sama sekali.

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
| `scripts/add-bridge-connection.js` | Tambah/hapus connection tambahan (multi-host: VPS, tunnel, port lain) |
| `scripts/fix-systemd.sh` | Tulis ulang unit systemd dengan format yang diterima + runtime Bun |
| `scripts/relay-shim.js` | Rotasi + failover relay (eksperimental) |
| `scripts/setup-relay.sh` | Pasang relay shim sebagai service |
| `DETAIL.md` | Penjelasan teknis, cara kerja, troubleshooting |

## Lisensi

Mengikuti upstream: MIT (lihat [LICENSE](./LICENSE)).
