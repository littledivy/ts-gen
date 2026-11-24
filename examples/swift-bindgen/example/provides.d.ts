// What the worker provides: the default export's fetch handler and a
// Durable Object.

/** @provides fetch */
declare const handler: ExportedHandler<Env>;
export default handler;

/** A Durable Object: a counter in KV and SQL storage. */
export declare class Counter {
  constructor(ctx: DurableObjectState, env: Env);
  fetch(request: Request): Promise<Response>;
}
