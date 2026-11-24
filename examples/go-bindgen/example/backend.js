// The worker's outbound service: replies after a delay, so /parallel can
// show its three fetches overlapping.
export default {
  async fetch(request) {
    const url = new URL(request.url);
    const ms = Number(url.searchParams.get('ms') ?? 0);
    await new Promise((r) => setTimeout(r, ms));
    return new Response(`backend ${url.pathname}`);
  },
};
