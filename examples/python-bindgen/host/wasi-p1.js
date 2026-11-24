// WASI preview1 (wasi_snapshot_preview1) for Workers.
//
//   const wasi = wasiP1(() => instance.exports.memory, { args, env, files, log });
//   new WebAssembly.Instance(module, { ...wasi });
//
// It uses only what a Worker has: crypto, Date, performance, TextEncoder/TextDecoder,
// console, setTimeout and, when present, WebAssembly.Suspending. Every preview1
// function exists. What Workers can't do fails with the errno a POSIX system would
// give (EROFS, ENOTSOCK, EBADF, ...), never a silent success.
//
// - args and environ are empty unless the caller passes `args` and `env`.
// - stdin reads EOF. stdout and stderr are line-buffered to log.log and log.error,
//   and flush() writes out a partial line. Both report as character devices, so
//   C stdio line-buffers them, as it would on a terminal.
// - `files` maps absolute paths to Uint8Array contents, for example
//   { "/data/words.txt": bytes }. When it is non-empty the guest gets one
//   preopened, read-only directory "/" holding those files.
// - poll_oneoff sleeps for real by suspending the guest through JSPI. The guest's
//   export must be called through WebAssembly.promising. Pass { suspend: false }
//   when it isn't; sleeps then return at once.
// - proc_exit throws WasiExit, which carries the exit code.

export class WasiExit extends Error {
  constructor(code) {
    super(`wasi: proc_exit(${code})`);
    this.name = "WasiExit";
    this.code = code;
  }
}

// The witx errno values.
export const ERRNO = {
  SUCCESS: 0, "2BIG": 1, ACCES: 2, ADDRINUSE: 3, ADDRNOTAVAIL: 4, AFNOSUPPORT: 5, AGAIN: 6,
  ALREADY: 7, BADF: 8, BADMSG: 9, BUSY: 10, CANCELED: 11, CHILD: 12, CONNABORTED: 13,
  CONNREFUSED: 14, CONNRESET: 15, DEADLK: 16, DESTADDRREQ: 17, DOM: 18, DQUOT: 19, EXIST: 20,
  FAULT: 21, FBIG: 22, HOSTUNREACH: 23, IDRM: 24, ILSEQ: 25, INPROGRESS: 26, INTR: 27,
  INVAL: 28, IO: 29, ISCONN: 30, ISDIR: 31, LOOP: 32, MFILE: 33, MLINK: 34, MSGSIZE: 35,
  MULTIHOP: 36, NAMETOOLONG: 37, NETDOWN: 38, NETRESET: 39, NETUNREACH: 40, NFILE: 41,
  NOBUFS: 42, NODEV: 43, NOENT: 44, NOEXEC: 45, NOLCK: 46, NOLINK: 47, NOMEM: 48, NOMSG: 49,
  NOPROTOOPT: 50, NOSPC: 51, NOSYS: 52, NOTCONN: 53, NOTDIR: 54, NOTEMPTY: 55,
  NOTRECOVERABLE: 56, NOTSOCK: 57, NOTSUP: 58, NOTTY: 59, NXIO: 60, OVERFLOW: 61,
  OWNERDEAD: 62, PERM: 63, PIPE: 64, PROTO: 65, PROTONOSUPPORT: 66, PROTOTYPE: 67, RANGE: 68,
  ROFS: 69, SPIPE: 70, SRCH: 71, STALE: 72, TIMEDOUT: 73, TXTBSY: 74, XDEV: 75,
  NOTCAPABLE: 76,
};
const E = ERRNO;

const FILETYPE = { UNKNOWN: 0, CHARACTER_DEVICE: 2, DIRECTORY: 3, REGULAR_FILE: 4 };

const R = (bit) => 1n << BigInt(bit);
const RIGHT = {
  FD_DATASYNC: R(0), FD_READ: R(1), FD_SEEK: R(2), FD_FDSTAT_SET_FLAGS: R(3), FD_SYNC: R(4),
  FD_TELL: R(5), FD_WRITE: R(6), FD_ADVISE: R(7), FD_ALLOCATE: R(8),
  PATH_CREATE_DIRECTORY: R(9), PATH_CREATE_FILE: R(10), PATH_LINK_SOURCE: R(11),
  PATH_LINK_TARGET: R(12), PATH_OPEN: R(13), FD_READDIR: R(14), PATH_READLINK: R(15),
  PATH_RENAME_SOURCE: R(16), PATH_RENAME_TARGET: R(17), PATH_FILESTAT_GET: R(18),
  PATH_FILESTAT_SET_SIZE: R(19), PATH_FILESTAT_SET_TIMES: R(20), FD_FILESTAT_GET: R(21),
  FD_FILESTAT_SET_SIZE: R(22), FD_FILESTAT_SET_TIMES: R(23), PATH_SYMLINK: R(24),
  PATH_REMOVE_DIRECTORY: R(25), PATH_UNLINK_FILE: R(26), POLL_FD_READWRITE: R(27),
  SOCK_SHUTDOWN: R(28), SOCK_ACCEPT: R(29),
};
// The rights that would let a guest change something. None are ever granted.
const WRITE_RIGHTS = RIGHT.FD_DATASYNC | RIGHT.FD_WRITE | RIGHT.FD_ALLOCATE | RIGHT.FD_SYNC |
  RIGHT.PATH_CREATE_DIRECTORY | RIGHT.PATH_CREATE_FILE | RIGHT.PATH_LINK_SOURCE |
  RIGHT.PATH_LINK_TARGET | RIGHT.PATH_RENAME_SOURCE | RIGHT.PATH_RENAME_TARGET |
  RIGHT.PATH_FILESTAT_SET_SIZE | RIGHT.PATH_FILESTAT_SET_TIMES | RIGHT.FD_FILESTAT_SET_SIZE |
  RIGHT.FD_FILESTAT_SET_TIMES | RIGHT.PATH_SYMLINK | RIGHT.PATH_REMOVE_DIRECTORY |
  RIGHT.PATH_UNLINK_FILE;
const FILE_RIGHTS = RIGHT.FD_READ | RIGHT.FD_SEEK | RIGHT.FD_TELL | RIGHT.FD_ADVISE |
  RIGHT.FD_FDSTAT_SET_FLAGS | RIGHT.FD_FILESTAT_GET | RIGHT.POLL_FD_READWRITE;
const DIR_RIGHTS = RIGHT.PATH_OPEN | RIGHT.FD_READDIR | RIGHT.PATH_READLINK |
  RIGHT.PATH_FILESTAT_GET | RIGHT.FD_FILESTAT_GET | RIGHT.FD_FDSTAT_SET_FLAGS;
const STDIN_RIGHTS = RIGHT.FD_READ | RIGHT.FD_FDSTAT_SET_FLAGS | RIGHT.FD_FILESTAT_GET |
  RIGHT.POLL_FD_READWRITE;
const STDOUT_RIGHTS = RIGHT.FD_WRITE | RIGHT.FD_FDSTAT_SET_FLAGS | RIGHT.FD_FILESTAT_GET |
  RIGHT.POLL_FD_READWRITE;

const OFLAGS = { CREAT: 1, DIRECTORY: 2, EXCL: 4, TRUNC: 8 };
const FDFLAGS = { APPEND: 1, DSYNC: 2, NONBLOCK: 4, RSYNC: 8, SYNC: 16 };
const FDFLAGS_ALL = 31;
const FSTFLAGS = { ATIM: 1, ATIM_NOW: 2, MTIM: 4, MTIM_NOW: 8 };
const CLOCK = { REALTIME: 0, MONOTONIC: 1, PROCESS_CPUTIME_ID: 2, THREAD_CPUTIME_ID: 3 };
const EVENTTYPE = { CLOCK: 0, FD_READ: 1, FD_WRITE: 2 };
const SUBCLOCKFLAGS_ABSTIME = 1;
const MAX_U32 = 0xffffffff;

// Thrown inside an implementation to return an errno.
class Errno {
  constructor(code) { this.code = code; }
}
const fail = (code) => { throw new Errno(code); };

export function wasiP1(getMemory, options = {}) {
  const { log = console, files = {}, args = [], env = {}, suspend: suspendOpt } = options;
  const canSuspend = typeof WebAssembly.Suspending === "function";
  const suspend = (suspendOpt ?? canSuspend) && canSuspend;
  const encoder = new TextEncoder();
  const argBytes = args.map((a) => encoder.encode(`${a}\0`));
  const envBytes = Object.entries(env).map(([k, v]) => encoder.encode(`${k}=${v}\0`));

  // Views are made per call: memory.grow() detaches the old buffer.
  const mem = () => {
    const m = typeof getMemory === "function" ? getMemory() : getMemory;
    const buffer = m.buffer;
    return { u8: new Uint8Array(buffer), dv: new DataView(buffer) };
  };

  // Clocks. In Workers, Date.now() and performance.now() only advance across I/O.
  let lastMonotonic = 0n;
  const realtime = () => BigInt(Date.now()) * 1_000_000n;
  const monotonic = () => {
    const now = BigInt(Math.floor(performance.now() * 1e6));
    if (now > lastMonotonic) lastMonotonic = now;
    return lastMonotonic;
  };
  const clockNow = (id) => {
    switch (id) {
      case CLOCK.REALTIME: return realtime();
      // There is no CPU-time clock in Workers. Elapsed time is the closest honest
      // answer, and wasi-libc's clock() and times() emulation reads these.
      case CLOCK.MONOTONIC: case CLOCK.PROCESS_CPUTIME_ID: case CLOCK.THREAD_CPUTIME_ID:
        return monotonic();
      default: return null;
    }
  };

  // The read-only filesystem, built from `files`.
  let nextIno = 1n;
  const now = realtime();
  const makeDir = (parent) => {
    const dir = { type: "dir", ino: nextIno++, children: new Map(), parent: null };
    dir.parent = parent ?? dir;
    return dir;
  };
  const root = makeDir(null);
  for (const [path, data] of Object.entries(files)) {
    const parts = path.split("/").filter((p) => p && p !== ".");
    if (!parts.length || parts.includes("..")) throw new TypeError(`wasi: bad file path ${path}`);
    let dir = root;
    for (const part of parts.slice(0, -1)) {
      let next = dir.children.get(part);
      if (!next) { next = makeDir(dir); dir.children.set(part, next); }
      if (next.type !== "dir") throw new TypeError(`wasi: ${path} is under a file`);
      dir = next;
    }
    const name = parts[parts.length - 1];
    if (dir.children.has(name)) throw new TypeError(`wasi: ${path} is given twice`);
    const bytes = data instanceof Uint8Array ? data
      : typeof data === "string" ? encoder.encode(data) : new Uint8Array(data);
    dir.children.set(name, { type: "file", ino: nextIno++, data: bytes });
  }

  // Line-buffered console output for fd 1 and 2.
  const decoders = { 1: new TextDecoder(), 2: new TextDecoder() };
  const pending = { 1: "", 2: "" };
  const emit = (fd, line) => (fd === 2 ? log.error : log.log).call(log, line);
  const writeConsole = (fd, bytes) => {
    let text = pending[fd] + decoders[fd].decode(bytes, { stream: true });
    let nl;
    while ((nl = text.indexOf("\n")) >= 0) {
      emit(fd, text.slice(0, nl));
      text = text.slice(nl + 1);
    }
    // A guest that never writes a newline still gets its output out.
    if (text.length > 65536) { emit(fd, text); text = ""; }
    pending[fd] = text;
  };
  const flush = () => {
    for (const fd of [1, 2]) {
      const text = pending[fd] + decoders[fd].decode();
      pending[fd] = "";
      if (text) emit(fd, text);
    }
  };

  // The descriptor table.
  const fds = new Map();
  const stdio = (n, rights) => ({ kind: "stdio", n, rights, inheriting: 0n, flags: 0 });
  fds.set(0, stdio(0, STDIN_RIGHTS));
  fds.set(1, stdio(1, STDOUT_RIGHTS));
  fds.set(2, stdio(2, STDOUT_RIGHTS));
  if (root.children.size) {
    fds.set(3, { kind: "dir", node: root, preopen: "/", rights: DIR_RIGHTS,
      inheriting: DIR_RIGHTS | FILE_RIGHTS, flags: 0, cookie: 0n });
  }
  let nextFd = fds.size;
  const allocFd = (entry) => {
    while (fds.has(nextFd)) nextFd++;
    fds.set(nextFd, entry);
    return nextFd++;
  };
  const getFd = (fd) => fds.get(fd) ?? fail(E.BADF);
  const need = (entry, right) => { if (!(entry.rights & right)) fail(E.NOTCAPABLE); };

  const filetypeOf = (entry) =>
    entry.kind === "stdio" ? FILETYPE.CHARACTER_DEVICE
      : entry.node.type === "dir" ? FILETYPE.DIRECTORY : FILETYPE.REGULAR_FILE;

  const writeFilestat = (dv, ptr, node, filetype) => {
    dv.setBigUint64(ptr, 1n, true); // dev
    dv.setBigUint64(ptr + 8, node ? node.ino : 0n, true);
    dv.setUint8(ptr + 16, filetype);
    for (let i = 17; i < 24; i++) dv.setUint8(ptr + i, 0);
    dv.setBigUint64(ptr + 24, 1n, true); // nlink
    dv.setBigUint64(ptr + 32, node?.type === "file" ? BigInt(node.data.length) : 0n, true);
    dv.setBigUint64(ptr + 40, node ? now : 0n, true);
    dv.setBigUint64(ptr + 48, node ? now : 0n, true);
    dv.setBigUint64(ptr + 56, node ? now : 0n, true);
  };

  const readString = (u8, ptr, len) => new TextDecoder("utf-8", { fatal: true }).decode(u8.subarray(ptr, ptr + len));

  // Resolves `path` under directory fd `dirFd`. Returns { node, parent, name, trailingSlash }.
  // `node` is undefined when only the last component is missing.
  const resolve = (dirFd, u8, ptr, len) => {
    const dir = getFd(dirFd);
    if (dir.kind !== "dir") fail(dir.kind === "stdio" ? E.NOTDIR : E.NOTDIR);
    let path;
    try { path = readString(u8, ptr, len); } catch { fail(E.ILSEQ); }
    if (path.includes("\0")) fail(E.INVAL);
    if (path === "") fail(E.NOENT);
    if (path.startsWith("/")) fail(E.NOTCAPABLE);
    const trailingSlash = path.endsWith("/");
    const parts = path.split("/").filter((p) => p !== "");
    // Walk from the fd's directory, keeping the stack so ".." can't leave it.
    const stack = [dir.node];
    let parent = dir.node, name = ".";
    for (let i = 0; i < parts.length; i++) {
      const part = parts[i];
      const last = i === parts.length - 1;
      const cur = stack[stack.length - 1];
      if (cur.type !== "dir") fail(E.NOTDIR);
      if (part === ".") { if (last) { parent = cur; name = "."; } continue; }
      if (part === "..") {
        if (stack.length === 1) fail(E.NOTCAPABLE);
        stack.pop();
        if (last) { parent = stack[stack.length - 1]; name = ".."; }
        continue;
      }
      if (part.length > 255) fail(E.NAMETOOLONG);
      const child = cur.children.get(part);
      if (last) return { node: child, parent: cur, name: part, trailingSlash };
      if (!child) fail(E.NOENT);
      stack.push(child);
    }
    return { node: stack[stack.length - 1], parent, name, trailingSlash };
  };
  const existing = (dirFd, u8, ptr, len) => {
    const r = resolve(dirFd, u8, ptr, len);
    if (!r.node) fail(E.NOENT);
    if (r.trailingSlash && r.node.type !== "dir") fail(E.NOTDIR);
    return r;
  };
  // Any change to the filesystem: report a missing path first, then EROFS.
  const readOnly = (dirFd, u8, ptr, len) => {
    existing(dirFd, u8, ptr, len);
    fail(E.ROFS);
  };

  // Reads the iovec array into a list of [ptr, len].
  const iovecs = (dv, ptr, count) => {
    const list = [];
    for (let i = 0; i < count; i++) {
      list.push([dv.getUint32(ptr + i * 8, true), dv.getUint32(ptr + i * 8 + 4, true)]);
    }
    return list;
  };
  const readInto = (u8, dv, data, pos, iovs, iovsLen) => {
    let total = 0;
    for (const [p, l] of iovecs(dv, iovs, iovsLen)) {
      if (pos >= data.length) break;
      const chunk = data.subarray(pos, Math.min(pos + l, data.length));
      u8.set(chunk, p);
      pos += chunk.length;
      total += chunk.length;
      if (chunk.length < l) break;
    }
    return total;
  };
  const toPos = (big) => (big > BigInt(Number.MAX_SAFE_INTEGER) ? Number.MAX_SAFE_INTEGER : Number(big));

  const handlers = {
    args_get(argv, buf) {
      const { u8, dv } = mem();
      for (const [i, bytes] of argBytes.entries()) {
        dv.setUint32(argv + i * 4, buf, true);
        u8.set(bytes, buf);
        buf += bytes.length;
      }
    },
    args_sizes_get(countPtr, sizePtr) {
      const { dv } = mem();
      dv.setUint32(countPtr, argBytes.length, true);
      dv.setUint32(sizePtr, argBytes.reduce((n, b) => n + b.length, 0), true);
    },
    environ_get(environ, buf) {
      const { u8, dv } = mem();
      for (const [i, bytes] of envBytes.entries()) {
        dv.setUint32(environ + i * 4, buf, true);
        u8.set(bytes, buf);
        buf += bytes.length;
      }
    },
    environ_sizes_get(countPtr, sizePtr) {
      const { dv } = mem();
      dv.setUint32(countPtr, envBytes.length, true);
      dv.setUint32(sizePtr, envBytes.reduce((n, b) => n + b.length, 0), true);
    },

    clock_res_get(id, out) {
      if (clockNow(id) === null) fail(E.INVAL);
      // Workers clocks tick in milliseconds.
      mem().dv.setBigUint64(out, 1_000_000n, true);
    },
    clock_time_get(id, _precision, out) {
      const t = clockNow(id);
      if (t === null) fail(E.INVAL);
      mem().dv.setBigUint64(out, t, true);
    },

    fd_advise(fd, _offset, _len, advice) {
      const entry = getFd(fd);
      if (advice > 5) fail(E.INVAL);
      if (entry.kind === "stdio") fail(E.SPIPE);
      if (entry.node.type === "dir") fail(E.BADF);
      need(entry, RIGHT.FD_ADVISE);
    },
    fd_allocate(fd) {
      const entry = getFd(fd);
      if (entry.kind === "stdio") fail(E.SPIPE);
      if (entry.node.type === "dir") fail(E.BADF);
      fail(E.BADF); // no descriptor is ever writable
    },
    fd_close(fd) {
      getFd(fd);
      fds.delete(fd);
      if (fd < nextFd) nextFd = fd;
    },
    fd_datasync(fd) {
      const entry = getFd(fd);
      if (entry.kind === "stdio") fail(E.INVAL);
      // Nothing is ever written, so there is nothing to sync.
    },
    fd_fdstat_get(fd, out) {
      const entry = getFd(fd);
      const { dv } = mem();
      dv.setUint8(out, filetypeOf(entry));
      dv.setUint8(out + 1, 0);
      dv.setUint16(out + 2, entry.flags, true);
      dv.setUint32(out + 4, 0, true);
      dv.setBigUint64(out + 8, entry.rights, true);
      dv.setBigUint64(out + 16, entry.inheriting, true);
    },
    fd_fdstat_set_flags(fd, flags) {
      const entry = getFd(fd);
      if (flags & ~FDFLAGS_ALL) fail(E.INVAL);
      need(entry, RIGHT.FD_FDSTAT_SET_FLAGS);
      // Stdio writes never block, so NONBLOCK and APPEND describe it already.
      // On read-only files and directories only NONBLOCK means anything.
      const allowed = entry.kind === "stdio" ? FDFLAGS.NONBLOCK | FDFLAGS.APPEND : FDFLAGS.NONBLOCK;
      if (flags & ~allowed) fail(entry.kind === "stdio" ? E.NOTSUP : E.ROFS);
      entry.flags = flags;
    },
    fd_fdstat_set_rights(fd, base, inheriting) {
      const entry = getFd(fd);
      if ((base & ~entry.rights) || (inheriting & ~entry.inheriting)) fail(E.NOTCAPABLE);
      entry.rights = base;
      entry.inheriting = inheriting;
    },
    fd_filestat_get(fd, out) {
      const entry = getFd(fd);
      if (entry.kind !== "stdio") need(entry, RIGHT.FD_FILESTAT_GET);
      writeFilestat(mem().dv, out, entry.kind === "stdio" ? null : entry.node, filetypeOf(entry));
    },
    fd_filestat_set_size(fd) {
      const entry = getFd(fd);
      if (entry.kind === "stdio") fail(E.INVAL);
      if (entry.node.type === "dir") fail(E.ISDIR);
      fail(E.BADF); // not open for writing
    },
    fd_filestat_set_times(fd, _atim, _mtim, fstflags) {
      const entry = getFd(fd);
      if (fstflags & ~15) fail(E.INVAL);
      if ((fstflags & FSTFLAGS.ATIM && fstflags & FSTFLAGS.ATIM_NOW) ||
          (fstflags & FSTFLAGS.MTIM && fstflags & FSTFLAGS.MTIM_NOW)) fail(E.INVAL);
      if (entry.kind === "stdio") fail(E.NOTSUP);
      fail(E.ROFS);
    },
    fd_pread(fd, iovs, iovsLen, offset, nread) {
      const entry = getFd(fd);
      if (entry.kind === "stdio") fail(E.SPIPE);
      if (entry.node.type === "dir") fail(E.ISDIR);
      need(entry, RIGHT.FD_READ | RIGHT.FD_SEEK);
      const { u8, dv } = mem();
      dv.setUint32(nread, readInto(u8, dv, entry.node.data, toPos(offset), iovs, iovsLen), true);
    },
    fd_prestat_get(fd, out) {
      const entry = fds.get(fd);
      if (!entry || !entry.preopen) fail(E.BADF);
      const { dv } = mem();
      dv.setUint32(out, 0, true); // tag dir, padding
      dv.setUint32(out + 4, encoder.encode(entry.preopen).length, true);
    },
    fd_prestat_dir_name(fd, path, len) {
      const entry = fds.get(fd);
      if (!entry || !entry.preopen) fail(E.BADF);
      const name = encoder.encode(entry.preopen);
      if (len < name.length) fail(E.NAMETOOLONG);
      mem().u8.set(name, path);
    },
    fd_pwrite(fd) {
      const entry = getFd(fd);
      if (entry.kind === "stdio") fail(E.SPIPE);
      if (entry.node.type === "dir") fail(E.ISDIR);
      fail(E.BADF);
    },
    fd_read(fd, iovs, iovsLen, nread) {
      const entry = getFd(fd);
      const { u8, dv } = mem();
      if (entry.kind === "stdio") {
        if (entry.n !== 0) fail(E.BADF);
        dv.setUint32(nread, 0, true); // stdin is always at EOF
        return;
      }
      if (entry.node.type === "dir") fail(E.ISDIR);
      need(entry, RIGHT.FD_READ);
      const n = readInto(u8, dv, entry.node.data, entry.pos, iovs, iovsLen);
      entry.pos += n;
      dv.setUint32(nread, n, true);
    },
    fd_readdir(fd, buf, bufLen, cookie, bufused) {
      const entry = getFd(fd);
      if (entry.kind !== "dir") fail(entry.kind === "stdio" ? E.NOTDIR : E.NOTDIR);
      need(entry, RIGHT.FD_READDIR);
      const dir = entry.node;
      const list = [[".", dir], ["..", dir.parent],
        ...[...dir.children].sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0))];
      const { u8, dv } = mem();
      let used = 0;
      for (let i = Number(cookie); i < list.length && used < bufLen; i++) {
        const [name, node] = list[i];
        const nameBytes = encoder.encode(name);
        const record = new Uint8Array(24 + nameBytes.length);
        const rv = new DataView(record.buffer);
        rv.setBigUint64(0, BigInt(i + 1), true);
        rv.setBigUint64(8, node.ino, true);
        rv.setUint32(16, nameBytes.length, true);
        rv.setUint8(20, node.type === "dir" ? FILETYPE.DIRECTORY : FILETYPE.REGULAR_FILE);
        record.set(nameBytes, 24);
        // The last record may be cut short; the guest sees bufused == bufLen and retries.
        const take = Math.min(record.length, bufLen - used);
        u8.set(record.subarray(0, take), buf + used);
        used += take;
      }
      dv.setUint32(bufused, used, true);
    },
    fd_renumber(from, to) {
      const entry = getFd(from);
      getFd(to);
      fds.set(to, entry);
      fds.delete(from);
      if (from < nextFd) nextFd = from;
    },
    fd_seek(fd, offset, whence, out) {
      const entry = getFd(fd);
      if (entry.kind === "stdio") fail(E.SPIPE);
      if (entry.node.type === "dir") fail(E.ISDIR);
      // A seek that only reports the position needs FD_TELL or FD_SEEK.
      need(entry, offset === 0n && whence === 1 ? RIGHT.FD_TELL | RIGHT.FD_SEEK : RIGHT.FD_SEEK);
      const base = whence === 0 ? 0n : whence === 1 ? BigInt(entry.pos)
        : whence === 2 ? BigInt(entry.node.data.length) : fail(E.INVAL);
      const pos = base + offset;
      if (pos < 0n) fail(E.INVAL);
      if (pos > BigInt(Number.MAX_SAFE_INTEGER)) fail(E.OVERFLOW);
      entry.pos = Number(pos);
      mem().dv.setBigUint64(out, pos, true);
    },
    fd_sync(fd) {
      const entry = getFd(fd);
      if (entry.kind === "stdio") fail(E.INVAL);
    },
    fd_tell(fd, out) {
      const entry = getFd(fd);
      if (entry.kind === "stdio") fail(E.SPIPE);
      if (entry.node.type === "dir") fail(E.ISDIR);
      need(entry, RIGHT.FD_TELL);
      mem().dv.setBigUint64(out, BigInt(entry.pos), true);
    },
    fd_write(fd, iovs, iovsLen, nwritten) {
      const entry = getFd(fd);
      if (entry.kind === "stdio") {
        if (entry.n === 0) fail(E.BADF);
        const { u8, dv } = mem();
        let total = 0;
        for (const [p, l] of iovecs(dv, iovs, iovsLen)) {
          writeConsole(entry.n, u8.subarray(p, p + l));
          total += l;
        }
        dv.setUint32(nwritten, total, true);
        return;
      }
      if (entry.node.type === "dir") fail(E.ISDIR);
      fail(E.BADF); // files are opened read-only
    },

    path_create_directory(fd, path, len) {
      const r = resolve(fd, mem().u8, path, len);
      if (r.node) fail(E.EXIST);
      fail(E.ROFS);
    },
    path_filestat_get(fd, _flags, path, len, out) {
      const { u8, dv } = mem();
      need(getFd(fd), RIGHT.PATH_FILESTAT_GET);
      const { node } = existing(fd, u8, path, len);
      writeFilestat(dv, out, node, node.type === "dir" ? FILETYPE.DIRECTORY : FILETYPE.REGULAR_FILE);
    },
    path_filestat_set_times(fd, _flags, path, len, _atim, _mtim, fstflags) {
      if (fstflags & ~15) fail(E.INVAL);
      if ((fstflags & FSTFLAGS.ATIM && fstflags & FSTFLAGS.ATIM_NOW) ||
          (fstflags & FSTFLAGS.MTIM && fstflags & FSTFLAGS.MTIM_NOW)) fail(E.INVAL);
      readOnly(fd, mem().u8, path, len);
    },
    path_link(oldFd, _flags, oldPath, oldLen, newFd, newPath, newLen) {
      const u8 = mem().u8;
      existing(oldFd, u8, oldPath, oldLen);
      const r = resolve(newFd, u8, newPath, newLen);
      if (r.node) fail(E.EXIST);
      fail(E.ROFS);
    },
    path_open(fd, _dirflags, path, len, oflags, rightsBase, rightsInheriting, fdflags, out) {
      const dirEntry = getFd(fd);
      if (dirEntry.kind !== "dir") fail(E.NOTDIR);
      need(dirEntry, RIGHT.PATH_OPEN);
      const { u8, dv } = mem();
      const r = resolve(fd, u8, path, len);
      if (!r.node) {
        if (oflags & OFLAGS.CREAT) fail(E.ROFS);
        fail(E.NOENT);
      }
      if (oflags & OFLAGS.CREAT && oflags & OFLAGS.EXCL) fail(E.EXIST);
      const node = r.node;
      if (r.trailingSlash && node.type !== "dir") fail(E.NOTDIR);
      if (oflags & OFLAGS.DIRECTORY && node.type !== "dir") fail(E.NOTDIR);
      // Requested rights are a ceiling, not intent: guests ask for FD_FILESTAT_SET_SIZE
      // on read-only opens. Only FD_WRITE, TRUNC or a write fdflag means writing.
      const wantsWrite = rightsBase & RIGHT.FD_WRITE || oflags & OFLAGS.TRUNC ||
        fdflags & (FDFLAGS.APPEND | FDFLAGS.DSYNC | FDFLAGS.RSYNC | FDFLAGS.SYNC);
      if (node.type === "dir") {
        if (oflags & OFLAGS.TRUNC) fail(E.ISDIR);
        if (rightsBase & RIGHT.FD_WRITE) fail(E.ISDIR);
      }
      if (wantsWrite) fail(E.ROFS);
      const allowed = node.type === "dir" ? DIR_RIGHTS : FILE_RIGHTS;
      const entry = {
        kind: node.type === "dir" ? "dir" : "file", node, preopen: null,
        rights: rightsBase & allowed & dirEntry.inheriting,
        inheriting: node.type === "dir" ? rightsInheriting & (DIR_RIGHTS | FILE_RIGHTS) & dirEntry.inheriting : 0n,
        flags: fdflags & FDFLAGS.NONBLOCK, pos: 0,
      };
      dv.setUint32(out, allocFd(entry), true);
    },
    path_readlink(fd, path, len, _buf, _bufLen, _used) {
      existing(fd, mem().u8, path, len);
      fail(E.INVAL); // there are no symlinks
    },
    path_remove_directory(fd, path, len) {
      const r = resolve(fd, mem().u8, path, len);
      if (!r.node) fail(E.NOENT);
      if (r.node.type !== "dir") fail(E.NOTDIR);
      fail(E.ROFS);
    },
    path_rename(fd, oldPath, oldLen, newFd, newPath, newLen) {
      const u8 = mem().u8;
      existing(fd, u8, oldPath, oldLen);
      resolve(newFd, u8, newPath, newLen);
      fail(E.ROFS);
    },
    path_symlink(oldPath, oldLen, fd, newPath, newLen) {
      const r = resolve(fd, mem().u8, newPath, newLen);
      if (r.node) fail(E.EXIST);
      fail(E.ROFS);
    },
    path_unlink_file(fd, path, len) {
      const r = resolve(fd, mem().u8, path, len);
      if (!r.node) fail(E.NOENT);
      if (r.node.type === "dir") fail(E.ISDIR);
      if (r.trailingSlash) fail(E.NOTDIR);
      fail(E.ROFS);
    },

    poll_oneoff(inPtr, outPtr, nsubs, neventsPtr) {
      if (nsubs === 0) fail(E.INVAL);
      const { dv } = mem();
      const subs = [];
      for (let i = 0; i < nsubs; i++) {
        const p = inPtr + i * 48;
        const userdata = dv.getBigUint64(p, true);
        const tag = dv.getUint8(p + 8);
        if (tag === EVENTTYPE.CLOCK) {
          const id = dv.getUint32(p + 16, true);
          const timeout = dv.getBigUint64(p + 24, true);
          const flags = dv.getUint16(p + 40, true);
          const nowT = clockNow(id);
          if (nowT === null) { subs.push({ userdata, tag, error: E.INVAL, ready: true }); continue; }
          const deadline = flags & SUBCLOCKFLAGS_ABSTIME ? timeout : nowT + timeout;
          const wait = deadline > nowT ? deadline - nowT : 0n;
          subs.push({ userdata, tag, clock: id, wait, error: 0, ready: wait === 0n });
        } else if (tag === EVENTTYPE.FD_READ || tag === EVENTTYPE.FD_WRITE) {
          const fd = dv.getUint32(p + 16, true);
          const entry = fds.get(fd);
          let error = 0, nbytes = 0n;
          if (!entry) error = E.BADF;
          else if (entry.kind === "stdio") {
            if ((tag === EVENTTYPE.FD_READ) !== (entry.n === 0)) error = E.BADF;
          } else if (entry.node.type === "dir") error = E.BADF;
          else if (tag === EVENTTYPE.FD_WRITE) error = E.BADF;
          else nbytes = BigInt(Math.max(0, entry.node.data.length - entry.pos));
          // stdin at EOF, stdout/stderr and files never block.
          subs.push({ userdata, tag, fd, error, nbytes, ready: true });
        } else {
          fail(E.INVAL);
        }
      }
      const finish = (fired) => {
        const { dv: out } = mem();
        let n = 0;
        for (const s of fired) {
          const p = outPtr + n * 32;
          out.setBigUint64(p, s.userdata, true);
          out.setUint16(p + 8, s.error, true);
          out.setUint8(p + 10, s.tag);
          for (let i = 11; i < 16; i++) out.setUint8(p + i, 0);
          out.setBigUint64(p + 16, s.tag === EVENTTYPE.CLOCK ? 0n : s.nbytes ?? 0n, true);
          // FD_READWRITE_HANGUP for stdin at EOF.
          out.setUint16(p + 24, s.tag === EVENTTYPE.FD_READ && fds.get(s.fd)?.n === 0 ? 1 : 0, true);
          for (let i = 26; i < 32; i++) out.setUint8(p + i, 0);
          n++;
        }
        out.setUint32(neventsPtr, n, true);
        return E.SUCCESS;
      };
      const ready = subs.filter((s) => s.ready);
      if (ready.length) return finish(ready);
      const minWait = subs.reduce((m, s) => (s.wait < m ? s.wait : m), subs[0].wait);
      if (!suspend) return finish(subs.filter((s) => s.wait === minWait));
      const ms = Number(minWait / 1_000_000n) + (minWait % 1_000_000n ? 1 : 0);
      return new Promise((done) => setTimeout(done, ms)).then(() => {
        // Every clock whose time has come fires, at least the earliest one.
        const elapsed = BigInt(ms) * 1_000_000n;
        return finish(subs.filter((s) => s.wait <= elapsed || s.wait === minWait));
      });
    },
    proc_exit(code) {
      flush();
      throw new WasiExit(code);
    },
    proc_raise(_sig) {
      fail(E.NOSYS);
    },
    sched_yield() {},
    random_get(buf, len) {
      const { u8 } = mem();
      for (let off = 0; off < len; off += 65536) {
        crypto.getRandomValues(u8.subarray(buf + off, buf + Math.min(off + 65536, len)));
      }
    },

    // There are no sockets: a valid descriptor is never one.
    sock_accept(fd) { getFd(fd); fail(E.NOTSOCK); },
    sock_recv(fd) { getFd(fd); fail(E.NOTSOCK); },
    sock_send(fd) { getFd(fd); fail(E.NOTSOCK); },
    sock_shutdown(fd) { getFd(fd); fail(E.NOTSOCK); },
  };

  // Each function returns an errno; thrown Errno values become that errno.
  const toErrno = (e) => {
    if (e instanceof Errno) return e.code;
    if (e instanceof RangeError) return E.FAULT; // a pointer outside linear memory
    throw e;
  };
  const imports = {};
  for (const [name, fn] of Object.entries(handlers)) {
    if (name === "poll_oneoff") {
      const poll = (...a) => {
        try {
          const r = fn(...a);
          return r instanceof Promise ? r.catch(toErrno) : r;
        } catch (e) { return toErrno(e); }
      };
      imports[name] = suspend ? new WebAssembly.Suspending(poll) : poll;
    } else if (name === "proc_exit") {
      imports[name] = fn;
    } else {
      imports[name] = (...a) => {
        try { return fn(...a) ?? E.SUCCESS; } catch (e) { return toErrno(e); }
      };
    }
  }
  // flush is not enumerable, so `{ ...wasiP1(...) }` is a plain import object.
  const result = { wasi_snapshot_preview1: imports };
  Object.defineProperty(result, "flush", { value: flush });
  return result;
}
