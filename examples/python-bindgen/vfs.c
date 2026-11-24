// An in-memory filesystem for the Python Worker, behind wasi-libc.
//
// `wasmtime wizer` gives pre-initialization real directories (the stdlib,
// the app, /site, /tmp, /session/metadata, and build inputs under /.build,
// which aren't kept), and wasi-libc keeps their preopened descriptors in its
// snapshotted preopen table. A Worker has no
// filesystem, so after the snapshot those descriptors would be EBADF. This
// file defines wasi-libc's `__imported_wasi_snapshot_preview1_*` filesystem
// functions, which the link then uses instead of the host's imports:
//
// - While pre-initializing, every call goes to the host.
// - `_cfvfs.add(path, data)`, called by _cf_runtime before the snapshot,
//   copies files (or, with data None, directories) into memory, read-only.
// - `cfvfs_activate()`, at the end of pre-initialization, gives each host
//   preopen an in-memory directory at the same path. From then on every
//   descriptor except stdin, stdout and stderr is served from memory.
//   /tmp is writable, as in Pyodide, and /dev holds null; everything else
//   is read-only (EROFS).
//
// There are no symlinks, hard links or permissions. Timestamps are the
// realtime clock at creation and on each write.

#define PY_SSIZE_T_CLEAN
#include <Python.h>

#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <wasi/api.h>

#define IMPORT(name) __attribute__((import_module("wasi_snapshot_preview1"), import_name(#name)))

// The host's functions, under other names.
IMPORT(fd_advise) int32_t host_fd_advise(int32_t, int64_t, int64_t, int32_t);
IMPORT(fd_allocate) int32_t host_fd_allocate(int32_t, int64_t, int64_t);
IMPORT(fd_close) int32_t host_fd_close(int32_t);
IMPORT(fd_datasync) int32_t host_fd_datasync(int32_t);
IMPORT(fd_fdstat_get) int32_t host_fd_fdstat_get(int32_t, int32_t);
IMPORT(fd_fdstat_set_flags) int32_t host_fd_fdstat_set_flags(int32_t, int32_t);
IMPORT(fd_fdstat_set_rights) int32_t host_fd_fdstat_set_rights(int32_t, int64_t, int64_t);
IMPORT(fd_filestat_get) int32_t host_fd_filestat_get(int32_t, int32_t);
IMPORT(fd_filestat_set_size) int32_t host_fd_filestat_set_size(int32_t, int64_t);
IMPORT(fd_filestat_set_times) int32_t host_fd_filestat_set_times(int32_t, int64_t, int64_t, int32_t);
IMPORT(fd_pread) int32_t host_fd_pread(int32_t, int32_t, int32_t, int64_t, int32_t);
IMPORT(fd_prestat_get) int32_t host_fd_prestat_get(int32_t, int32_t);
IMPORT(fd_prestat_dir_name) int32_t host_fd_prestat_dir_name(int32_t, int32_t, int32_t);
IMPORT(fd_pwrite) int32_t host_fd_pwrite(int32_t, int32_t, int32_t, int64_t, int32_t);
IMPORT(fd_read) int32_t host_fd_read(int32_t, int32_t, int32_t, int32_t);
IMPORT(fd_readdir) int32_t host_fd_readdir(int32_t, int32_t, int32_t, int64_t, int32_t);
IMPORT(fd_renumber) int32_t host_fd_renumber(int32_t, int32_t);
IMPORT(fd_seek) int32_t host_fd_seek(int32_t, int64_t, int32_t, int32_t);
IMPORT(fd_sync) int32_t host_fd_sync(int32_t);
IMPORT(fd_tell) int32_t host_fd_tell(int32_t, int32_t);
IMPORT(fd_write) int32_t host_fd_write(int32_t, int32_t, int32_t, int32_t);
IMPORT(path_create_directory) int32_t host_path_create_directory(int32_t, int32_t, int32_t);
IMPORT(path_filestat_get) int32_t host_path_filestat_get(int32_t, int32_t, int32_t, int32_t, int32_t);
IMPORT(path_filestat_set_times) int32_t host_path_filestat_set_times(int32_t, int32_t, int32_t, int32_t, int64_t, int64_t, int32_t);
IMPORT(path_link) int32_t host_path_link(int32_t, int32_t, int32_t, int32_t, int32_t, int32_t, int32_t);
IMPORT(path_open) int32_t host_path_open(int32_t, int32_t, int32_t, int32_t, int32_t, int64_t, int64_t, int32_t, int32_t);
IMPORT(path_readlink) int32_t host_path_readlink(int32_t, int32_t, int32_t, int32_t, int32_t, int32_t);
IMPORT(path_remove_directory) int32_t host_path_remove_directory(int32_t, int32_t, int32_t);
IMPORT(path_rename) int32_t host_path_rename(int32_t, int32_t, int32_t, int32_t, int32_t, int32_t);
IMPORT(path_symlink) int32_t host_path_symlink(int32_t, int32_t, int32_t, int32_t, int32_t);
IMPORT(path_unlink_file) int32_t host_path_unlink_file(int32_t, int32_t, int32_t);
IMPORT(clock_time_get) int32_t host_clock_time_get(int32_t, int64_t, int32_t);

typedef struct Node Node;
typedef struct {
  char *name;
  Node *node;
} Entry;
struct Node {
  uint8_t type;  // __WASI_FILETYPE_DIRECTORY, _REGULAR_FILE or _CHARACTER_DEVICE (/dev/null)
  uint8_t writable;
  uint64_t ino, mtim;
  uint32_t links;  // names plus open descriptors; freed at 0
  Node *parent;
  Entry *entries;  // directories
  size_t count, cap;
  uint8_t *data;  // files
  size_t size, alloc;
};

typedef struct {
  Node *node;
  uint64_t pos;
  uint16_t flags;
  char *preopen;
} Fd;

static int active;
static Node *root;
static uint64_t next_ino = 1;
static Fd *fds;
static size_t nfds;

#define RIGHTS_ALL ((uint64_t)0x3fffffff)

static uint64_t now(void) {
  uint64_t t = 0;
  host_clock_time_get(__WASI_CLOCKID_REALTIME, 1, (int32_t)(uintptr_t)&t);
  return t;
}

static Node *new_node(uint8_t type, Node *parent, int writable) {
  Node *n = calloc(1, sizeof(Node));
  if (!n) return NULL;
  n->type = type;
  n->writable = writable;
  n->ino = next_ino++;
  n->mtim = now();
  n->parent = parent ? parent : n;
  return n;
}

static void unref(Node *n) {
  if (--n->links) return;
  free(n->entries);
  free(n->data);
  free(n);
}

static Entry *find(Node *dir, const char *name, size_t len) {
  for (size_t i = 0; i < dir->count; i++) {
    if (strlen(dir->entries[i].name) == len && !memcmp(dir->entries[i].name, name, len)) return &dir->entries[i];
  }
  return NULL;
}

static int link_into(Node *dir, const char *name, size_t len, Node *n) {
  if (dir->count == dir->cap) {
    size_t cap = dir->cap ? dir->cap * 2 : 8;
    Entry *e = realloc(dir->entries, cap * sizeof(Entry));
    if (!e) return __WASI_ERRNO_NOMEM;
    dir->entries = e;
    dir->cap = cap;
  }
  char *copy = malloc(len + 1);
  if (!copy) return __WASI_ERRNO_NOMEM;
  memcpy(copy, name, len);
  copy[len] = 0;
  dir->entries[dir->count++] = (Entry){copy, n};
  n->parent = dir;
  n->links++;
  dir->mtim = now();
  return 0;
}

static void unlink_entry(Node *dir, Entry *e) {
  Node *n = e->node;
  free(e->name);
  *e = dir->entries[--dir->count];
  dir->mtim = now();
  unref(n);
}

// Splits `path` relative to `dir` into its directory and last component.
// `*last` is empty for a path naming `dir` itself (or ending in "/." etc.).
static int walk(Node *dir, const char *path, size_t len, Node **parent, const char **last, size_t *last_len) {
  if (len && path[0] == '/') return __WASI_ERRNO_NOTCAPABLE;
  Node *cur = dir;
  size_t i = 0;
  *last = path;
  *last_len = 0;
  while (i < len) {
    size_t j = i;
    while (j < len && path[j] != '/') j++;
    const char *c = path + i;
    size_t clen = j - i;
    size_t k = j;
    while (k < len && path[k] == '/') k++;
    int final = k == len;
    if (final && !(clen == 0 || (clen == 1 && c[0] == '.') || (clen == 2 && c[0] == '.' && c[1] == '.'))) {
      *last = c;
      *last_len = clen;
      break;
    }
    if (clen == 0 || (clen == 1 && c[0] == '.')) {
    } else if (clen == 2 && c[0] == '.' && c[1] == '.') {
      cur = cur->parent;
    } else {
      Entry *e = find(cur, c, clen);
      if (!e) return __WASI_ERRNO_NOENT;
      if (e->node->type != __WASI_FILETYPE_DIRECTORY) return __WASI_ERRNO_NOTDIR;
      cur = e->node;
    }
    i = k;
  }
  *parent = cur;
  return 0;
}

static int lookup(Node *dir, const char *path, size_t len, Node **out) {
  Node *parent;
  const char *last;
  size_t last_len;
  int err = walk(dir, path, len, &parent, &last, &last_len);
  if (err) return err;
  if (!last_len) {
    *out = parent;
    return 0;
  }
  Entry *e = find(parent, last, last_len);
  if (!e) return __WASI_ERRNO_NOENT;
  // "file/" names a directory.
  if (path[len - 1] == '/' && e->node->type != __WASI_FILETYPE_DIRECTORY) return __WASI_ERRNO_NOTDIR;
  *out = e->node;
  return 0;
}

static int32_t alloc_fd(Node *n, uint16_t flags) {
  size_t i = 3;
  while (i < nfds && fds[i].node) i++;
  if (i >= nfds) {
    size_t cap = nfds ? nfds * 2 : 16;
    Fd *f = realloc(fds, cap * sizeof(Fd));
    if (!f) return -1;
    memset(f + nfds, 0, (cap - nfds) * sizeof(Fd));
    fds = f;
    nfds = cap;
  }
  fds[i] = (Fd){n, 0, flags, NULL};
  n->links++;
  return (int32_t)i;
}

static Fd *get_fd(int32_t fd) { return fd >= 0 && (size_t)fd < nfds && fds[fd].node ? &fds[fd] : NULL; }

static Node *get_dir(int32_t fd, int *err) {
  Fd *f = get_fd(fd);
  if (!f) {
    *err = __WASI_ERRNO_BADF;
    return NULL;
  }
  if (f->node->type != __WASI_FILETYPE_DIRECTORY) {
    *err = __WASI_ERRNO_NOTDIR;
    return NULL;
  }
  return f->node;
}

static void put_filestat(void *buf, Node *n) {
  __wasi_filestat_t *st = buf;
  memset(st, 0, sizeof(*st));
  st->dev = 1;
  st->ino = n->ino;
  st->filetype = n->type;
  st->nlink = 1;
  st->size = n->type == __WASI_FILETYPE_DIRECTORY ? 4096 : n->size;
  st->atim = st->mtim = st->ctim = n->mtim;
}

static int reserve(Node *n, size_t size) {
  if (size <= n->alloc) return 0;
  size_t cap = n->alloc ? n->alloc : 256;
  while (cap < size) cap *= 2;
  uint8_t *d = realloc(n->data, cap);
  if (!d) return __WASI_ERRNO_NOMEM;
  n->data = d;
  n->alloc = cap;
  return 0;
}

static int resize(Node *n, size_t size) {
  int err = reserve(n, size);
  if (err) return err;
  if (size > n->size) memset(n->data + n->size, 0, size - n->size);
  n->size = size;
  n->mtim = now();
  return 0;
}

static int do_read(Node *n, const __wasi_iovec_t *iovs, size_t count, uint64_t pos, size_t *done) {
  if (n->type == __WASI_FILETYPE_DIRECTORY) return __WASI_ERRNO_ISDIR;
  if (n->type == __WASI_FILETYPE_CHARACTER_DEVICE) pos = n->size;
  size_t total = 0;
  for (size_t i = 0; i < count; i++) {
    if (pos >= n->size) break;
    size_t m = n->size - pos < iovs[i].buf_len ? n->size - pos : iovs[i].buf_len;
    memcpy(iovs[i].buf, n->data + pos, m);
    pos += m;
    total += m;
  }
  *done = total;
  return 0;
}

static int do_write(Node *n, const __wasi_ciovec_t *iovs, size_t count, uint64_t pos, size_t *done) {
  if (n->type == __WASI_FILETYPE_DIRECTORY) return __WASI_ERRNO_ISDIR;
  if (!n->writable) return __WASI_ERRNO_ROFS;
  size_t total = 0;
  for (size_t i = 0; i < count; i++) total += iovs[i].buf_len;
  if (n->type == __WASI_FILETYPE_CHARACTER_DEVICE) {
    *done = total;
    return 0;
  }
  if (pos + total > n->size) {
    int err = resize(n, pos + total);
    if (err) return err;
  }
  for (size_t i = 0; i < count; i++) {
    memcpy(n->data + pos, iovs[i].buf, iovs[i].buf_len);
    pos += iovs[i].buf_len;
  }
  n->mtim = now();
  *done = total;
  return 0;
}

#define P(x) ((void *)(uintptr_t)(x))
#define S(x) ((const char *)(uintptr_t)(x))
#define HOST(call) \
  if (!active || fd < 3) return host_##call

int32_t __imported_wasi_snapshot_preview1_fd_advise(int32_t fd, int64_t off, int64_t len, int32_t advice) {
  HOST(fd_advise(fd, off, len, advice));
  return get_fd(fd) ? 0 : __WASI_ERRNO_BADF;
}

int32_t __imported_wasi_snapshot_preview1_fd_allocate(int32_t fd, int64_t off, int64_t len) {
  HOST(fd_allocate(fd, off, len));
  Fd *f = get_fd(fd);
  if (!f) return __WASI_ERRNO_BADF;
  if (f->node->type != __WASI_FILETYPE_REGULAR_FILE) return __WASI_ERRNO_BADF;
  if (!f->node->writable) return __WASI_ERRNO_ROFS;
  return (uint64_t)(off + len) > f->node->size ? resize(f->node, off + len) : 0;
}

int32_t __imported_wasi_snapshot_preview1_fd_close(int32_t fd) {
  HOST(fd_close(fd));
  Fd *f = get_fd(fd);
  if (!f) return __WASI_ERRNO_BADF;
  Node *n = f->node;
  free(f->preopen);
  *f = (Fd){0};
  unref(n);
  return 0;
}

int32_t __imported_wasi_snapshot_preview1_fd_datasync(int32_t fd) {
  HOST(fd_datasync(fd));
  return get_fd(fd) ? 0 : __WASI_ERRNO_BADF;
}

int32_t __imported_wasi_snapshot_preview1_fd_sync(int32_t fd) {
  HOST(fd_sync(fd));
  return get_fd(fd) ? 0 : __WASI_ERRNO_BADF;
}

int32_t __imported_wasi_snapshot_preview1_fd_fdstat_get(int32_t fd, int32_t buf) {
  HOST(fd_fdstat_get(fd, buf));
  Fd *f = get_fd(fd);
  if (!f) return __WASI_ERRNO_BADF;
  __wasi_fdstat_t *st = P(buf);
  memset(st, 0, sizeof(*st));
  st->fs_filetype = f->node->type;
  st->fs_flags = f->flags;
  st->fs_rights_base = RIGHTS_ALL;
  st->fs_rights_inheriting = RIGHTS_ALL;
  return 0;
}

int32_t __imported_wasi_snapshot_preview1_fd_fdstat_set_flags(int32_t fd, int32_t flags) {
  HOST(fd_fdstat_set_flags(fd, flags));
  Fd *f = get_fd(fd);
  if (!f) return __WASI_ERRNO_BADF;
  f->flags = flags;
  return 0;
}

int32_t __imported_wasi_snapshot_preview1_fd_fdstat_set_rights(int32_t fd, int64_t base, int64_t inh) {
  HOST(fd_fdstat_set_rights(fd, base, inh));
  return get_fd(fd) ? 0 : __WASI_ERRNO_BADF;
}

int32_t __imported_wasi_snapshot_preview1_fd_filestat_get(int32_t fd, int32_t buf) {
  HOST(fd_filestat_get(fd, buf));
  Fd *f = get_fd(fd);
  if (!f) return __WASI_ERRNO_BADF;
  put_filestat(P(buf), f->node);
  return 0;
}

int32_t __imported_wasi_snapshot_preview1_fd_filestat_set_size(int32_t fd, int64_t size) {
  HOST(fd_filestat_set_size(fd, size));
  Fd *f = get_fd(fd);
  if (!f) return __WASI_ERRNO_BADF;
  if (f->node->type != __WASI_FILETYPE_REGULAR_FILE) return __WASI_ERRNO_INVAL;
  if (!f->node->writable) return __WASI_ERRNO_ROFS;
  return resize(f->node, size);
}

static int set_times(Node *n, int64_t atim, int64_t mtim, int32_t flags) {
  (void)atim;
  if (!n->writable) return __WASI_ERRNO_ROFS;
  if (flags & __WASI_FSTFLAGS_MTIM) n->mtim = mtim;
  else if (flags & __WASI_FSTFLAGS_MTIM_NOW) n->mtim = now();
  return 0;
}

int32_t __imported_wasi_snapshot_preview1_fd_filestat_set_times(int32_t fd, int64_t atim, int64_t mtim, int32_t flags) {
  HOST(fd_filestat_set_times(fd, atim, mtim, flags));
  Fd *f = get_fd(fd);
  return f ? set_times(f->node, atim, mtim, flags) : __WASI_ERRNO_BADF;
}

int32_t __imported_wasi_snapshot_preview1_fd_pread(int32_t fd, int32_t iovs, int32_t count, int64_t off, int32_t out) {
  HOST(fd_pread(fd, iovs, count, off, out));
  Fd *f = get_fd(fd);
  if (!f) return __WASI_ERRNO_BADF;
  size_t done;
  int err = do_read(f->node, P(iovs), count, off, &done);
  if (!err) *(uint32_t *)P(out) = done;
  return err;
}

int32_t __imported_wasi_snapshot_preview1_fd_pwrite(int32_t fd, int32_t iovs, int32_t count, int64_t off, int32_t out) {
  HOST(fd_pwrite(fd, iovs, count, off, out));
  Fd *f = get_fd(fd);
  if (!f) return __WASI_ERRNO_BADF;
  size_t done;
  int err = do_write(f->node, P(iovs), count, off, &done);
  if (!err) *(uint32_t *)P(out) = done;
  return err;
}

int32_t __imported_wasi_snapshot_preview1_fd_read(int32_t fd, int32_t iovs, int32_t count, int32_t out) {
  HOST(fd_read(fd, iovs, count, out));
  Fd *f = get_fd(fd);
  if (!f) return __WASI_ERRNO_BADF;
  size_t done;
  int err = do_read(f->node, P(iovs), count, f->pos, &done);
  if (err) return err;
  f->pos += done;
  *(uint32_t *)P(out) = done;
  return 0;
}

int32_t __imported_wasi_snapshot_preview1_fd_write(int32_t fd, int32_t iovs, int32_t count, int32_t out) {
  HOST(fd_write(fd, iovs, count, out));
  Fd *f = get_fd(fd);
  if (!f) return __WASI_ERRNO_BADF;
  if (f->flags & __WASI_FDFLAGS_APPEND) f->pos = f->node->size;
  size_t done;
  int err = do_write(f->node, P(iovs), count, f->pos, &done);
  if (err) return err;
  f->pos += done;
  *(uint32_t *)P(out) = done;
  return 0;
}

int32_t __imported_wasi_snapshot_preview1_fd_prestat_get(int32_t fd, int32_t buf) {
  HOST(fd_prestat_get(fd, buf));
  Fd *f = get_fd(fd);
  if (!f || !f->preopen) return __WASI_ERRNO_BADF;
  __wasi_prestat_t *p = P(buf);
  p->tag = __WASI_PREOPENTYPE_DIR;
  p->u.dir.pr_name_len = strlen(f->preopen);
  return 0;
}

int32_t __imported_wasi_snapshot_preview1_fd_prestat_dir_name(int32_t fd, int32_t buf, int32_t len) {
  HOST(fd_prestat_dir_name(fd, buf, len));
  Fd *f = get_fd(fd);
  if (!f || !f->preopen) return __WASI_ERRNO_BADF;
  size_t n = strlen(f->preopen);
  if ((size_t)len < n) return __WASI_ERRNO_NAMETOOLONG;
  memcpy(P(buf), f->preopen, n);
  return 0;
}

int32_t __imported_wasi_snapshot_preview1_fd_readdir(int32_t fd, int32_t buf, int32_t len, int64_t cookie, int32_t used) {
  HOST(fd_readdir(fd, buf, len, cookie, used));
  int err = 0;
  Node *dir = get_dir(fd, &err);
  if (!dir) return err;
  uint8_t *out = P(buf);
  size_t pos = 0;
  // Cookies 0 and 1 are "." and "..", then one per entry.
  for (uint64_t c = cookie; c < dir->count + 2 && pos < (size_t)len; c++) {
    const char *name = c == 0 ? "." : c == 1 ? ".." : dir->entries[c - 2].name;
    Node *n = c == 0 ? dir : c == 1 ? dir->parent : dir->entries[c - 2].node;
    __wasi_dirent_t d = {c + 1, n->ino, strlen(name), n->type};
    size_t m = sizeof(d) < len - pos ? sizeof(d) : len - pos;
    memcpy(out + pos, &d, m);
    pos += m;
    m = d.d_namlen < len - pos ? d.d_namlen : len - pos;
    memcpy(out + pos, name, m);
    pos += m;
  }
  *(uint32_t *)P(used) = pos;
  return 0;
}

int32_t __imported_wasi_snapshot_preview1_fd_renumber(int32_t fd, int32_t to) {
  if (!active || (fd < 3 && to < 3)) return host_fd_renumber(fd, to);
  Fd *f = get_fd(fd);
  if (!f || to < 3 || !get_fd(to)) return __WASI_ERRNO_BADF;
  if (fd == to) return 0;
  __imported_wasi_snapshot_preview1_fd_close(to);
  fds[to] = *f;
  *f = (Fd){0};
  return 0;
}

int32_t __imported_wasi_snapshot_preview1_fd_seek(int32_t fd, int64_t off, int32_t whence, int32_t out) {
  HOST(fd_seek(fd, off, whence, out));
  Fd *f = get_fd(fd);
  if (!f) return __WASI_ERRNO_BADF;
  if (f->node->type == __WASI_FILETYPE_DIRECTORY) return __WASI_ERRNO_ISDIR;
  if (f->node->type == __WASI_FILETYPE_CHARACTER_DEVICE) {
    *(uint64_t *)P(out) = 0;
    return 0;
  }
  int64_t base = whence == __WASI_WHENCE_SET ? 0 : whence == __WASI_WHENCE_CUR ? (int64_t)f->pos
               : whence == __WASI_WHENCE_END ? (int64_t)f->node->size : -1;
  if (base < 0 && whence != __WASI_WHENCE_SET) return __WASI_ERRNO_INVAL;
  if (base + off < 0) return __WASI_ERRNO_INVAL;
  f->pos = base + off;
  *(uint64_t *)P(out) = f->pos;
  return 0;
}

int32_t __imported_wasi_snapshot_preview1_fd_tell(int32_t fd, int32_t out) {
  HOST(fd_tell(fd, out));
  Fd *f = get_fd(fd);
  if (!f) return __WASI_ERRNO_BADF;
  *(uint64_t *)P(out) = f->pos;
  return 0;
}

int32_t __imported_wasi_snapshot_preview1_path_create_directory(int32_t fd, int32_t path, int32_t len) {
  HOST(path_create_directory(fd, path, len));
  int err = 0;
  Node *dir = get_dir(fd, &err), *parent;
  if (!dir) return err;
  const char *last;
  size_t last_len;
  if ((err = walk(dir, S(path), len, &parent, &last, &last_len))) return err;
  if (!last_len || find(parent, last, last_len)) return __WASI_ERRNO_EXIST;
  if (!parent->writable) return __WASI_ERRNO_ROFS;
  Node *n = new_node(__WASI_FILETYPE_DIRECTORY, parent, 1);
  if (!n) return __WASI_ERRNO_NOMEM;
  if ((err = link_into(parent, last, last_len, n))) free(n);
  return err;
}

int32_t __imported_wasi_snapshot_preview1_path_filestat_get(int32_t fd, int32_t flags, int32_t path, int32_t len, int32_t buf) {
  HOST(path_filestat_get(fd, flags, path, len, buf));
  int err = 0;
  Node *dir = get_dir(fd, &err), *n;
  if (!dir) return err;
  if ((err = lookup(dir, S(path), len, &n))) return err;
  put_filestat(P(buf), n);
  return 0;
}

int32_t __imported_wasi_snapshot_preview1_path_filestat_set_times(int32_t fd, int32_t flags, int32_t path, int32_t len, int64_t atim, int64_t mtim, int32_t fst) {
  HOST(path_filestat_set_times(fd, flags, path, len, atim, mtim, fst));
  int err = 0;
  Node *dir = get_dir(fd, &err), *n;
  if (!dir) return err;
  if ((err = lookup(dir, S(path), len, &n))) return err;
  return set_times(n, atim, mtim, fst);
}

int32_t __imported_wasi_snapshot_preview1_path_link(int32_t fd, int32_t flags, int32_t path, int32_t len, int32_t fd2, int32_t path2, int32_t len2) {
  HOST(path_link(fd, flags, path, len, fd2, path2, len2));
  return __WASI_ERRNO_NOTSUP;
}

int32_t __imported_wasi_snapshot_preview1_path_symlink(int32_t path, int32_t len, int32_t fd, int32_t path2, int32_t len2) {
  HOST(path_symlink(path, len, fd, path2, len2));
  return __WASI_ERRNO_NOTSUP;
}

int32_t __imported_wasi_snapshot_preview1_path_readlink(int32_t fd, int32_t path, int32_t len, int32_t buf, int32_t buf_len, int32_t used) {
  HOST(path_readlink(fd, path, len, buf, buf_len, used));
  int err = 0;
  Node *dir = get_dir(fd, &err), *n;
  if (!dir) return err;
  if ((err = lookup(dir, S(path), len, &n))) return err;
  return __WASI_ERRNO_INVAL;  // not a symlink
}

int32_t __imported_wasi_snapshot_preview1_path_open(int32_t fd, int32_t dirflags, int32_t path, int32_t len, int32_t oflags,
                                                    int64_t base, int64_t inh, int32_t fdflags, int32_t out) {
  HOST(path_open(fd, dirflags, path, len, oflags, base, inh, fdflags, out));
  int err = 0;
  Node *dir = get_dir(fd, &err), *parent, *n;
  if (!dir) return err;
  const char *last;
  size_t last_len;
  if ((err = walk(dir, S(path), len, &parent, &last, &last_len))) return err;
  Entry *e = last_len ? find(parent, last, last_len) : NULL;
  n = last_len ? (e ? e->node : NULL) : parent;
  int write = (base & (__WASI_RIGHTS_FD_WRITE | __WASI_RIGHTS_FD_ALLOCATE | __WASI_RIGHTS_FD_FILESTAT_SET_SIZE)) != 0;
  if (!n) {
    if (!(oflags & __WASI_OFLAGS_CREAT)) return __WASI_ERRNO_NOENT;
    if (oflags & __WASI_OFLAGS_DIRECTORY) return __WASI_ERRNO_NOENT;
    if (S(path)[len - 1] == '/') return __WASI_ERRNO_ISDIR;
    if (!parent->writable) return __WASI_ERRNO_ROFS;
    n = new_node(__WASI_FILETYPE_REGULAR_FILE, parent, 1);
    if (!n) return __WASI_ERRNO_NOMEM;
    if ((err = link_into(parent, last, last_len, n))) {
      free(n);
      return err;
    }
  } else {
    if ((oflags & __WASI_OFLAGS_CREAT) && (oflags & __WASI_OFLAGS_EXCL)) return __WASI_ERRNO_EXIST;
    if ((oflags & __WASI_OFLAGS_DIRECTORY) && n->type != __WASI_FILETYPE_DIRECTORY) return __WASI_ERRNO_NOTDIR;
    if (n->type == __WASI_FILETYPE_DIRECTORY && (write || (oflags & __WASI_OFLAGS_TRUNC))) return __WASI_ERRNO_ISDIR;
    if (S(path)[len - 1] == '/' && n->type != __WASI_FILETYPE_DIRECTORY) return __WASI_ERRNO_NOTDIR;
    if ((write || (oflags & __WASI_OFLAGS_TRUNC)) && !n->writable) return __WASI_ERRNO_ROFS;
    if (oflags & __WASI_OFLAGS_TRUNC) {
      n->size = 0;
      n->mtim = now();
    }
  }
  int32_t new_fd = alloc_fd(n, fdflags);
  if (new_fd < 0) return __WASI_ERRNO_NFILE;
  *(int32_t *)P(out) = new_fd;
  return 0;
}

int32_t __imported_wasi_snapshot_preview1_path_remove_directory(int32_t fd, int32_t path, int32_t len) {
  HOST(path_remove_directory(fd, path, len));
  int err = 0;
  Node *dir = get_dir(fd, &err), *parent;
  if (!dir) return err;
  const char *last;
  size_t last_len;
  if ((err = walk(dir, S(path), len, &parent, &last, &last_len))) return err;
  if (!last_len) return __WASI_ERRNO_INVAL;
  Entry *e = find(parent, last, last_len);
  if (!e) return __WASI_ERRNO_NOENT;
  if (e->node->type != __WASI_FILETYPE_DIRECTORY) return __WASI_ERRNO_NOTDIR;
  if (e->node->count) return __WASI_ERRNO_NOTEMPTY;
  if (!parent->writable) return __WASI_ERRNO_ROFS;
  unlink_entry(parent, e);
  return 0;
}

int32_t __imported_wasi_snapshot_preview1_path_unlink_file(int32_t fd, int32_t path, int32_t len) {
  HOST(path_unlink_file(fd, path, len));
  int err = 0;
  Node *dir = get_dir(fd, &err), *parent;
  if (!dir) return err;
  const char *last;
  size_t last_len;
  if ((err = walk(dir, S(path), len, &parent, &last, &last_len))) return err;
  if (!last_len) return __WASI_ERRNO_ISDIR;
  Entry *e = find(parent, last, last_len);
  if (!e) return __WASI_ERRNO_NOENT;
  if (e->node->type == __WASI_FILETYPE_DIRECTORY) return __WASI_ERRNO_ISDIR;
  if (S(path)[len - 1] == '/') return __WASI_ERRNO_NOTDIR;
  if (!parent->writable) return __WASI_ERRNO_ROFS;
  unlink_entry(parent, e);
  return 0;
}

static int is_ancestor(Node *a, Node *n) {
  for (;;) {
    if (n == a) return 1;
    if (n->parent == n) return 0;
    n = n->parent;
  }
}

int32_t __imported_wasi_snapshot_preview1_path_rename(int32_t fd, int32_t path, int32_t len, int32_t fd2, int32_t path2, int32_t len2) {
  HOST(path_rename(fd, path, len, fd2, path2, len2));
  int err = 0;
  Node *d1 = get_dir(fd, &err), *d2 = d1 ? get_dir(fd2, &err) : NULL, *p1, *p2;
  if (!d2) return err;
  const char *l1, *l2;
  size_t n1, n2;
  if ((err = walk(d1, S(path), len, &p1, &l1, &n1))) return err;
  if ((err = walk(d2, S(path2), len2, &p2, &l2, &n2))) return err;
  if (!n1 || !n2) return __WASI_ERRNO_INVAL;
  Entry *src = find(p1, l1, n1);
  if (!src) return __WASI_ERRNO_NOENT;
  if (!p1->writable || !p2->writable) return __WASI_ERRNO_ROFS;
  Node *n = src->node;
  if (n->type == __WASI_FILETYPE_DIRECTORY && is_ancestor(n, p2)) return __WASI_ERRNO_INVAL;
  Entry *dst = find(p2, l2, n2);
  if (dst) {
    if (dst->node == n) return 0;
    if (dst->node->type == __WASI_FILETYPE_DIRECTORY) {
      if (n->type != __WASI_FILETYPE_DIRECTORY) return __WASI_ERRNO_ISDIR;
      if (dst->node->count) return __WASI_ERRNO_NOTEMPTY;
    } else if (n->type == __WASI_FILETYPE_DIRECTORY) {
      return __WASI_ERRNO_NOTDIR;
    }
  }
  n->links++;
  unlink_entry(p1, src);
  if (dst) unlink_entry(p2, find(p2, l2, n2));
  err = link_into(p2, l2, n2, n);
  unref(n);
  return err;
}

// ---- setup ----

// The directory at absolute `path`, made (with its parents) if missing.
static Node *mkdirs(const char *path, size_t len, int writable) {
  if (!root) {
    root = new_node(__WASI_FILETYPE_DIRECTORY, NULL, 0);
    root->links = 1;
  }
  Node *cur = root;
  size_t i = 0;
  while (i < len) {
    while (i < len && path[i] == '/') i++;
    size_t j = i;
    while (j < len && path[j] != '/') j++;
    if (j == i) break;
    Entry *e = find(cur, path + i, j - i);
    if (e) {
      if (e->node->type != __WASI_FILETYPE_DIRECTORY) return NULL;
      cur = e->node;
    } else {
      Node *n = new_node(__WASI_FILETYPE_DIRECTORY, cur, writable);
      if (!n || link_into(cur, path + i, j - i, n)) return NULL;
      cur = n;
    }
    i = j;
  }
  return cur;
}

void cfvfs_activate(void) {
  if (active) return;
  for (int32_t fd = 3;; fd++) {
    __wasi_prestat_t p;
    if (host_fd_prestat_get(fd, (int32_t)(uintptr_t)&p) != 0) break;
    char *name = calloc(1, p.u.dir.pr_name_len + 1);
    if (!name || host_fd_prestat_dir_name(fd, (int32_t)(uintptr_t)name, p.u.dir.pr_name_len)) break;
    // Build-time inputs (build.sh's /.build) aren't part of the Worker.
    if (!strncmp(name, "/.build", 7)) {
      free(name);
      continue;
    }
    int tmp = !strcmp(name, "/tmp");
    Node *n = mkdirs(name, strlen(name), tmp);
    if (!n) break;
    n->writable |= tmp;
    if (!strcmp(name, "/dev") && !find(n, "null", 4)) {
      Node *null = new_node(__WASI_FILETYPE_CHARACTER_DEVICE, n, 1);
      if (null) link_into(n, "null", 4, null);
    }
    while (nfds <= (size_t)fd) {
      size_t cap = nfds ? nfds * 2 : 16;
      Fd *f = realloc(fds, cap * sizeof(Fd));
      memset(f + nfds, 0, (cap - nfds) * sizeof(Fd));
      fds = f;
      nfds = cap;
    }
    fds[fd] = (Fd){n, 0, 0, name};
    n->links++;
  }
  active = 1;
}

static PyObject *vfs_add(PyObject *self, PyObject *args) {
  const char *path;
  Py_ssize_t len;
  Py_buffer data = {0};
  PyObject *obj;
  if (!PyArg_ParseTuple(args, "s#O", &path, &len, &obj)) return NULL;
  if (obj != Py_None && PyObject_GetBuffer(obj, &data, PyBUF_SIMPLE) < 0) return NULL;
  const char *slash = path + len;
  while (slash > path && slash[-1] != '/') slash--;
  Node *dir = mkdirs(path, obj == Py_None ? (size_t)len : (size_t)(slash - path), 0);
  if (!dir) goto fail;
  if (obj != Py_None) {
    size_t name_len = path + len - slash;
    Entry *e = find(dir, slash, name_len);
    if (e) unlink_entry(dir, e);
    Node *n = new_node(__WASI_FILETYPE_REGULAR_FILE, dir, 0);
    if (!n || reserve(n, data.len ? data.len : 1) || link_into(dir, slash, name_len, n)) goto fail;
    memcpy(n->data, data.buf, data.len);
    n->size = data.len;
    PyBuffer_Release(&data);
  }
  Py_RETURN_NONE;
fail:
  if (data.obj) PyBuffer_Release(&data);
  return PyErr_Format(PyExc_OSError, "_cfvfs.add: can't add %s", path);
}

// _cfvfs.alias(path, target): makes the directory `path` another name for
// the directory `target` (both absolute).
static PyObject *vfs_alias(PyObject *self, PyObject *args) {
  const char *path, *target;
  Py_ssize_t len, tlen;
  if (!PyArg_ParseTuple(args, "s#s#", &path, &len, &target, &tlen)) return NULL;
  const char *slash = path + len;
  while (slash > path && slash[-1] != '/') slash--;
  Node *t = mkdirs(target, tlen, 0), *dir = mkdirs(path, slash - path, 0);
  if (!t || !dir || find(dir, slash, path + len - slash)) return PyErr_Format(PyExc_OSError, "_cfvfs.alias: can't add %s", path);
  // ".." from the target still leads to its own parent.
  Node *parent = t->parent;
  if (link_into(dir, slash, path + len - slash, t)) return PyErr_NoMemory();
  t->parent = parent;
  Py_RETURN_NONE;
}

static PyMethodDef vfs_methods[] = {
  {"add", vfs_add, METH_VARARGS, NULL},
  {"alias", vfs_alias, METH_VARARGS, NULL},
  {NULL, NULL, 0, NULL},
};

static struct PyModuleDef vfs_module = {PyModuleDef_HEAD_INIT, "_cfvfs", NULL, -1, vfs_methods};

PyObject *PyInit__cfvfs(void) { return PyModule_Create(&vfs_module); }
