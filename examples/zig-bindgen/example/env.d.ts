// The worker's bindings from config.capnp, merged into workers-types' `Env`.
interface Env {
  readonly GREETING: string;
  readonly BACKEND: Fetcher;
  readonly COUNTER: DurableObjectNamespace;
}

// HTMLRewriter's element handlers as callback properties: workers-types
// declares them as optional methods, which lower as methods to call.
interface ElementHandlers {
  element?: (element: Element) => void;
}
interface HTMLRewriter {
  on(selector: string, handlers: ElementHandlers): HTMLRewriter;
}
