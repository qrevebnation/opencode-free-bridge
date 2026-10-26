# Setup: bridge + 9Router (fork)

Fork dari [azrinaldi/opencode-free-bridge](https://github.com/azrinaldi/opencode-free-bridge),
mengikuti upstream **2.3.1**.

> **Baca dulu soal free tier.** Sejak akhir Oktober 2026 gateway menolak request
> non-klien dengan pesan
> `429 FreeUsageLimitError: Free usage limit reached. Free models work in OpenCode (https://opencode.ai); subscribe to OpenCode Go`.
> Pesan itu muncul di **semua** jalur egress (IP rumah, SSH, relay) walau katalog
> model tetap `200`. Untuk pemakaian serius, siapkan `OpenCode Go` atau provider
> lain di 9Router. Dokumen ini tetap berlaku untuk pemasangan, egress pool, dan
> integrasi 9Router.

Dokumentasi bridge: [README.md](./README.md) · catatan teknis: [DETAIL.md](./DETAIL.md).

---

## Quick start

```bash
git clone https://github.com/qrevebnation/opencode-free-bridge.git
cd opencode-free-bridge
bash scripts/setup-all.sh
```

Yang dikerjakan: install/upgrade bridge lewat installer upstream (memasang Bun,
menulis unit systemd, cek `/health` + fingerprint TLS), memastikan runtime Bun,
mendaftarkan provider `zen` ke 9Router, lalu verifikasi.

Butuh **Bun** — gate upstream menolak Node (`403 FreeTierError` karena TLS
`ClientHello` berbeda).

## Cara pakai

| Setting  | Nilai                        |
| -------- | ---------------------------- |
| Base URL | `http://127.0.0.1:20128/v1`  |
| API key  | API key 9Router kamu         |
| Model    | `zen/<id>`, mis. `zen/big-pickle` |

```bash
curl -s http://127.0.0.1:20129/v1/models
curl -s http://127.0.0.1:20129/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"big-pickle","messages":[{"role":"user","content":"Say OK"}]}'
```

## Egress pool (fitur native 2.3.x)

Kuota free tier dihitung **per IP egress**, bukan per akun. Sejak 2.3.x bridge
punya pool egress sendiri: satu proses, banyak IP, tiap entry punya health
sendiri — jadi tidak perlu lagi beberapa instance bridge.

**Cara 1 — panel.** Buka `http://127.0.0.1:20129/` lalu isi bagian **Pool egress**,
satu entry per baris:

```
med1=http://pool:token@127.0.0.1:20251
med2=http://pool:token@127.0.0.1:20252
direct
```

**Cara 2 — environment** (lebih cocok untuk service/systemd):

```ini
Environment=UPSTREAM_PROXY_POOL=med1=http://a:1,med2=http://b:2,direct
Environment=UPSTREAM_PROXY_STRATEGY=failover
```

- **Bentuk entry:** URL, atau `{id,label,url,weight,enabled}`, atau `direct`
  (IP mesin ini ikut berputar, bukan cuma cadangan).
- **Strategi:** `round-robin` (default), `failover` (sticky di entry sehat
  pertama — menjaga prompt cache upstream di satu IP), `random` (berbobot).
- **Cooldown:** penolakan dicatat **per entry**, backoff berlipat dari 120 dtk
  sampai 30 menit; `429` dapat 4× jendela dasar; sukses mereset.
- **Selalu mengirim:** kalau semua entry sedang cooldown, yang paling cepat
  pulih tetap dipakai — lebih baik daripada bridge mati.
- **Failover penolakan gate:** entry yang ditolak dibuang dan request diulang
  lewat entry lain dalam request yang sama.
- **Health lintas restart:** disimpan di `pool-health.json` (mode 0600), kunci
  berupa hash identitas egress (bukan URL), jadi tidak menduplikasi kredensial.

Cek status:

```bash
curl -s http://127.0.0.1:20129/health | grep -o '"egress":{[^}]*'
```

### Menjadikan host lain sebagai anggota pool

Di host tersebut (mis. kantor), jalankan proxy bawaan:

```bash
PORT=8888 EGRESS_PROXY_TOKEN=rahasia bun ~/.opencode-free-bridge/egress-proxy.js
```

Lalu dari mesin utama, buka lewat SSH (proxy tetap tidak terekspos, autentikasi
dibawa tunnel):

```bash
ssh -L 127.0.0.1:20251:127.0.0.1:8888 host-ssh
```

Daftarkan ke pool:

```
kantor=http://pool:rahasia@127.0.0.1:20251
```

Entry `direct` bisa ditambahkan supaya IP mesin ini ikut ambil bagian.

## Mendaftarkan ke 9Router

```bash
node scripts/add-9router-provider.js                 # buat provider zen + connection
node scripts/add-bridge-connection.js --url http://127.0.0.1:20130/v1 --name vps-1
node scripts/add-bridge-connection.js --name vps-1 --delete
```

Catatan: proxy pool **9Router** tidak boleh dipasang pada connection yang
menunjuk `127.0.0.1` — relay-nya di cloud tidak bisa menjangkau localhost dan
hasilnya `FUNCTION_INVOCATION_FAILED`. Script di atas mengosongkannya otomatis.

## Status & troubleshooting

```bash
journalctl --user -u opencode-free-bridge -n 50 --no-pager
curl -s http://127.0.0.1:20129/health | head -c 400
bun ~/.opencode-free-bridge/verify.js --quick
```

| Gejala | Arti |
| --- | --- |
| `429 FreeUsageLimitError` "Free models work in OpenCode" | Gateway menolak klien non-resmi / kuota habis. Ganti egress tidak menolong jika ini kebijakan |
| `429 FreeUsageLimitError` biasa | **Dua sebab**: kuota habis, atau system prompt tanpa blok `<env>` berisi `Working directory:`. Versi < 2.3.1 tidak mengirimnya — upgrade |
| `403 FreeTierError` + "abusive traffic" | Blokir IP-level; bridge tidak retry. Email `help@anoma.ly` dengan waktu + `x-opencode-log-id` |
| `403 FreeTierError` biasa | IP sedang cooldown free tier, atau bridge jalan di Node. Pastikan Bun, atau tunggu |
| `/health` `lastError: null` tapi 403 | IP cooldown; bridge menahan retry 30 dtk (`GATE_RETRY_COOLDOWN_MS`) agar penalti tidak diperpanjang |
| `bun: command not found` di SSH baru | `~/.bun/bin` tidak ada di PATH non-interaktif; pakai path absolut |
| `404 Model ... has been retired` | Model deprecated upstream; ambil daftar baru dari `/v1/models` |

`verify.js` exit code: `0` sehat · `2` transport lolos tapi IP ditolak (gate /
kuota) · `1` gagal nyata (bridge mati, Node, atau fingerprint TLS melenceng).

## Script di repo ini

Sebagian sudah **digantikan fitur native 2.3.x** — dipertahankan sebagai
lapisan lama / alat bantu.

| File | Status | Fungsi |
| ---- | ------ | ------ |
| `scripts/setup-all.sh` | aktif | Setup idempoten sekali jalan |
| `scripts/add-9router-provider.js` | aktif | Daftarkan provider `zen` ke 9Router + bersihkan proxy pool |
| `scripts/add-bridge-connection.js` | aktif | Tambah/hapus connection tambahan di 9Router |
| `scripts/fix-systemd.sh` | aktif | Tulis ulang unit systemd dengan runtime Bun |
| `scripts/check-relays.sh` | aktif | Probe relay lewat rantai sungguhan (bukan cuma `/models`) |
| `scripts/setup-relay-health.sh` | aktif | Timer systemd untuk probe relay berkala |
| `scripts/relay-shim.js` | **legacy** | Rotasi relay; digantikan egress pool native |
| `scripts/setup-relay.sh` | **legacy** | Pasang shim relay |
| `scripts/setup-chain.sh` | **legacy** | Rantai 3-tier (IP sendiri → SSH → relay); digantikan satu bridge + pool |
| `scripts/add-egress-bridge.sh` | **legacy** | Tambah instance bridge per jalur; digantikan entry pool |
| `scripts/connect-proxy.js` | **legacy** | SOCKS→CONNECT untuk SSH tunnel (masih berguna bila host hanya punya SOCKS) |
| `scripts/set-chain-strategy.js` | **legacy** | Set priority/fill-first di 9Router |
| `workers/relay.js` | **legacy** | Relay Cloudflare Workers |

## Lisensi

Mengikuti upstream: MIT (lihat [LICENSE](./LICENSE)).
