"""fcntl for WASI, where CPython doesn't build it: the parts a single
process can honor. F_GETFL/F_SETFL read and set O_NONBLOCK (os.get_blocking,
os.set_blocking); file locks always succeed, as there is no other process to
exclude; ioctl fails with ENOTTY. Pyodide has the C module, over Emscripten's
stubs, so packages import it at the top level (mcp's stdio server does)."""

import errno as _errno
import os as _os

F_DUPFD = 0
F_GETFD = 1
F_SETFD = 2
F_GETFL = 3
F_SETFL = 4
F_GETLK = 5
F_SETLK = 6
F_SETLKW = 7
FD_CLOEXEC = 1
LOCK_SH = 1
LOCK_EX = 2
LOCK_NB = 4
LOCK_UN = 8


def _fd(fd):
    return fd if isinstance(fd, int) else fd.fileno()


def fcntl(fd, cmd, arg=0, /):
    fd = _fd(fd)
    if cmd == F_GETFL:
        return 0 if _os.get_blocking(fd) else _os.O_NONBLOCK
    if cmd == F_SETFL:
        _os.set_blocking(fd, not (arg & _os.O_NONBLOCK))
        return 0
    if cmd in (F_GETFD, F_SETFD):
        return 0
    if cmd in (F_SETLK, F_SETLKW, F_GETLK):
        return arg
    raise OSError(_errno.EINVAL, _os.strerror(_errno.EINVAL))


def ioctl(fd, request, arg=0, mutate_flag=True, /):
    raise OSError(_errno.ENOTTY, _os.strerror(_errno.ENOTTY))


def flock(fd, operation, /):
    _fd(fd)


def lockf(fd, cmd, len=0, start=0, whence=0, /):
    _fd(fd)
