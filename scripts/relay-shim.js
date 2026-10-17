#!/usr/bin/env node
// Relay shim: jembatan antara opencode-free-bridge dan relay proxy 9Router.
//
// Kenapa perlu: bridge tidak mendukung env HTTP_PROXY, dan relay 9Router
// memakai protokol header (x-relay-target / x-relay-path), bukan HTTP CONNECT.
// Shim ini menerjemahkan request bridge menjadi request relay, sehingga egress
// ke opencode.ai keluar dari IP relay (Vercel) — bukan IP mesin lokal. Ini yang
// menyebar rate limit per-IP upstream.
//
// Pemakaian:
//   RELAY_URLS="https://relay-a.vercel.app,https://relay-b.vercel.app" node relay-shim.js
//   RELAY_URL=https://relay-a.vercel.app node relay-shim.js        # satu relay saja
//
// Beberapa relay dirotasi (round-robin). Kalau sebuah relay membalas 403
// (FreeTierError) / 429 / 5xx, request dicoba ke relay berikutnya.
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

function debug(record) {
  if (!DEBUG_LOG) return;
  try {
    fs.appendFileSync(DEBUG_LOG, JSON.stringify(record) + "\n");
  } catch {}
}

function pickRelay() {
  const relay = relays[cursor % relays.length];
  cursor += 1;
  return relay;
}

const server = http.createServer((req, res) => {
  const chunks = [];
  req.on("data", (c) => chunks.push(c));
  req.on("end", () => {
    const bodyBuf = Buffer.concat(chunks);
    attempt(bodyBuf, 0);
  });

  function attempt(bodyBuf, tried) {
    if (tried >= relays.length) {
      if (!res.headersSent) res.writeHead(502, { "content-type": "application/json" });
      return res.end(
        JSON.stringify({ error: { message: `relay shim: semua relay gagal (${relays.length})` } })
      );
    }
    forward(bodyBuf, tried);
  }

  function forward(bodyBuf, tried) {
    const relay = pickRelay();
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
        debug({ ts: new Date().toISOString(), relay: relay.hostname, status: pres.statusCode, url: req.url, tried });

        if (retriable && tried + 1 < relays.length) {
          settled = true;
          pres.resume();
          return attempt(bodyBuf, tried + 1);
        }

        settled = true;
        // opencode mengirim body teks walau status non-2xx; jangan hilangkan
        // content-length pada perespons agar klien membaca pesan aslinya.
        res.writeHead(pres.statusCode, out);
        pres.pipe(res);
      }
    );

    preq.on("timeout", () => preq.destroy(new Error("relay timeout")));
    preq.on("error", (err) => {
      if (settled) return;
      settled = true;
      debug({ ts: new Date().toISOString(), relay: relay.hostname, error: err.message, tried });
      if (tried + 1 < relays.length) return attempt(bodyBuf, tried + 1);
      if (!res.headersSent) res.writeHead(502, { "content-type": "application/json" });
      res.end(JSON.stringify({ error: { message: `relay shim: ${err.message}` } }));
    });

    preq.end(bodyBuf);
  }
});

server.listen(LISTEN, HOST, () => {
  console.log(
    `relay-shim on http://${HOST}:${LISTEN} -> ${relays.map((r) => r.hostname).join(", ")} (target ${TARGET})`
  );
});
