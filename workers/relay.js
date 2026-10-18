// Relay untuk Cloudflare Workers — forwarder generik dengan kontrak yang sama
// seperti relay 9Router: target diambil dari header x-relay-target + x-relay-path.
//
// Deploy:
//   npx wrangler login
//   npx wrangler deploy
//
// Hasilnya URL seperti https://opencode-relay.<subdomain>.workers.dev — pakai
// sebagai salah satu isi RELAY_URLS, mis.:
//   RELAY_URLS="https://opencode-relay.xxx.workers.dev,https://relay-b.vercel.app" \
//     bash scripts/setup-relay.sh

export default {
  async fetch(request) {
    const target = request.headers.get("x-relay-target");
    const relayPath = request.headers.get("x-relay-path") || "/";

    if (!target) {
      return new Response(JSON.stringify({ error: "Missing x-relay-target header" }), {
        status: 400,
        headers: { "content-type": "application/json" },
      });
    }

    const targetUrl = target.replace(/\/$/, "") + relayPath;

    const headers = new Headers(request.headers);
    headers.delete("x-relay-target");
    headers.delete("x-relay-path");
    headers.delete("host");

    const init = { method: request.method, headers };
    if (request.method !== "GET" && request.method !== "HEAD") {
      init.body = request.body;
      init.duplex = "half";
    }

    try {
      const response = await fetch(targetUrl, init);
      return new Response(response.body, {
        status: response.status,
        headers: response.headers,
      });
    } catch (error) {
      return new Response(JSON.stringify({ error: error.message }), {
        status: 502,
        headers: { "content-type": "application/json" },
      });
    }
  },
};
