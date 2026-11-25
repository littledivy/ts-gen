// The worker's bindings from config.capnp, merged into workers-types' `Env`.
interface Env {
  readonly GREETING: string;
  readonly COUNTER: DurableObjectNamespace;
  readonly BACKEND: Fetcher;
}
