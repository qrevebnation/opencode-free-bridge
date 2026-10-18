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
IP 9Router. Upstream membedakan dua penolakan: `429 FreeUsageLimitError` berarti
transport lolos dan tinggal kuota, sedangkan `403 FreeTierError` berarti jaringan
itu sendiri yang ditolak (mis. egress datacenter).

### Rantai bertingkat otomatis (IP sendiri -> SSH -> relay)

Kalau ingin semuanya jalan sendiri tanpa memilih manual:

```bash
TUNNEL_HOST=host-ssh bash scripts/setup-chain.sh
```

| Tingkat | Egress | Bridge | Connection |
| --- | --- | --- | --- |
| 1 | IP sendiri (langsung) | `:20129` | `bridge-local` (priority 1) |
| 2 | SSH ke `host-ssh` (alias SSH di `~/.ssh/config`) | `:20131` | `ssh` (priority 2) |
| 3 | relay 9Router | `:20133` | `relay` (priority 3) |

9Router memakai strategi **`fill-first`**: pakai tingkat berprioritas terkecil
selama bisa; begitu upstream membalas `429`/`403`, connection itu dikunci
sementara dan request berikutnya otomatis pindah ke tingkat berikutnya.

```bash
node scripts/set-chain-strategy.js show    # urutan + priority
sqlite3 ~/.9router/db/data.sqlite \
  "SELECT timestamp, model, connectionId FROM usageHistory ORDER BY id DESC LIMIT 3;"
```

Bongkar tingkat 2 & 3 (bridge utama tetap ada): `bash scripts/setup-chain.sh --delete`

### Cara individual

Kalau tidak mau rantai otomatis, tiap jalur bisa dipasang sendiri:

### 1. Tunnel ke host lain (disarankan)

Pindahkan egress bridge ke jaringan host lain lewat SSH — **tanpa memasang apa pun
di host itu**. TLS bridge tetap end-to-end (Bun), jadi gate lolos; hanya IP-nya yang
berpindah, dan kuota per-IP host itu yang dipakai.

```bash
TUNNEL_HOST=host-ssh bash scripts/setup-all.sh
# atau hanya pasang tunnel-nya:
TUNNEL_HOST=host-ssh bash scripts/setup-tunnel.sh
```

Alurnya:

```
bridge :20129 ──HTTPS_PROXY──▶ connect-proxy :1085 ──SOCKS5──▶ ssh -D :1080 ──▶ internet
```

Script memasang tiga service systemd: tunnel SSH, proxy CONNECT lokal, dan bridge
dengan `HTTPS_PROXY`. Verifikasi:

```bash
curl -s -x http://127.0.0.1:1085 https://api.ipify.org   # harus IP host tujuan
systemctl --user status opencode-free-bridge-tunnel opencode-free-bridge
```

Catatan: host tujuan harus di jaringan dengan **IP publik berbeda**. Mesin lain di
rumahmu yang satu router tidak menambah kuota sama sekali.

**Menambah jalur lagi (hotspot HP, host SSH lain).** Tiap jalur = satu instance
bridge dengan proxy sendiri, lalu didaftarkan sebagai connection `zen` terpisah.
9Router otomatis round-robin dan failover antar jalur.

Hotspot HP paling mudah karena tidak perlu SSH: pasang app proxy SOCKS5 di HP
(mis. Every Proxy / SocksDroid), aktifkan, lalu:

```bash
NAME=seluler SOCKS=192.168.42.10:1080 bash scripts/add-egress-bridge.sh
```

Script itu memilih port bebas (bridge `20131`, proxy `1086`, …), memasang dua
service systemd, memverifikasi IP egress berubah, dan mendaftarkannya ke 9Router
sebagai connection `seluler`.

```bash
NAME=seluler bash scripts/add-egress-bridge.sh --delete   # hapus jalur
```

Yang **tidak** menolong: VPS, Cloudflare, Deno, Netlify — semuanya egress
datacenter dan ditolak gate dengan `403`. Yang menolong hanya IP ISP/seluler
(rumah, ISP lain, kafe, hotspot HP).

### 2. Multiple hosts (kalau punya mesin sendiri)

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

### 3. Rotasi relay (paling rapuh — hanya menolong kadang-kadang)

Relay (Vercel/Cloudflare/Deno/Netlify) **memutus TLS di sisi edge**, sehingga
fingerprint Bun hilang dan egress-nya datang dari datacenter. Gate upstream sering
menolaknya dengan `403 FreeTierError` — sudah terukur di sini: tiga relay sekaligus
ditolak, sementara IP rumah hanya kena `429`. Jadi pakai ini hanya kalau opsi 1 dan 2
tidak mungkin; kalau tetap mau, berikut caranya.

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
→ deploy pool baru. Setiap deploy menghasilkan satu URL relay.

Pilihan platform di 9Router (semuanya memakai kontrak yang sama — forwarder
`x-relay-target` / `x-relay-path`):

| Platform | Yang dibutuhkan | Catatan |
| --- | --- | --- |
| **Vercel** | token Vercel | Sering minta verifikasi nomor telepon saat daftar |
| **Cloudflare** | Account ID + API Token | Akun CF cukup email, tanpa nomor telepon. Workers gratis 100k request/hari |
| **Deno Deploy** | token Deno | Login via GitHub |
| **Netlify** | token Netlify | — |

**Deploy relay Cloudflare tanpa lewat 9Router** (mis. kalau UI-nya rewel):

```bash
cd workers
npx wrangler login     # sekali saja
npx wrangler deploy    # menghasilkan https://opencode-relay.<subdomain>.workers.dev
```

Lalu daftarkan URL itu ke rotasi:

```bash
RELAY_URLS="https://opencode-relay.<subdomain>.workers.dev,https://relay-lain.vercel.app" \
  bash scripts/setup-relay.sh
```

Untuk beberapa IP, ubah `name` di `workers/wrangler.toml` (mis. `opencode-relay-2`)
dan deploy lagi — tiap Worker menghasilkan endpoint sendiri.

Catatan: relay Cloudflare/edge memakai IP yang dibagi banyak pengguna, jadi kalau
opencode menolak IP itu, shim akan menandainya cooldown lalu pindah ke relay lain.
Uji dulu satu relay sebelum dipakai massal:

```bash
curl -s -o /dev/null -w '%{http_code}\n' -X POST "https://relay-baru.workers.dev/" \
  -H "x-relay-target: https://opencode.ai" -H "x-relay-path: /inference/v1/models"
```

Lihat daftar relay 9Router:

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

**Pengecekan berkala.** Status relay naik-turun: hari ini pernah tiga relay `403`
sekaligus, lalu beberapa jam kemudian ketiganya `200` lagi. Untuk memantaunya tanpa
menebak, pasang timer yang mem-probe lewat rantai sungguhan (bridge → shim → relay),
bukan sekadar `GET /models` — endpoint itu tidak melewati gate sehingga bisa `200`
padahal chat-nya `403`.

```bash
bash scripts/setup-relay-health.sh            # cek tiap 30 menit
systemctl --user start opencode-free-bridge-relay-health.service   # jalankan sekarang
tail -f ~/.local/state/opencode-free-bridge/relay-health.log       # lihat hasil
bash scripts/setup-relay-health.sh --delete   # matikan
```

Contoh keluaran `bash scripts/check-relays.sh`:

```
RELAY                                          STATUS   ARTI
relay-munb2b1k-...vercel.app                   200      sehat — bisa dipakai
vercel-relay2-...vercel.app                    403      ditolak gate (IP datacenter)
vercel-qnyoy-...vercel.app                     429      kuota IP relay habis
```

Interpretasi: `200` sehat, `403` jaringannya ditolak, `429` kuota IP itu habis.
Kalau ada `200`, `relay-shim.js` akan memakainya lebih dulu.

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
| `scripts/setup-tunnel.sh` | Pindahkan egress lewat SSH host lain (tanpa pasang apa pun di sana) |
| `scripts/add-egress-bridge.sh` | Tambah/hapus satu jalur egress (bridge + proxy + daftar 9Router) |
| `scripts/setup-chain.sh` | Rantai otomatis: IP sendiri -> SSH -> relay (prioritas + failover) |
| `scripts/set-chain-strategy.js` | Setel priority tingkat 1 dan strategi `fill-first` 9Router |
| `scripts/check-relays.sh` | Probe akurat: apakah relay masih bisa melayani chat (bukan cuma hidup) |
| `scripts/setup-relay-health.sh` | Pasang timer pengecekan relay berkala |
| `scripts/connect-proxy.js` | Proxy CONNECT lokal → SOCKS5, dipakai oleh `setup-tunnel.sh` |
| `scripts/relay-shim.js` | Rotasi + failover relay (eksperimental) |
| `scripts/setup-relay.sh` | Pasang relay shim sebagai service |
| `workers/relay.js` | Relay untuk Cloudflare Workers (deploy mandiri, tanpa 9Router) |
| `DETAIL.md` | Penjelasan teknis, cara kerja, troubleshooting |

## Lisensi

Mengikuti upstream: MIT (lihat [LICENSE](./LICENSE)).
