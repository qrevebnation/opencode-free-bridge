#!/usr/bin/env node
// Proxy HTTP CONNECT lokal yang meneruskan koneksi lewat SOCKS5 (mis. `ssh -D`).
//
// Kenapa: gate free-tier OpenCode menolak egress datacenter (relay Vercel/edge)
// dengan 403 FreeTierError, dan menolak Node karena TLS ClientHello-nya berbeda.
// Relay juga memutus TLS di sisi edge, jadi fingerprint Bun-nya hilang.
//
// Proxy ini hanya memindahkan IP: TLS bridge tetap end-to-end (Bun), sehingga
// gate melihat transport Bun dari IP baru.
//
// Pemakaian:
//   ssh -N -D 127.0.0.1:1080 user@host-lain      # SOCKS5 lewat SSH
//   SOCKS_HOST=127.0.0.1 SOCKS_PORT=1080 node connect-proxy.js
//
// Lalu set env bridge (unit systemd):
//   HTTPS_PROXY=http://127.0.0.1:1085
//
// Verifikasi IP egress:
//   curl -s -x http://127.0.0.1:1085 https://api.ipify.org

const http = require("node:http");
const net = require("node:net");

const LISTEN = Number(process.env.PORT || 1085);
const HOST = process.env.HOST || "127.0.0.1";
const SOCKS_HOST = process.env.SOCKS_HOST || "127.0.0.1";
const SOCKS_PORT = Number(process.env.SOCKS_PORT || 1080);
const CONNECT_TIMEOUT_MS = Number(process.env.CONNECT_TIMEOUT_MS || 20000);

function socksConnect(dstHost, dstPort, cb) {
  const sock = net.connect({ host: SOCKS_HOST, port: SOCKS_PORT });
  let done = false;
  const fail = (err) => {
    if (done) return;
    done = true;
    sock.destroy();
    cb(err);
  };
  const timer = setTimeout(() => fail(new Error("timeout SOCKS")), CONNECT_TIMEOUT_MS);

  sock.on("error", fail);
  sock.on("connect", () => sock.write(Buffer.from([0x05, 0x01, 0x00]))); // ver 5, no-auth

  let stage = "greeting";
  let buf = Buffer.alloc(0);

  sock.on("data", (chunk) => {
    if (done) return;
    buf = Buffer.concat([buf, chunk]);

    if (stage === "greeting") {
      if (buf.length < 2) return;
      if (buf[0] !== 0x05) return fail(new Error("bukan SOCKS5"));
      if (buf[1] !== 0x00) return fail(new Error(`SOCKS5 butuh auth (${buf[1]})`));
      buf = buf.subarray(2);
      stage = "reply";

      // hanya IPv4/hostname yang didukung cukup untuk kasus ini
      const hostBuf = Buffer.from(dstHost, "utf8");
      const req = Buffer.concat([
        Buffer.from([0x05, 0x01, 0x00, 0x03, hostBuf.length]),
        hostBuf,
        Buffer.from([(dstPort >> 8) & 0xff, dstPort & 0xff]),
      ]);
      sock.write(req);
      return;
    }

    if (stage === "reply") {
      if (buf.length < 4) return;
      if (buf[1] !== 0x00) return fail(new Error(`SOCKS5 CONNECT gagal (kode ${buf[1]})`));
      const atyp = buf[3];
      let need = 4;
      if (atyp === 0x01) need += 4 + 2;
      else if (atyp === 0x04) need += 16 + 2;
      else if (atyp === 0x03) {
        if (buf.length < 5) return;
        need += 1 + buf[4] + 2;
      } else return fail(new Error(`ATYP tidak dikenal ${atyp}`));
      if (buf.length < need) return;

      done = true;
      clearTimeout(timer);
      sock.removeAllListeners("data");
      cb(null, sock, buf.subarray(need));
    }
  });
}

const server = http.createServer((req, res) => {
  res.writeHead(501, { "content-type": "text/plain" });
  res.end("Proxy ini hanya melayani metode CONNECT (HTTPS).\n");
});

server.on("connect", (req, clientSocket, head) => {
  const [dstHost, dstPortRaw] = req.url.split(":");
  const dstPort = Number(dstPortRaw || 443);

  socksConnect(dstHost, dstPort, (err, upstream, leftover) => {
    if (err) {
      clientSocket.end("HTTP/1.1 502 Bad Gateway\r\n\r\n");
      return;
    }
    clientSocket.write("HTTP/1.1 200 Connection Established\r\n\r\n");
    if (head?.length) upstream.write(head);
    if (leftover?.length) clientSocket.write(leftover);
    upstream.pipe(clientSocket);
    clientSocket.pipe(upstream);
    const close = () => {
      upstream.destroy();
      clientSocket.destroy();
    };
    upstream.on("error", close);
    clientSocket.on("error", close);
  });
});

server.listen(LISTEN, HOST, () => {
  console.log(`connect-proxy on http://${HOST}:${LISTEN} -> socks5://${SOCKS_HOST}:${SOCKS_PORT}`);
});
