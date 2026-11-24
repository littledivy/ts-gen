#!/usr/bin/env node
// WebSocket soak for soak/app's Durable Object (hibernation API): opens
// `conns` sockets in turn to /do/<name>/ws, `parallel` at a time, sends
// `msgs` messages on each and checks every echo, then closes it.
//
//   node soak/ws.mjs <port> [conns 1000] [msgs 20] [parallel 10] [objects 10]
const [port, conns = 1000, msgs = 20, parallel = 10, objects = 10] = process.argv.slice(2).map(Number);
const base = `ws://127.0.0.1:${port}`;

function one(i) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(`${base}/do/ws${i % objects}/ws`);
    let got = 0;
    const timer = setTimeout(() => reject(new Error(`socket ${i}: timed out after ${got} echoes`)), 20000);
    ws.onopen = () => ws.send(`m0`);
    ws.onmessage = (e) => {
      if (!String(e.data).startsWith(`echo m${got} `)) return reject(new Error(`socket ${i}: unexpected ${e.data}`));
      got++;
      if (got < msgs) ws.send(`m${got}`);
      else ws.close(1000, "done");
    };
    ws.onclose = () => {
      clearTimeout(timer);
      got === msgs ? resolve() : reject(new Error(`socket ${i}: closed after ${got} echoes`));
    };
    ws.onerror = () => {};
  });
}

let next = 0, failed = 0;
const t0 = Date.now();
async function worker() {
  while (next < conns) {
    const i = next++;
    try {
      await one(i);
    } catch (e) {
      if (failed++ < 5) console.error(e.message);
    }
  }
}
await Promise.all(Array.from({ length: parallel }, worker));
console.log(JSON.stringify({ conns, msgs, failed, seconds: (Date.now() - t0) / 1000 }));
