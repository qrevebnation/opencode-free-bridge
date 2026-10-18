# Detail teknis

Catatan mendalam untuk fork ini. Untuk pemasangan cepat, lihat [SETUP.md](./SETUP.md);
dokumentasi bridge-nya sendiri ada di [README.md](./README.md) (punya upstream).

Fork ini mengikuti upstream **v2.3.11** (sebelumnya berbasis v1.5.3 — selisih 45 commit).

---

## 1. Kenapa butuh Bun

Gate free-tier OpenCode memeriksa **TLS `ClientHello`** dari koneksi yang masuk.
CLI resmi dikompilasi dengan Bun, jadi hanya Bun yang menyamai fingerprint-nya.

| Properti | OpenCode CLI | Bridge di Bun | Bridge di Node.js |
| --- | --- | --- | --- |
| Cipher suite TLS | 17 | 17 (identik) | 52 |
| Extension TLS | 12 | 12 (urutan identik) | 11 (urutan beda) |
| `Accept-Encoding` | `gzip, deflate, br, zstd` | identik | `gzip, deflate` |
| Hasil di gateway | `200` | `200` (6/6) | `403 FreeTierError` (0/6) |

Sumber: tabel di `README.md` upstream (diukur dari IP yang sama, header & payload sama).

Praktiknya di mesin ini:

- **v1.5.3 di Node** → tetap dapat `200`, tapi hasil verifikasi: 7 usable,
  1 rate-limited, 1 timeout. Jawaban sangat pendek (2 karakter).
- **v2.3.11 di Bun** → 8 usable, 0 gate-closed, 0 rate-limited, jawaban normal
  (31–82 karakter). `glm-5.3-flash-free` yang tadinya `BUSY` ikut jalan.

Jadi klaim "Node selalu 403" tidak mutlak, tapi Bun jelas lebih baik dan itu
yang didukung upstream.

## 2. Bug unit systemd (sudah diperbaiki upstream)

Installer v1.5.x menulis:

```ini
WorkingDirectory="/home/user/.opencode-free-bridge"
ExecStart="/path/to/node" "/home/user/.opencode-free-bridge/server.js"
```

`WorkingDirectory` dengan tanda kutip ditolak systemd (`path is not absolute` →
`bad unit file setting`), jadi service tidak pernah start. Tanda kutip pada
`ExecStart` sendiri legal (systemd memang mengizinkannya untuk argumen).

Upstream memperbaikinya di `0edfaea` ("write a systemd unit systemd accepts"),
jadi **fork ini tidak lagi menambal `install.sh`**. `scripts/fix-systemd.sh`
tetap disediakan sebagai perbaikan mandiri (mis. unit lama v1.5.x yang tersangkut)
dan untuk memastikan runtime yang dipakai adalah Bun.

## 3. Proxy pool 9Router tidak bisa dipakai untuk bridge localhost

Proxy pool = relay yang di-deploy ke Vercel/Cloudflare/Deno. Kalau dipasang pada
custom provider yang base URL-nya `127.0.0.1`, request dikirim ke relay di cloud
yang **tidak bisa menjangkau localhost** → `FUNCTION_INVOCATION_FAILED`.

Gejala: direct ke `127.0.0.1:20129` sukses, lewat 9Router selalu 500.

Cek:

```bash
sqlite3 ~/.9router/db/data.sqlite \
  "SELECT id, provider, json_extract(data,'\$.providerSpecificData.proxyPoolId')
   FROM providerConnections;"
```

`scripts/add-9router-provider.js` otomatis mengosongkan `proxyPoolId` pada
connection bridge. Koneksi di 9Router di-cache di memori — **restart 9Router**
setelah mengubahnya.

## 4. Rate limit: di mana sebarnya

Limit dihitung per IP **mesin yang menjalankan bridge**, bukan IP 9Router.

Upstream membedakan dua penolakan, dan bedanya penting:

| Respons | Arti |
| --- | --- |
| `429 FreeUsageLimitError` | Transport lolos, tinggal kuota IP itu yang habis |
| `403 FreeTierError` | Jaringan/transportnya sendiri yang ditolak |

Terukur di mesin ini, satu waktu:

```
IP rumah langsung : 429 FreeUsageLimitError   -> transport lolos, kuota habis
tiga relay (Vercel): 403 FreeTierError        -> jaringannya yang ditolak
GET /inference/v1/models lewat relay: 200     -> relay-nya sehat; yang ditolak khusus request gated
```

Karena itu urutan solusinya:

1. **Tunnel ke host lain** (paling praktis). `ssh -D` + `connect-proxy.js` +
   `HTTPS_PROXY` hanya memindahkan IP; TLS tetap dihasilkan Bun, jadi transport
   tetap lolos dan kuota IP host tujuan yang terpakai. Tidak perlu memasang apa pun
   di host tujuan, dan IP-nya bukan datacenter.
2. **Multiple hosts** — beberapa mesin dengan IP publik berbeda, tiap mesin satu
   connection `zen` di 9Router.
3. **Rotasi relay** — paling rapuh: relay memutus TLS di edge (Vercel/Cloudflare/
   Deno/Netlify semuanya datacenter), sehingga `403` sering muncul. Shim hanya
   menyembunyikannya lewat cooldown + failover.

Catatan penting: relay/edge dan tunnel sama-sama hanya mengubah **IP egress**. Limit
**per model** (mis. satu model tertentu sedang jenuh) tidak terpengaruh oleh
keduanya.

## 5. Verifikasi

```bash
bun ~/.opencode-free-bridge/verify.js            # semua model
bun ~/.opencode-free-bridge/verify.js --quick    # berhenti di model pertama yang menjawab
```

Exit code sejak v2.3.x:

| Kode | Arti |
| --- | --- |
| `0` | Ada model yang menjawab — bridge sehat |
| `2` | Bridge sehat & fingerprint TLS cocok, tapi upstream menolak alokasi IP ini (`403 FreeTierError`). CLI resmi dari IP yang sama juga dapat 403 — **bukan** alasan reinstall |
| `1` | Gagal nyata: bridge tidak terjangkau, jalan di Node, atau fingerprint TLS melenceng |

Opsional: `bun ~/.opencode-free-bridge/transport-fingerprint.js --check` untuk
membandingkan Bun lokal dengan baseline CLI (`transport-baseline.json`).

## 6. Self-healing upstream (v2.3.7–v2.3.11)

Pada `403 FreeTierError`, `426 UpgradeRequired`, atau `404` di path yang pindah,
bridge upstream:

1. refresh "recipe" + catalog dari upstream,
2. buang session ID basi dari cache dan bikin session baru,
3. escalate ke profil 12-tool penuh,
4. retry sekali secara transparan sebelum mengembalikan error ke klien.

Ini yang membuat v2.3.x jauh lebih tahan terhadap perubahan sisi upstream.

## 7. Log

```bash
journalctl --user -u opencode-free-bridge -f          # Linux (systemd)
tail -50 ~/Library/Logs/opencode-free-bridge.log      # macOS (launchd)
```

Shim relay (kalau diaktifkan) menulis log ke
`~/.local/state/opencode-free-bridge/relay-shim.log` bila `DEBUG_LOG` diset —
`scripts/setup-relay.sh` menyetelnya.

## 8. Perbandingan cepat: v1.5.3 vs v2.3.11

| | v1.5.3 (basis lama) | v2.3.11 (sekarang) |
| --- | --- | --- |
| Runtime | Node | **Bun** (wajib untuk gate) |
| Unit systemd | tanda kutip di `WorkingDirectory` → gagal | benar |
| 403/426/404 | diteruskan apa adanya | self-healing + retry |
| `verify.js` | OK/FAIL/BUSY | + kode `2` (gate) & cek fingerprint |
| Installer | tidak pasang Bun, tidak cek health | pasang Bun, staging + syntax check, cek `/health` + fingerprint |
| Fingerprint TLS | tidak diperiksa | `transport-fingerprint.js` |
