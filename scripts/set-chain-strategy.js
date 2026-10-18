#!/usr/bin/env node
// Setel urutan tingkat pada 9Router:
//   - connection tingkat 1 (bridge :20129, IP sendiri) diberi priority 1
//   - strategi provider diset "fill-first" = pakai connection berprioritas
//     terkecil selama bisa, pindah otomatis saat gagal (429/403)
//
// Pemakaian:
//   node scripts/set-chain-strategy.js          # setel
//   node scripts/set-chain-strategy.js show     # tampilkan urutan saja
//   node scripts/set-chain-strategy.js reset    # hapus override strategi

const os = require("node:os");
const path = require("node:path");

const PREFIX = process.env.PREFIX || "zen";
const TIER1_PORT = process.env.TIER1_PORT || "20129";

function loadClient() {
  const candidates = [
    process.env.NINE_ROUTER_CLIENT,
    path.join(os.homedir(), ".bun", "install", "global", "node_modules", "9router", "src", "cli", "api", "client.js"),
    "/usr/lib/node_modules/9router/src/cli/api/client.js",
    "/usr/local/lib/node_modules/9router/src/cli/api/client.js",
  ].filter(Boolean);
  for (const f of candidates) {
    try {
      return require(f);
    } catch {}
  }
  throw new Error("Modul API client 9router tidak ditemukan.");
}

const mode = process.argv[2] || "set";

(async () => {
  const api = loadClient();

  const nodes = (await api.getProviderNodes())?.data?.nodes || [];
  const node = nodes.find((n) => n.prefix === PREFIX);
  if (!node) throw new Error(`Provider node prefix "${PREFIX}" tidak ada. Jalankan add-9router-provider.js dulu.`);

  const conns = ((await api.getProviders())?.data?.connections || [])
    .filter((c) => c.provider === node.id)
    .sort((a, b) => (a.priority ?? 999) - (b.priority ?? 999));

  if (mode === "show" || mode === "reset" || mode === "set") {
    if (conns.length === 0) console.log("  (belum ada connection)");
    for (const c of conns) {
      const url = c.providerSpecificData?.baseUrl || "?";
      console.log(`  priority ${String(c.priority ?? "-").padEnd(3)} | ${(c.name || "?").padEnd(10)} | ${url}`);
    }
  }

  if (mode === "show") return;

  // tingkat 1 = connection yang menunjuk bridge utama
  for (const c of conns) {
    const url = c.providerSpecificData?.baseUrl || "";
    if (url.includes(`:${TIER1_PORT}/`)) {
      const r = await api.updateConnection(c.id, { priority: 1 });
      if (r?.success) console.log(`Tingkat 1: ${c.name} -> priority 1`);
      else console.error(`Gagal set priority: ${r?.error}`);
    }
  }

  const settings = (await api.getSettings())?.data || {};
  const strategies = { ...(settings.providerStrategies || {}) };

  if (mode === "reset") {
    delete strategies[node.id];
  } else {
    strategies[node.id] = { fallbackStrategy: "fill-first" };
  }

  const res = await api.updateSettings({ providerStrategies: strategies });
  console.log(res?.success ? `Strategi: ${mode === "reset" ? "direset (default fill-first)" : "fill-first"}` : `Gagal set strategi: ${res?.error}`);
})().catch((e) => {
  console.error(`Error: ${e.message}`);
  process.exit(1);
});
