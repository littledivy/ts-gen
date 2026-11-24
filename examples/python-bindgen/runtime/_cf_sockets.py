"""The socket module over cloudflare:sockets, as Python Workers provide it.

patch() replaces socket.socket and socket.getaddrinfo, and adds
socket.gethostbyname, which WASI lacks: a socket is a TCP
connection made with cloudflare:sockets' connect(), opened with
secureTransport "starttls" so that ssl's wrap_socket can upgrade it with
startTls(). Blocking calls suspend the instance until the JS promise settles;
the event loop's sock_* methods and transports (see _cf_runtime) await the
same promises without blocking.
"""

import errno
import itertools
import socket as _std

import _cfjs

_fds = itertools.count(3)
_connect = []  # cloudflare:sockets' connect, once imported


def _js_connect(host, port):
    if not _connect:
        _connect.append(_cfjs.getattr(_cfjs.import_module("cloudflare:sockets"), "connect"))
    address = _cfjs.new_object()
    _cfjs.set(address, "hostname", host)
    _cfjs.set(address, "port", port)
    options = _cfjs.new_object()
    _cfjs.set(options, "secureTransport", "starttls")
    _cfjs.set(options, "allowHalfOpen", True)
    return _cfjs.invoke(_connect[0], (address, options))


def _error(e, host, port):
    message = getattr(e, "message", None) or str(e)
    if "refused" in message.lower() or "connect" in message.lower():
        return ConnectionRefusedError(errno.ECONNREFUSED, f"{message} ({host}:{port})")
    return OSError(errno.EIO, message)


class socket:
    """A TCP socket over cloudflare:sockets."""

    def __init__(self, family=_std.AF_INET, type=_std.SOCK_STREAM, proto=0, fileno=None):
        if type == getattr(_std, "SOCK_DGRAM", None):
            raise OSError(errno.EPROTONOSUPPORT, "only TCP (SOCK_STREAM) sockets are supported")
        self.family = _std.AddressFamily(family) if family else _std.AF_INET
        self.type = _std.SOCK_STREAM
        self.proto = proto
        self._fd = next(_fds)
        self._timeout = _std.getdefaulttimeout()
        self._js = self._reader = self._writer = None
        self._buf = b""
        self._eof = False
        self._reading = None  # an unfinished read's Future, from a non-blocking recv
        self._peer = None
        self._closed = False
        self._io_refs = 0

    # ---- connecting ----

    def _open(self, host, port):
        self._peer = (host, port)
        self._js = _js_connect(host, port)
        return _cfjs.getattr(self._js, "opened")

    def _streams(self):
        self._reader = _cfjs.call(_cfjs.getattr(self._js, "readable"), "getReader", ())
        self._writer = _cfjs.call(_cfjs.getattr(self._js, "writable"), "getWriter", ())

    async def _aconnect(self, address):
        host, port = address[0], int(address[1])
        try:
            await self._open(host, port)
        except Exception as e:
            raise _error(e, host, port) from None
        self._streams()

    def connect(self, address):
        _block(self._aconnect(address))

    def connect_ex(self, address):
        try:
            self.connect(address)
            return 0
        except OSError as e:
            return e.errno or errno.ECONNREFUSED

    async def _aupgrade(self, server_hostname):
        """Upgrades to TLS with startTls(), for ssl.wrap_socket."""
        try:
            _cfjs.call(self._reader, "releaseLock", ())
            _cfjs.call(self._writer, "releaseLock", ())
        except Exception:
            pass
        options = _cfjs.new_object()
        if server_hostname:
            _cfjs.set(options, "expectedServerHostname", server_hostname)
        self._js = _cfjs.call(self._js, "startTls", (options,))
        try:
            await _cfjs.getattr(self._js, "opened")
        except Exception as e:
            import ssl

            raise ssl.SSLError(str(e)) from None
        self._streams()

    # ---- reading ----

    def _read_future(self):
        from _cf_runtime import _await_promise

        if self._reading is None:
            self._reading = _await_promise(_cfjs.call(self._reader, "read", ()))
        return self._reading

    def _take(self, result, n):
        self._reading = None
        if _cfjs.get(result, "done"):
            self._eof = True
        else:
            value = _cfjs.get(result, "value")
            self._buf += value.to_bytes() if hasattr(value, "to_bytes") else bytes(value)
        return self._from_buf(n)

    def _from_buf(self, n):
        out, self._buf = self._buf[:n], self._buf[n:]
        return out

    async def _arecv(self, n):
        self._check()
        while not self._buf and not self._eof:
            self._take(await self._read_future(), 0)
        return self._from_buf(n)

    def recv(self, n, flags=0):
        self._check()
        if self._buf or self._eof:
            return self._from_buf(n)
        if self._timeout == 0:
            fut = self._read_future()
            if not fut.done():
                raise BlockingIOError(errno.EAGAIN, "Resource temporarily unavailable")
            return self._take(fut.result(), n)
        return _block(self._arecv(n), self._timeout)

    def recv_into(self, buffer, nbytes=0, flags=0):
        view = memoryview(buffer).cast("B")
        data = self.recv(nbytes or len(view))
        view[: len(data)] = data
        return len(data)

    # ---- writing ----

    async def _asend(self, data):
        self._check()
        if self._writer is None:
            raise OSError(errno.ENOTCONN, "Socket is not connected")
        await _cfjs.call(self._writer, "write", (bytes(data),))

    def sendall(self, data, flags=0):
        _block(self._asend(data), self._timeout)

    def send(self, data, flags=0):
        self.sendall(data)
        return len(data)

    # ---- the rest of the socket API ----

    def _check(self):
        if self._closed:
            raise OSError(errno.EBADF, "Bad file descriptor")

    def settimeout(self, value):
        self._timeout = None if value is None else float(value)

    def gettimeout(self):
        return self._timeout

    def setblocking(self, flag):
        self._timeout = None if flag else 0.0

    def getblocking(self):
        return self._timeout != 0

    def fileno(self):
        return -1 if self._closed else self._fd

    def getpeername(self):
        if self._peer is None:
            raise OSError(errno.ENOTCONN, "Socket is not connected")
        return self._peer

    def getsockname(self):
        return ("0.0.0.0", 0)

    def setsockopt(self, *args):
        pass

    def getsockopt(self, *args):
        return 0

    def shutdown(self, how):
        if self._writer is not None and how in (_std.SHUT_WR, _std.SHUT_RDWR):
            _cfjs.call(self._writer, "close", ())
            self._writer = None
        if how in (_std.SHUT_RD, _std.SHUT_RDWR):
            self._eof = True

    def close(self):
        if self._closed:
            return
        self._closed = True
        if self._io_refs <= 0 and self._js is not None:
            try:
                _cfjs.call(self._js, "close", ())
            except Exception:
                pass

    def detach(self):
        self._closed = True
        return -1

    def __enter__(self):
        return self

    def __exit__(self, *args):
        self.close()

    def __repr__(self):
        return f"<socket fd={self.fileno()} family={self.family!r} type={self.type!r} peer={self._peer}>"

    # makefile() and its reference counting, as in the stdlib.
    makefile = _std.socket.makefile

    def _decref_socketios(self):
        if self._io_refs > 0:
            self._io_refs -= 1
        if self._closed and self._io_refs <= 0 and self._js is not None:
            try:
                _cfjs.call(self._js, "close", ())
            except Exception:
                pass

    _real_close = close


def _block(aw, timeout=None):
    from _cf_runtime import _run

    if timeout is not None and timeout > 0:
        import asyncio

        aw = asyncio.wait_for(aw, timeout)
    try:
        return _run(aw)
    except TimeoutError:
        raise _std.timeout("timed out") from None


def getaddrinfo(host, port, family=0, type=0, proto=0, flags=0):
    # cloudflare:sockets resolves the name itself when it connects.
    if isinstance(host, bytes):
        host = host.decode()
    if isinstance(port, str):
        port = int(port) if port.isdigit() else {"http": 80, "https": 443}[port]
    return [(_std.AF_INET, _std.SOCK_STREAM, _std.IPPROTO_TCP, "", (host, port))]


def gethostbyname(host):
    # WASI's socket module has none. There is no resolver to ask: an IPv4
    # literal is its own address, and a name fails as unresolvable (Pyodide
    # gives a placeholder address that no connection reaches). Callers such as
    # urllib's FTP handler turn the OSError into their own error.
    import ipaddress

    try:
        return str(ipaddress.IPv4Address(host))
    except ValueError:
        raise _std.gaierror(getattr(_std, "EAI_NONAME", -2), "Name or service not known") from None


def patch(module):
    module.socket = module.SocketType = socket
    module.getaddrinfo = getaddrinfo
    module.gethostbyname = gethostbyname
