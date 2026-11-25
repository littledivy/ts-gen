// Runs the routes node can serve (all but /counter, which needs a Durable
// Object). The wasm modules load as WebAssembly.Module, as workerd's do;
// HTMLRewriter is a stub of the one element handler /rewrite uses, and
// BACKEND is backend.js called in place.
import { registerHooks } from 'node:module';

registerHooks({
  load(url, context, next) {
    if (url.endsWith('.wasm')) {
      return { format: 'module', shortCircuit: true, source:
        `export default new WebAssembly.Module((await import("node:fs")).readFileSync(new URL(${JSON.stringify(url)})));` };
    }
    return next(url, context);
  },
});

globalThis.HTMLRewriter ??= class {
  #handlers = [];
  on(selector, handlers) { this.#handlers.push(handlers); return this; }
  transform(response) {
    const handlers = this.#handlers;
    const rewrite = (html) => html.replace(/<a ([^>]*)>/g, (_, attrs) => {
      const set = {};
      for (const h of handlers) h.element?.({ setAttribute(k, v) { set[k] = v; return this; } });
      return `<a ${attrs}${Object.entries(set).map(([k, v]) => ` ${k}="${v}"`).join('')}>`;
    });
    return new Response(new ReadableStream({
      async start(c) {
        c.enqueue(new TextEncoder().encode(rewrite(await response.text())));
        c.close();
      },
    }));
  }
};

const { default: backend } = await import(new URL('./backend.js', import.meta.url));
const { default: worker } = await import(new URL('./loader.js', import.meta.url));
const { tour, routes } = await import(new URL('./tour.mjs', import.meta.url));
// Env is read whole on each request, so COUNTER needs a value.
const env = { GREETING: 'Hello', COUNTER: {}, BACKEND: { fetch: (input, init) => backend.fetch(new Request(input, init)) } };
const ctx = { waitUntil() {}, passThroughOnException() {} };
routes.splice(routes.findIndex(([, p]) => p.startsWith('/counter')));
await tour((path, init) => worker.fetch(new Request('http://example' + path, init), env, ctx));
