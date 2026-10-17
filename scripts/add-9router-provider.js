#!/usr/bin/env node
// Daftarkan opencode-free-bridge sebagai custom provider di 9Router lokal.
//
// Pemakaian:
//   node scripts/add-9router-provider.js
//   BRIDGE_URL=http://127.0.0.1:20129/v1 PREFIX=zen node scripts/add-9router-provider.js
//
// Script ini idempoten: kalau provider node dengan prefix yang sama sudah ada,
// pembuatan node dilewati dan hanya memastikan koneksinya tersedia.

const os = require("node:os");
const path = require("node:path");

const BRIDGE_URL = process.env.BRIDGE_URL || "http://127.0.0.1:20129/v1";
const PREFIX = process.env.PREFIX || "zen";
const NODE_NAME = process.env.NODE_NAME || "OpenCode Free Bridge";
const API_KEY = process.env.API_KEY || "public";
const NINE_ROUTER_DIR = process.env.NINE_ROUTER_DIR || path.join(os.homedir(), ".9router", "bin");

function loadClient() {
  const candidates = [
    process.env.NINE_ROUTER_CLIENT,
    path.join(NINE_ROUTER_DIR, "..", "..", "node_modules", "9router", "src", "cli", "api", "client.js"),
    path.join(os.homedir(), ".bun", "install", "global", "node_modules", "9router", "src", "cli", "api", "client.js"),
    "/usr/lib/node_modules/9router/src/cli/api/client.js",
    "/usr/local/lib/node_modules/9router/src/cli/api/client.js",
  ].filter(Boolean);

  for (const file of candidates) {
    try {
      return require(file);
    } catch {}
  }
  throw new Error(
    "Tidak menemukan modul API client 9router. Set NINE_ROUTER_CLIENT=/path/ke/client.js"
  );
}

async function main() {
  const api = loadClient();

  const listed = await api.getProviderNodes();
  const nodes = listed?.data?.nodes || listed?.data || [];
  const existing = nodes.find((n) => n.prefix === PREFIX);

  if (existing) {
    console.log(`Provider node prefix "${PREFIX}" sudah ada: ${existing.name} (${existing.id})`);
    await ensureConnection(api, existing);
    return;
  }

  const created = await api.createProviderNode({
    name: NODE_NAME,
    prefix: PREFIX,
    baseUrl: BRIDGE_URL,
    type: "openai-compatible",
    apiType: "chat",
  });

  if (!created?.success) {
    throw new Error(`Gagal membuat provider node: ${created?.error || JSON.stringify(created)}`);
  }

  const node = created.data.node;
  console.log(`Provider node dibuat: ${node.name} (${node.id})`);
  await ensureConnection(api, node);
}

async function ensureConnection(api, node) {
  const providers = await api.getProviders();
  const connections = providers?.data?.connections || [];
  let conn = connections.find((c) => c.provider === node.id);

  if (conn) {
    console.log(`Koneksi sudah ada: ${conn.name} (${conn.id})`);
  } else {
    const res = await api.createApiKeyProvider({
      provider: node.id,
      name: "bridge-local",
      apiKey: API_KEY,
    });
    if (!res?.success) {
      throw new Error(`Gagal membuat koneksi: ${res?.error || JSON.stringify(res)}`);
    }
    conn = res.data.connection;
    console.log(`Koneksi dibuat: ${conn.name} (${conn.id})`);
  }

  await clearProxyPool(api, conn);

  const models = await api.getAvailableModels();
  const ids = (models?.data?.data || [])
    .map((m) => m.id)
    .filter((id) => id.startsWith(`${PREFIX}/`));

  console.log(`\nModel tersedia via 9Router (${ids.length}):`);
  for (const id of ids) console.log(`  - ${id}`);

  if (ids.length === 0) {
    console.log(
      "\nBelum ada model. Tunggu ±1 menit sampai bridge selesai discovery, lalu jalankan ulang."
    );
  }
}

// Bridge lokal tidak bisa dijangkau proxy pool (relay cloud). Pastikan pool kosong,
// lalu restart 9Router supaya perubahan terbaca.
async function clearProxyPool(api, conn) {
  const psd = conn?.providerSpecificData || {};
  if (!psd.proxyPoolId) {
    console.log("Proxy pool: kosong (OK)");
    return;
  }
  console.log(`Proxy pool terpasang (${psd.proxyPoolId}) — menghapus...`);
  const res = await api.updateConnection(conn.id, {
    providerSpecificData: { ...psd, proxyPoolId: null },
  });
  if (!res?.success) {
    console.warn(`Gagal menghapus proxy pool: ${res?.error || JSON.stringify(res)}`);
    return;
  }
  console.log("Proxy pool dihapus. Restart 9Router agar berlaku (lihat README bagian 6).");
}

main().catch((err) => {
  console.error(`Error: ${err.message}`);
  process.exit(1);
});
