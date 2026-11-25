// What the Go module provides: the fetch handler and the Counter Durable
// Object class.
/** @provides fetch */
declare const handler: ExportedHandler<Env>;
export default handler;

export declare class Counter {
  constructor(ctx: DurableObjectState, env: Env);
  fetch(request: Request): Promise<Response>;
}
