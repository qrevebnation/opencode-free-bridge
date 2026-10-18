#!/usr/bin/env node
// Relay shim: jembatan antara opencode-free-bridge dan relay proxy 9Router.
//
// Kenapa perlu: bridge tidak mendukung env HTTP_PROXY, dan relay 9Router memakai
// protokol header (x-relay-target / x-relay-path), bukan HTTP CONNECT. Shim ini
// menerjemahkan request bridge menjadi request relay, sehingga egress ke
// opencode.ai keluar dari IP relay — bukan IP mesin lokal.
//
// Rotasi + cooldown: relay yang membalas 403 (FreeTierError) / 429 / 5xx dianggap
// sedang kehabisan jatah IP, lalu disisihkan selama RELAY_COOLDOWN_MS (default 60s)
// agar trafik berikutnya tidak terus dikirim ke relay mati. Relay sehat dipakai
// lebih dulu; relay yang sedang cooldown hanya dipakai kalau semuanya cooldown.
//
// Pemakaian:
//   RELAY_URLS="https://relay-a.vercel.app,https://relay-b.vercel.app" node relay-shim.js
//   RELAY_URL=https://relay-a.vercel.app node relay-shim.js        # satu relay saja
//
// Lalu set env bridge:
//   OPENCODE_CHAT_URL=http://127.0.0.1:20140/inference/v1/chat/completions
//   OPENCODE_RESPONSES_URL=http://127.0.0.1:20140/inference/v1/responses
//   OPENCODE_MODELS_URL=http://127.0.0.1:20140/inference/v1/models

const http = require("node:http");
const https = require("node:https");
const fs = require("node:fs");

const LISTEN = Number(process.env.PORT || 20140);
const HOST = process.env.HOST || "127.0.0.1";
const TARGET = process.env.RELAY_TARGET || "https://opencode.ai";
const TIMEOUT_MS = Number(process.env.TIMEOUT_MS || 180000);
const COOLDOWN_MS = Number(process.env.RELAY_COOLDOWN_MS || 60000);
// Kalau semua relay ditolak, coba jalur langsung (IP mesin ini) sebelum menyerah.
// Berguna karena gate upstream menolak egress datacenter (relay) dengan 403,
// sementara IP sendiri mungkin masih punya jatah.
const FALLBACK_DIRECT = (process.env.RELAY_FALLBACK_DIRECT || "1") !== "0";
const DEBUG_LOG = process.env.DEBUG_LOG || "";

const relayUrls = (process.env.RELAY_URLS || process.env.RELAY_URL || "")
  .split(",")
  .map((s) => s.trim())
  .filter(Boolean);

if (relayUrls.length === 0) {
  console.error('RELAY_URL / RELAY_URLS wajib diisi. Contoh: RELAY_URLS="https://a.vercel.app,https://b.vercel.app"');
  process.exit(1);
}

const relays = relayUrls.map((u) => new URL(u));
let cursor = 0;

// hostname -> timestamp sampai kapan relay dianggap tidak sehat
const downUntil = new Map();

function debug(record) {
  if (!DEBUG_LOG) return;
  try {
    fs.appendFileSync(DEBUG_LOG, JSON.stringify(record) + "\n");
  } catch {}
}

function isHealthy(relay) {
  return (downUntil.get(relay.hostname) || 0) <= Date.now();
}

// Urutan kandidat untuk satu request: relay sehat dulu (mulai dari posisi
// round-robin), lalu relay yang sedang cooldown (yang paling cepat pulih dulu).
function candidateOrder() {
  const start = cursor++ % relays.length;
  const healthy = [];
  const cooling = [];
  for (let i = 0; i < relays.length; i++) {
    const relay = relays[(start + i) % relays.length];
    (isHealthy(relay) ? healthy : cooling).push(relay);
  }
  cooling.sort((a, b) => (downUntil.get(a.hostname) || 0) - (downUntil.get(b.hostname) || 0));
  return [...healthy, ...cooling];
}

function markDown(relay, reason) {
  downUntil.set(relay.hostname, Date.now() + COOLDOWN_MS);
  debug({ ts: new Date().toISOString(), relay: relay.hostname, event: "cooldown", reason, ms: COOLDOWN_MS });
}

function markUp(relay) {
  if (downUntil.delete(relay.hostname)) {
    debug({ ts: new Date().toISOString(), relay: relay.hostname, event: "recovered" });
  }
}

const server = http.createServer((req, res) => {
  const chunks = [];
  req.on("data", (c) => chunks.push(c));
  req.on("end", () => {
    const bodyBuf = Buffer.concat(chunks);
    const order = candidateOrder();
    forward(bodyBuf, order, 0);
  });

  function forward(bodyBuf, order, index) {
    if (index >= order.length) {
      if (FALLBACK_DIRECT) return forwardDirect(bodyBuf);
      if (!res.headersSent) res.writeHead(502, { "content-type": "application/json" });
      return res.end(
        JSON.stringify({ error: { message: `relay shim: semua relay gagal (${order.length})` } })
      );
    }

    const relay = order[index];
    const headers = { ...req.headers };
    delete headers.host;
    delete headers["content-length"];
    headers["x-relay-target"] = TARGET;
    headers["x-relay-path"] = req.url;

    let settled = false;

    const preq = https.request(
      {
        host: relay.hostname,
        port: relay.port || 443,
        path: "/",
        method: req.method,
        headers,
        timeout: TIMEOUT_MS,
      },
      (pres) => {
        const out = { ...pres.headers };
        delete out["connection"];
        delete out["keep-alive"];
        delete out["transfer-encoding"];

        const retriable = pres.statusCode === 403 || pres.statusCode === 429 || pres.statusCode >= 500;
        debug({ ts: new Date().toISOString(), relay: relay.hostname, status: pres.statusCode, url: req.url, wentCold: !isHealthy(relay) });

        if (retriable) {
          settled = true;
          pres.resume();
          markDown(relay, `status ${pres.statusCode}`);
          return forward(bodyBuf, order, index + 1);
        }

        settled = true;
        markUp(relay);
        res.writeHead(pres.statusCode, out);
        pres.pipe(res);
      }
    );

    preq.on("timeout", () => preq.destroy(new Error("relay timeout")));
    preq.on("error", (err) => {
      if (settled) return;
      settled = true;
      debug({ ts: new Date().toISOString(), relay: relay.hostname, error: err.message, index });
      markDown(relay, err.message);
      forward(bodyBuf, order, index + 1);
    });

    preq.end(bodyBuf);
  }

  // Jalur terakhir: kirim langsung ke upstream (tanpa relay).
  function forwardDirect(bodyBuf) {
    const target = new URL(TARGET);
    const headers = { ...req.headers };
    delete headers.host;
    delete headers["content-length"];

    debug({ ts: new Date().toISOString(), relay: "direct", event: "fallback", url: req.url });

    const preq = https.request(
      {
        host: target.hostname,
        port: target.port || 443,
        path: req.url,
        method: req.method,
        headers,
        timeout: TIMEOUT_MS,
      },
      (pres) => {
        const out = { ...pres.headers };
        delete out["connection"];
        delete out["keep-alive"];
        delete out["transfer-encoding"];
        res.writeHead(pres.statusCode, out);
        pres.pipe(res);
      }
    );

    preq.on("timeout", () => preq.destroy(new Error("upstream timeout")));
    preq.on("error", (err) => {
      if (!res.headersSent) res.writeHead(502, { "content-type": "application/json" });
      res.end(JSON.stringify({ error: { message: `relay shim (direct): ${err.message}` } }));
    });

    preq.end(bodyBuf);
  }
});

server.listen(LISTEN, HOST, () => {
  console.log(
    `relay-shim on http://${HOST}:${LISTEN} -> ${relays.map((r) => r.hostname).join(", ")} ` +
      `(target ${TARGET}, cooldown ${COOLDOWN_MS}ms)`
  );
});
