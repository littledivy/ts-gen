// The WASI preview1 functions Swift's static runtime imports, as little as
// a worker needs: stdout and stderr go to the console a line at a time,
// clocks and randomness are the platform's, there are no arguments,
// environment or files, and the module runs as a reactor (no exit).
const ERRNO_SUCCESS = 0;
const ERRNO_BADF = 8;
const ERRNO_NOSYS = 52;

export function wasi(memory) {
  const view = () => new DataView(memory().buffer);
  const bytes = (p, n) => new Uint8Array(memory().buffer, p, n);
  const decoder = new TextDecoder();
  const lines = { 1: '', 2: '' };
  const write = (fd, text) => {
    lines[fd] += text;
    let nl;
    while ((nl = lines[fd].indexOf('\n')) >= 0) {
      (fd === 1 ? console.log : console.error)(lines[fd].slice(0, nl));
      lines[fd] = lines[fd].slice(nl + 1);
    }
  };
  const empty = (countPtr, sizePtr) => {
    view().setUint32(countPtr, 0, true);
    view().setUint32(sizePtr, 0, true);
    return ERRNO_SUCCESS;
  };
  return {
    args_get: () => ERRNO_SUCCESS,
    args_sizes_get: empty,
    environ_get: () => ERRNO_SUCCESS,
    environ_sizes_get: empty,
    clock_res_get: (id, out) => {
      view().setBigUint64(out, 1000n, true);
      return ERRNO_SUCCESS;
    },
    clock_time_get: (id, precision, out) => {
      const ns = id === 0 ? BigInt(Date.now()) * 1_000_000n : BigInt(Math.round(performance.now() * 1e6));
      view().setBigUint64(out, ns, true);
      return ERRNO_SUCCESS;
    },
    fd_write: (fd, iovs, n, written) => {
      if (fd !== 1 && fd !== 2) return ERRNO_BADF;
      let total = 0;
      for (let i = 0; i < n; i++) {
        const p = view().getUint32(iovs + i * 8, true);
        const len = view().getUint32(iovs + i * 8 + 4, true);
        write(fd, decoder.decode(bytes(p, len)));
        total += len;
      }
      view().setUint32(written, total, true);
      return ERRNO_SUCCESS;
    },
    fd_fdstat_get: (fd, out) => {
      if (fd > 2) return ERRNO_BADF;
      bytes(out, 24).fill(0);
      view().setUint8(out, 2); // a character device
      return ERRNO_SUCCESS;
    },
    fd_prestat_get: () => ERRNO_BADF,
    fd_prestat_dir_name: () => ERRNO_BADF,
    fd_close: () => ERRNO_BADF,
    fd_read: () => ERRNO_BADF,
    fd_seek: () => ERRNO_BADF,
    path_open: () => ERRNO_NOSYS,
    poll_oneoff: () => ERRNO_NOSYS,
    random_get: (p, n) => {
      crypto.getRandomValues(bytes(p, n));
      return ERRNO_SUCCESS;
    },
    proc_exit: (code) => {
      throw new WebAssembly.RuntimeError(`exit(${code})`);
    },
  };
}
