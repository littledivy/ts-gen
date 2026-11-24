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
//   descriptor is served from memory, and stdin, stdout and stderr are
//   descriptors 0, 1 and 2 of a table like any other, whose open files
//   write to the host's.
//   /tmp is writable, as in Pyodide, and /dev holds null; everything else
//   is read-only, and writing to it fails with EACCES, as in Pyodide.
//
// Descriptors share open files as POSIX's do: `_cfvfs.dup(fd)` and
// `_cfvfs.dup2(fd, fd2)`, which _cf_runtime installs as os.dup and os.dup2
// (WASI has neither), give another descriptor for the same file and
// position, and `_cfvfs.pipe()` (os.pipe) a pipe within the instance.
// Symbolic links work as in POSIX, and `_cfvfs.symlink(path, target)`
// makes one before the snapshot. There are no hard links or permissions.
// Timestamps are the realtime clock at creation and on each write.

#define PY_SSIZE_T_CLEAN
#include <Python.h>

#include <errno.h>
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
  // __WASI_FILETYPE_DIRECTORY, _REGULAR_FILE, _SYMBOLIC_LINK (whose data is
  // the target) or _CHARACTER_DEVICE (/dev/null, and pipes, which have `fifo`
  // set).
  uint8_t type;
  uint8_t writable;
  uint8_t fifo;
  uint32_t writers;  // a pipe's open write ends
  uint64_t ino, mtim;
  uint32_t links;  // names plus open descriptors; freed at 0
  Node *parent;
  Entry *entries;  // directories
  size_t count, cap;
  uint8_t *data;  // files
  size_t size, alloc;
};

// An open file: what open() makes and dup() shares, with the position.
// `host` is the host's descriptor for stdin, stdout and stderr (node NULL),
// and -1 otherwise.
typedef struct {
  Node *node;
  uint64_t pos;
  uint16_t flags;
  uint8_t pipe_end;  // 1 for a pipe's read end, 2 for its write end
  int32_t host;
  uint32_t refs;
} File;

typedef struct {
  File *file;
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

#define MAX_LINKS 40

static int lookup_at(Node *dir, const char *path, size_t len, int follow, int depth, Node **out);

// The node a symbolic link at `n` in `dir` leads to.
static int follow_link(Node *dir, Node *n, int depth, Node **out) {
  if (depth >= MAX_LINKS) return __WASI_ERRNO_LOOP;
  return lookup_at(dir, (const char *)n->data, n->size, 1, depth + 1, out);
}

// Splits `path` relative to `dir` into its directory and last component,
// following symbolic links on the way. `*last` is empty for a path naming
// `dir` itself (or ending in "/." etc.). An absolute path is relative to the
// root, which only a symbolic link's target may be (wasi-libc passes paths
// relative to a preopen).
static int walk_at(Node *dir, const char *path, size_t len, int depth, Node **parent, const char **last, size_t *last_len) {
  Node *cur = dir;
  size_t i = 0;
  if (len && path[0] == '/') {
    if (!depth) return __WASI_ERRNO_NOTCAPABLE;
    cur = root;
    while (i < len && path[i] == '/') i++;
  }
  *last = path + i;
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
      Node *n = e->node;
      if (n->type == __WASI_FILETYPE_SYMBOLIC_LINK) {
        int err = follow_link(cur, n, depth, &n);
        if (err) return err;
      }
      if (n->type != __WASI_FILETYPE_DIRECTORY) return __WASI_ERRNO_NOTDIR;
      cur = n;
    }
    i = k;
  }
  *parent = cur;
  return 0;
}

static int walk(Node *dir, const char *path, size_t len, Node **parent, const char **last, size_t *last_len) {
  return walk_at(dir, path, len, 0, parent, last, last_len);
}

static int lookup_at(Node *dir, const char *path, size_t len, int follow, int depth, Node **out) {
  Node *parent;
  const char *last;
  size_t last_len;
  int err = walk_at(dir, path, len, depth, &parent, &last, &last_len);
  if (err) return err;
  if (!last_len) {
    *out = parent;
    return 0;
  }
  Entry *e = find(parent, last, last_len);
  if (!e) return __WASI_ERRNO_NOENT;
  Node *n = e->node;
  int slash = path[len - 1] == '/';
  if (n->type == __WASI_FILETYPE_SYMBOLIC_LINK && (follow || slash)) {
    if ((err = follow_link(parent, n, depth, &n))) return err;
  }
  // "file/" names a directory.
  if (slash && n->type != __WASI_FILETYPE_DIRECTORY) return __WASI_ERRNO_NOTDIR;
  *out = n;
  return 0;
}

static int lookup(Node *dir, const char *path, size_t len, int follow, Node **out) {
  return lookup_at(dir, path, len, follow, 0, out);
}

static File *new_file(Node *n, uint16_t flags) {
  File *f = calloc(1, sizeof(File));
  if (!f) return NULL;
  f->node = n;
  f->flags = flags;
  f->host = -1;
  f->refs = 1;
  if (n) n->links++;
  return f;
}

static void drop_file(File *f) {
  if (--f->refs) return;
  if (f->pipe_end == 2) f->node->writers--;
  if (f->node) unref(f->node);
  free(f);
}

static int grow_fds(size_t want) {
  while (nfds <= want) {
    size_t cap = nfds ? nfds * 2 : 16;
    Fd *f = realloc(fds, cap * sizeof(Fd));
    if (!f) return -1;
    memset(f + nfds, 0, (cap - nfds) * sizeof(Fd));
    fds = f;
    nfds = cap;
  }
  return 0;
}

// The lowest free descriptor, for `f` (whose reference it takes).
static int32_t install_fd(File *f) {
  size_t i = 0;
  while (i < nfds && fds[i].file) i++;
  if (grow_fds(i)) return -1;
  fds[i] = (Fd){f, NULL};
  return (int32_t)i;
}

static int32_t alloc_fd(Node *n, uint16_t flags) {
  File *f = new_file(n, flags);
  if (!f) return -1;
  int32_t fd = install_fd(f);
  if (fd < 0) drop_file(f);
  return fd;
}

static Fd *get_fd(int32_t fd) { return fd >= 0 && (size_t)fd < nfds && fds[fd].file ? &fds[fd] : NULL; }

// The file an in-memory descriptor names (NULL for the host's).
static File *get_file(int32_t fd) {
  Fd *d = get_fd(fd);
  return d && d->file->node ? d->file : NULL;
}

// The host's descriptor behind `fd`, or -1.
static int32_t host_of(int32_t fd) {
  Fd *d = get_fd(fd);
  return d ? d->file->host : -1;
}

static Node *get_dir(int32_t fd, int *err) {
  File *f = get_file(fd);
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
  if (n->fifo) {
    // A pipe reads from the front; with nothing in it, EOF once no write
    // end is open, and otherwise EAGAIN, since nothing could fill it while
    // this waited.
    if (!n->size) {
      *done = 0;
      return n->writers ? __WASI_ERRNO_AGAIN : 0;
    }
    pos = 0;
  } else if (n->type == __WASI_FILETYPE_CHARACTER_DEVICE) {
    pos = n->size;
  }
  size_t total = 0;
  for (size_t i = 0; i < count; i++) {
    if (pos >= n->size) break;
    size_t m = n->size - pos < iovs[i].buf_len ? n->size - pos : iovs[i].buf_len;
    memcpy(iovs[i].buf, n->data + pos, m);
    pos += m;
    total += m;
  }
  if (n->fifo) {
    memmove(n->data, n->data + total, n->size - total);
    n->size -= total;
  }
  *done = total;
  return 0;
}

static int do_write(Node *n, const __wasi_ciovec_t *iovs, size_t count, uint64_t pos, size_t *done) {
  if (n->type == __WASI_FILETYPE_DIRECTORY) return __WASI_ERRNO_ISDIR;
  if (!n->writable) return __WASI_ERRNO_ACCES;
  size_t total = 0;
  for (size_t i = 0; i < count; i++) total += iovs[i].buf_len;
  if (n->fifo) {
    pos = n->size;
  } else if (n->type == __WASI_FILETYPE_CHARACTER_DEVICE) {
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
// Calls go to the host while pre-initializing, and after that for the
// host's stdin, stdout and stderr, under whichever descriptor names them.
#define HOST(call)                  \
  if (!active) return host_##call; \
  {                                 \
    int32_t hfd = host_of(fd);      \
    if (hfd >= 0) {                 \
      int32_t fd = hfd;             \
      return host_##call;           \
    }                               \
  }

int32_t __imported_wasi_snapshot_preview1_fd_advise(int32_t fd, int64_t off, int64_t len, int32_t advice) {
  HOST(fd_advise(fd, off, len, advice));
  return get_file(fd) ? 0 : __WASI_ERRNO_BADF;
}

int32_t __imported_wasi_snapshot_preview1_fd_allocate(int32_t fd, int64_t off, int64_t len) {
  HOST(fd_allocate(fd, off, len));
  File *f = get_file(fd);
  if (!f) return __WASI_ERRNO_BADF;
  if (f->node->type != __WASI_FILETYPE_REGULAR_FILE) return __WASI_ERRNO_BADF;
  if (!f->node->writable) return __WASI_ERRNO_ACCES;
  return (uint64_t)(off + len) > f->node->size ? resize(f->node, off + len) : 0;
}

static int close_fd(int32_t fd) {
  Fd *d = get_fd(fd);
  if (!d) return __WASI_ERRNO_BADF;
  File *f = d->file;
  free(d->preopen);
  *d = (Fd){0};
  // The host's own descriptors stay open: closing stdout here only closes
  // this name for it.
  drop_file(f);
  return 0;
}

int32_t __imported_wasi_snapshot_preview1_fd_close(int32_t fd) {
  if (!active) return host_fd_close(fd);
  return close_fd(fd);
}

int32_t __imported_wasi_snapshot_preview1_fd_datasync(int32_t fd) {
  HOST(fd_datasync(fd));
  return get_file(fd) ? 0 : __WASI_ERRNO_BADF;
}

int32_t __imported_wasi_snapshot_preview1_fd_sync(int32_t fd) {
  HOST(fd_sync(fd));
  return get_file(fd) ? 0 : __WASI_ERRNO_BADF;
}

int32_t __imported_wasi_snapshot_preview1_fd_fdstat_get(int32_t fd, int32_t buf) {
  HOST(fd_fdstat_get(fd, buf));
  File *f = get_file(fd);
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
  File *f = get_file(fd);
  if (!f) return __WASI_ERRNO_BADF;
  f->flags = flags;
  return 0;
}

int32_t __imported_wasi_snapshot_preview1_fd_fdstat_set_rights(int32_t fd, int64_t base, int64_t inh) {
  HOST(fd_fdstat_set_rights(fd, base, inh));
  return get_file(fd) ? 0 : __WASI_ERRNO_BADF;
}

int32_t __imported_wasi_snapshot_preview1_fd_filestat_get(int32_t fd, int32_t buf) {
  HOST(fd_filestat_get(fd, buf));
  File *f = get_file(fd);
  if (!f) return __WASI_ERRNO_BADF;
  put_filestat(P(buf), f->node);
  return 0;
}

int32_t __imported_wasi_snapshot_preview1_fd_filestat_set_size(int32_t fd, int64_t size) {
  HOST(fd_filestat_set_size(fd, size));
  File *f = get_file(fd);
  if (!f) return __WASI_ERRNO_BADF;
  if (f->node->type != __WASI_FILETYPE_REGULAR_FILE) return __WASI_ERRNO_INVAL;
  if (!f->node->writable) return __WASI_ERRNO_ACCES;
  return resize(f->node, size);
}

static int set_times(Node *n, int64_t atim, int64_t mtim, int32_t flags) {
  (void)atim;
  if (!n->writable) return __WASI_ERRNO_ACCES;
  if (flags & __WASI_FSTFLAGS_MTIM) n->mtim = mtim;
  else if (flags & __WASI_FSTFLAGS_MTIM_NOW) n->mtim = now();
  return 0;
}

int32_t __imported_wasi_snapshot_preview1_fd_filestat_set_times(int32_t fd, int64_t atim, int64_t mtim, int32_t flags) {
  HOST(fd_filestat_set_times(fd, atim, mtim, flags));
  File *f = get_file(fd);
  return f ? set_times(f->node, atim, mtim, flags) : __WASI_ERRNO_BADF;
}

int32_t __imported_wasi_snapshot_preview1_fd_pread(int32_t fd, int32_t iovs, int32_t count, int64_t off, int32_t out) {
  HOST(fd_pread(fd, iovs, count, off, out));
  File *f = get_file(fd);
  if (!f) return __WASI_ERRNO_BADF;
  size_t done;
  int err = do_read(f->node, P(iovs), count, off, &done);
  if (!err) *(uint32_t *)P(out) = done;
  return err;
}

int32_t __imported_wasi_snapshot_preview1_fd_pwrite(int32_t fd, int32_t iovs, int32_t count, int64_t off, int32_t out) {
  HOST(fd_pwrite(fd, iovs, count, off, out));
  File *f = get_file(fd);
  if (!f) return __WASI_ERRNO_BADF;
  size_t done;
  int err = do_write(f->node, P(iovs), count, off, &done);
  if (!err) *(uint32_t *)P(out) = done;
  return err;
}

int32_t __imported_wasi_snapshot_preview1_fd_read(int32_t fd, int32_t iovs, int32_t count, int32_t out) {
  HOST(fd_read(fd, iovs, count, out));
  File *f = get_file(fd);
  if (!f || f->pipe_end == 2) return __WASI_ERRNO_BADF;
  size_t done;
  int err = do_read(f->node, P(iovs), count, f->pos, &done);
  if (err) return err;
  f->pos += done;
  *(uint32_t *)P(out) = done;
  return 0;
}

int32_t __imported_wasi_snapshot_preview1_fd_write(int32_t fd, int32_t iovs, int32_t count, int32_t out) {
  HOST(fd_write(fd, iovs, count, out));
  File *f = get_file(fd);
  if (!f || f->pipe_end == 1) return __WASI_ERRNO_BADF;
  if (f->pipe_end == 2 && !f->node->writers) return __WASI_ERRNO_PIPE;
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

// fd2 names fd's open file (as dup2), whatever fd2 named before closed.
static int dup_to(int32_t fd, int32_t fd2) {
  Fd *d = get_fd(fd);
  if (!d || fd2 < 0) return __WASI_ERRNO_BADF;
  if (fd == fd2) return 0;
  File *f = d->file;
  f->refs++;
  if (get_fd(fd2)) close_fd(fd2);
  if (grow_fds(fd2)) {
    drop_file(f);
    return __WASI_ERRNO_NOMEM;
  }
  fds[fd2] = (Fd){f, NULL};
  return 0;
}

int32_t __imported_wasi_snapshot_preview1_fd_renumber(int32_t fd, int32_t to) {
  if (!active) return host_fd_renumber(fd, to);
  if (!get_fd(fd) || !get_fd(to)) return __WASI_ERRNO_BADF;
  int err = dup_to(fd, to);
  if (!err && fd != to) close_fd(fd);
  return err;
}

int32_t __imported_wasi_snapshot_preview1_fd_seek(int32_t fd, int64_t off, int32_t whence, int32_t out) {
  HOST(fd_seek(fd, off, whence, out));
  File *f = get_file(fd);
  if (!f) return __WASI_ERRNO_BADF;
  if (f->node->type == __WASI_FILETYPE_DIRECTORY) return __WASI_ERRNO_ISDIR;
  if (f->node->fifo) return __WASI_ERRNO_SPIPE;
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
  File *f = get_file(fd);
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
  if (!parent->writable) return __WASI_ERRNO_ACCES;
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
  if ((err = lookup(dir, S(path), len, flags & __WASI_LOOKUPFLAGS_SYMLINK_FOLLOW, &n))) return err;
  put_filestat(P(buf), n);
  return 0;
}

int32_t __imported_wasi_snapshot_preview1_path_filestat_set_times(int32_t fd, int32_t flags, int32_t path, int32_t len, int64_t atim, int64_t mtim, int32_t fst) {
  HOST(path_filestat_set_times(fd, flags, path, len, atim, mtim, fst));
  int err = 0;
  Node *dir = get_dir(fd, &err), *n;
  if (!dir) return err;
  if ((err = lookup(dir, S(path), len, flags & __WASI_LOOKUPFLAGS_SYMLINK_FOLLOW, &n))) return err;
  return set_times(n, atim, mtim, fst);
}

int32_t __imported_wasi_snapshot_preview1_path_link(int32_t fd, int32_t flags, int32_t path, int32_t len, int32_t fd2, int32_t path2, int32_t len2) {
  HOST(path_link(fd, flags, path, len, fd2, path2, len2));
  return __WASI_ERRNO_NOTSUP;
}

static int make_symlink(Node *parent, const char *name, size_t len, const char *target, size_t tlen, int writable) {
  Node *n = new_node(__WASI_FILETYPE_SYMBOLIC_LINK, parent, writable);
  if (!n) return __WASI_ERRNO_NOMEM;
  int err = reserve(n, tlen ? tlen : 1);
  if (!err) {
    memcpy(n->data, target, tlen);
    n->size = tlen;
    err = link_into(parent, name, len, n);
  }
  if (err) {
    free(n->data);
    free(n);
  }
  return err;
}

int32_t __imported_wasi_snapshot_preview1_path_symlink(int32_t path, int32_t len, int32_t fd, int32_t path2, int32_t len2) {
  HOST(path_symlink(path, len, fd, path2, len2));
  int err = 0;
  Node *dir = get_dir(fd, &err), *parent;
  if (!dir) return err;
  const char *last;
  size_t last_len;
  if ((err = walk(dir, S(path2), len2, &parent, &last, &last_len))) return err;
  if (!last_len || find(parent, last, last_len)) return __WASI_ERRNO_EXIST;
  if (!parent->writable) return __WASI_ERRNO_ACCES;
  return make_symlink(parent, last, last_len, S(path), len, 1);
}

int32_t __imported_wasi_snapshot_preview1_path_readlink(int32_t fd, int32_t path, int32_t len, int32_t buf, int32_t buf_len, int32_t used) {
  HOST(path_readlink(fd, path, len, buf, buf_len, used));
  int err = 0;
  Node *dir = get_dir(fd, &err), *n;
  if (!dir) return err;
  if ((err = lookup(dir, S(path), len, 0, &n))) return err;
  if (n->type != __WASI_FILETYPE_SYMBOLIC_LINK) return __WASI_ERRNO_INVAL;
  size_t m = n->size < (size_t)buf_len ? n->size : (size_t)buf_len;
  memcpy(P(buf), n->data, m);
  *(uint32_t *)P(used) = m;
  return 0;
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
  if (n && n->type == __WASI_FILETYPE_SYMBOLIC_LINK) {
    if (!(dirflags & __WASI_LOOKUPFLAGS_SYMLINK_FOLLOW)) return __WASI_ERRNO_LOOP;
    if ((err = follow_link(parent, n, 0, &n))) return err;
  }
  int write = (base & (__WASI_RIGHTS_FD_WRITE | __WASI_RIGHTS_FD_ALLOCATE | __WASI_RIGHTS_FD_FILESTAT_SET_SIZE)) != 0;
  if (!n) {
    if (!(oflags & __WASI_OFLAGS_CREAT)) return __WASI_ERRNO_NOENT;
    if (oflags & __WASI_OFLAGS_DIRECTORY) return __WASI_ERRNO_NOENT;
    if (S(path)[len - 1] == '/') return __WASI_ERRNO_ISDIR;
    if (!parent->writable) return __WASI_ERRNO_ACCES;
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
    if ((write || (oflags & __WASI_OFLAGS_TRUNC)) && !n->writable) return __WASI_ERRNO_ACCES;
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
  if (!parent->writable) return __WASI_ERRNO_ACCES;
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
  if (!parent->writable) return __WASI_ERRNO_ACCES;
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
  if (!p1->writable || !p2->writable) return __WASI_ERRNO_ACCES;
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
    File *f = new_file(n, 0);
    if (!f || grow_fds(fd)) break;
    fds[fd] = (Fd){f, name};
  }
  for (int32_t fd = 0; fd < 3; fd++) {
    File *f = new_file(NULL, 0);
    if (!f || grow_fds(fd)) break;
    f->host = fd;
    fds[fd] = (Fd){f, NULL};
  }
  active = 1;
}

// _cfvfs.add(path, data, writable=False): a file at `path` (absolute)
// holding `data`, or with data None a directory, made with its parents.
static PyObject *vfs_add(PyObject *self, PyObject *args) {
  const char *path;
  Py_ssize_t len;
  Py_buffer data = {0};
  PyObject *obj;
  int writable = 0;
  if (!PyArg_ParseTuple(args, "s#O|p", &path, &len, &obj, &writable)) return NULL;
  if (obj != Py_None && PyObject_GetBuffer(obj, &data, PyBUF_SIMPLE) < 0) return NULL;
  const char *slash = path + len;
  while (slash > path && slash[-1] != '/') slash--;
  Node *dir = mkdirs(path, obj == Py_None ? (size_t)len : (size_t)(slash - path), 0);
  if (!dir) goto fail;
  if (obj != Py_None) {
    size_t name_len = path + len - slash;
    Entry *e = find(dir, slash, name_len);
    if (e) unlink_entry(dir, e);
    Node *n = new_node(__WASI_FILETYPE_REGULAR_FILE, dir, writable);
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

// _cfvfs.symlink(path, target): makes `path` (absolute) a read-only
// symbolic link to `target`.
static PyObject *vfs_symlink(PyObject *self, PyObject *args) {
  const char *path, *target;
  Py_ssize_t len, tlen;
  if (!PyArg_ParseTuple(args, "s#s#", &path, &len, &target, &tlen)) return NULL;
  const char *slash = path + len;
  while (slash > path && slash[-1] != '/') slash--;
  Node *dir = mkdirs(path, slash - path, 0);
  if (!dir) return PyErr_Format(PyExc_OSError, "_cfvfs.symlink: can't add %s", path);
  Entry *e = find(dir, slash, path + len - slash);
  if (e) unlink_entry(dir, e);
  if (make_symlink(dir, slash, path + len - slash, target, tlen, 0)) return PyErr_NoMemory();
  Py_RETURN_NONE;
}

static PyObject *set_errno(int err) {
  errno = err;
  return PyErr_SetFromErrno(PyExc_OSError);
}

// os.dup and os.dup2, for the in-memory descriptors (once active).
static PyObject *vfs_dup(PyObject *self, PyObject *args) {
  int fd;
  if (!PyArg_ParseTuple(args, "i", &fd)) return NULL;
  Fd *d = active ? get_fd(fd) : NULL;
  if (!d) return set_errno(EBADF);
  d->file->refs++;
  int32_t fd2 = install_fd(d->file);
  if (fd2 < 0) {
    drop_file(d->file);
    return set_errno(EMFILE);
  }
  return PyLong_FromLong(fd2);
}

static PyObject *vfs_dup2(PyObject *self, PyObject *args, PyObject *kw) {
  static char *names[] = {"fd", "fd2", "inheritable", NULL};
  int fd, fd2, inheritable = 1;
  if (!PyArg_ParseTupleAndKeywords(args, kw, "ii|p", names, &fd, &fd2, &inheritable)) return NULL;
  if (!active) return set_errno(EBADF);
  int err = dup_to(fd, fd2);
  if (err) return set_errno(err);
  return PyLong_FromLong(fd2);
}

// os.pipe: (read end, write end) of a pipe within the instance.
static PyObject *vfs_pipe(PyObject *self, PyObject *noargs) {
  if (!active) return set_errno(ENOSYS);
  Node *n = new_node(__WASI_FILETYPE_CHARACTER_DEVICE, NULL, 1);
  if (!n) return PyErr_NoMemory();
  n->fifo = 1;
  File *r = new_file(n, 0), *w = new_file(n, 0);
  if (!r || !w) {
    free(r);
    free(w);
    free(n);
    return PyErr_NoMemory();
  }
  r->pipe_end = 1;
  w->pipe_end = 2;
  n->writers = 1;
  int32_t rfd = install_fd(r);
  int32_t wfd = rfd < 0 ? -1 : install_fd(w);
  if (wfd < 0) {
    if (rfd >= 0) close_fd(rfd);
    else drop_file(r);
    drop_file(w);
    return set_errno(EMFILE);
  }
  return Py_BuildValue("(ii)", rfd, wfd);
}

static PyObject *vfs_active(PyObject *self, PyObject *noargs) { return PyBool_FromLong(active); }

// _cfvfs.writable(path): whether the file at `path` (absolute) can be
// written, once active.
static PyObject *vfs_writable(PyObject *self, PyObject *args) {
  const char *path;
  Py_ssize_t len;
  if (!PyArg_ParseTuple(args, "s#", &path, &len)) return NULL;
  Node *n;
  if (!active || !root || lookup_at(root, path, len, 1, 1, &n)) Py_RETURN_FALSE;
  return PyBool_FromLong(n->writable);
}

static PyMethodDef vfs_methods[] = {
  {"active", vfs_active, METH_NOARGS, NULL},
  {"writable", vfs_writable, METH_VARARGS, NULL},
  {"add", vfs_add, METH_VARARGS, NULL},
  {"alias", vfs_alias, METH_VARARGS, NULL},
  {"symlink", vfs_symlink, METH_VARARGS, NULL},
  {"dup", vfs_dup, METH_VARARGS, NULL},
  {"dup2", (PyCFunction)(void (*)(void))vfs_dup2, METH_VARARGS | METH_KEYWORDS, NULL},
  {"pipe", vfs_pipe, METH_NOARGS, NULL},
  {NULL, NULL, 0, NULL},
};

static struct PyModuleDef vfs_module = {PyModuleDef_HEAD_INIT, "_cfvfs", NULL, -1, vfs_methods};

PyObject *PyInit__cfvfs(void) { return PyModule_Create(&vfs_module); }
