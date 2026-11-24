// The second service of config.capnp, in plain JS: what `/fetch` reaches
// through the BACKEND binding.
export default {
  async fetch(request) {
    const { pathname } = new URL(request.url);
    const body = await request.text();
    return new Response(`${request.method} ${pathname}${body && `, with "${body}"`}, from the backend`);
  },
};
