// The WASI preview1 functions a Go wasip1 module imports, for a host
// without WASI (workerd). poll_oneoff, which Go calls to sleep, suspends
// the module under JSPI instead of blocking.
export function wasi(memory) {
  const view = () => new DataView(memory().buffer);
  const bytes = () => new Uint8Array(memory().buffer);
  const lines = { 1: '', 2: '' };
  const decoder = new TextDecoder();
  const poll = async (subs, events, n, nevents) => {
    const v = view();
    let wait = 0;
    for (let i = 0; i < n; i++) {
      const s = subs + i * 48;
      if (v.getUint8(s + 8) === 0) {
        const t = Number(v.getBigUint64(s + 24, true)) / 1e6;
        const abs = v.getUint16(s + 40, true) & 1;
        wait = Math.max(wait, abs ? t - Date.now() : t);
      }
    }
    if (wait > 0) await new Promise((r) => setTimeout(r, wait));
    const w = view();
    for (let i = 0; i < n; i++) {
      const s = subs + i * 48, e = events + i * 32;
      w.setBigUint64(e, w.getBigUint64(s, true), true);
      w.setUint16(e + 8, 0, true);
      w.setUint8(e + 10, w.getUint8(s + 8));
    }
    w.setUint32(nevents, n, true);
    return 0;
  };
  return {
    args_sizes_get: (argc, size) => (view().setUint32(argc, 0, true), view().setUint32(size, 0, true), 0),
    args_get: () => 0,
    environ_sizes_get: (n, size) => (view().setUint32(n, 0, true), view().setUint32(size, 0, true), 0),
    environ_get: () => 0,
    clock_time_get: (id, _precision, out) => {
      const ns = id === 0 ? BigInt(Date.now()) * 1000000n : BigInt(Math.round(performance.now() * 1e6));
      view().setBigUint64(out, ns, true);
      return 0;
    },
    random_get: (buf, len) => {
      for (let i = 0; i < len; i += 65536) crypto.getRandomValues(bytes().subarray(buf + i, buf + Math.min(len, i + 65536)));
      return 0;
    },
    fd_write: (fd, iovs, n, written) => {
      const v = view();
      let total = 0;
      for (let i = 0; i < n; i++) {
        const p = v.getUint32(iovs + i * 8, true), len = v.getUint32(iovs + i * 8 + 4, true);
        lines[fd] = (lines[fd] ?? '') + decoder.decode(bytes().subarray(p, p + len));
        total += len;
      }
      const parts = lines[fd].split('\n');
      lines[fd] = parts.pop();
      for (const l of parts) (fd === 2 ? console.error : console.log)(l);
      v.setUint32(written, total, true);
      return 0;
    },
    // stdin, stdout and stderr are character devices; there are no
    // preopened directories (EBADF ends Go's scan for them).
    fd_fdstat_get: (fd, out) => {
      if (fd > 2) return 8;
      const v = view();
      for (let i = 0; i < 24; i += 4) v.setUint32(out + i, 0, true);
      v.setUint8(out, 2);
      return 0;
    },
    fd_fdstat_set_flags: () => 0,
    fd_prestat_get: () => 8,
    fd_prestat_dir_name: () => 8,
    poll_oneoff: new WebAssembly.Suspending(poll),
    sched_yield: () => 0,
    proc_exit: (code) => { throw new Error(`exit ${code}`); },
  };
}
