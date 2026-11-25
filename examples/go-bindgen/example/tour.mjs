// Requests every route of the worker at the URL given (workerd's), or of
// the handler passed in (node.mjs), and prints each reply.
export const routes = [
  ['GET /', '/'],
  ['POST /echo', '/echo', { method: 'POST', headers: { 'x-go': 'hi' }, body: 'Hello!' }],
  ['POST /json', '/json', { method: 'POST', body: '{"item":"tea","quantity":2,"tags":["hot","green"]}' }],
  ['POST /json (not JSON)', '/json', { method: 'POST', body: '{nope' }],
  ['GET /rewrite', '/rewrite'],
  ['GET /errors', '/errors'],
  ['GET /parallel', '/parallel'],
  ['GET /counter/a', '/counter/a'],
  ['GET /counter/a (again)', '/counter/a'],
];

export async function tour(fetch) {
  for (const [label, path, init] of routes) {
    const r = await fetch(path, init);
    console.log(`${label}\n  ${r.status} ${(await r.text()).replaceAll('\n', '\n  ')}`);
  }
}

if (process.argv[2]) {
  const base = process.argv[2];
  await tour((path, init) => fetch(base + path, init));
}
