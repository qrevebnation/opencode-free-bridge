#!/usr/bin/env node
// Tambahkan connection tambahan ke provider node bridge yang sudah ada di 9Router.
// Dipakai untuk skenario multi-host: tiap host bridge (port/SSH-forward berbeda)
// didaftarkan sebagai connection sendiri, lalu 9Router round-robin + failover.
//
// Pemakaian:
//   node scripts/add-bridge-connection.js --url http://127.0.0.1:20130/v1 --name vps-1
//   BRIDGE_URL=http://127.0.0.1:20130/v1 CONNECTION_NAME=vps-1 node scripts/add-bridge-connection.js
//
// Demo/bersih-bersih:
//   node scripts/add-bridge-connection.js --url ... --name ... --delete

const os = require("node:os");
const path = require("node:path");

const PREFIX = process.env.PREFIX || "zen";
const NINE_ROUTER_DIR = process.env.NINE_ROUTER_DIR || path.join(os.homedir(), ".9router", "bin");

function arg(name) {
  const i = process.argv.indexOf(`--${name}`);
  return i >= 0 ? process.argv[i + 1] : undefined;
}

const BRIDGE_URL = arg("url") || process.env.BRIDGE_URL;
const CONNECTION_NAME = arg("name") || process.env.CONNECTION_NAME;
const API_KEY = process.env.API_KEY || "public";
const DELETE = process.argv.includes("--delete");

function loadClient() {
  const candidates = [
    process.env.NINE_ROUTER_CLIENT,
    path.join(NINE_ROUTER_DIR, "..", "..", "node_modules", "9router", "src", "cli", "api", "client.js"),
    path.join(os.homedir(), ".bun", "install", "global", "node_modules", "9router", "src", "cli", "api", "client.js"),
    "/usr/lib/node_modules/9router/src/cli/api/client.js",
    "/usr/local/lib/node_modules/9router/src/cli/api/client.js",
  ].filter(Boolean);
  for (const f of candidates) {
    try {
      return require(f);
    } catch {}
  }
  throw new Error("Modul API client 9router tidak ditemukan. Set NINE_ROUTER_CLIENT=/path/ke/client.js");
}

async function main() {
  const api = loadClient();

  const listed = await api.getProviderNodes();
  const nodes = listed?.data?.nodes || listed?.data || [];
  const node = nodes.find((n) => n.prefix === PREFIX);
  if (!node) {
    throw new Error(
      `Provider node dengan prefix "${PREFIX}" belum ada. Jalankan dulu: node scripts/add-9router-provider.js`
    );
  }

  if (DELETE) {
    if (!CONNECTION_NAME) throw new Error("--name wajib untuk --delete");
    const providers = await api.getProviders();
    const conns = (providers?.data?.connections || []).filter(
      (c) => c.provider === node.id && c.name === CONNECTION_NAME
    );
    if (conns.length === 0) return console.log(`Tidak ada connection bernama "${CONNECTION_NAME}".`);
    for (const c of conns) {
      const res = await api.deleteConnection(c.id);
      console.log(res?.success ? `Dihapus: ${c.name} (${c.id})` : `Gagal hapus ${c.id}: ${res?.error}`);
    }
    return;
  }

  if (!BRIDGE_URL) throw new Error("--url wajib (mis. http://127.0.0.1:20130/v1)");
  if (!CONNECTION_NAME) throw new Error("--name wajib (mis. vps-1)");

  const created = await api.createApiKeyProvider({
    provider: node.id,
    name: CONNECTION_NAME,
    apiKey: API_KEY,
  });
  if (!created?.success) throw new Error(`Gagal membuat connection: ${created?.error || JSON.stringify(created)}`);

  const conn = created.data.connection;
  const updated = await api.updateConnection(conn.id, {
    providerSpecificData: {
      prefix: PREFIX,
      apiType: "chat",
      baseUrl: BRIDGE_URL,
      nodeName: node.name,
      connectionProxyEnabled: false,
      connectionProxyUrl: "",
      connectionNoProxy: "",
      proxyPoolId: null,
    },
  });
  if (!updated?.success) throw new Error(`Gagal set baseUrl: ${updated?.error || JSON.stringify(updated)}`);

  console.log(`Connection dibuat: ${CONNECTION_NAME} (${conn.id}) -> ${BRIDGE_URL}`);

  const providers = await api.getProviders();
  const mine = (providers?.data?.connections || []).filter((c) => c.provider === node.id);
  console.log(`\nConnection pada provider "${PREFIX}" (${mine.length}):`);
  for (const c of mine) {
    const url = c.providerSpecificData?.baseUrl || "?";
    console.log(`  - ${c.name} | priority=${c.priority} | ${url} | status=${c.testStatus}`);
  }
  console.log("\nSemua connection ini dipakai 9Router untuk model zen/* (round-robin + failover).");
  console.log("Restart 9Router bila perubahan belum terbaca.");
}

main().catch((e) => {
  console.error(`Error: ${e.message}`);
  process.exit(1);
});
