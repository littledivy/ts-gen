"""The socket module over cloudflare:sockets, as Python Workers provide it.

patch() replaces socket.socket and the resolver calls, as Pyodide's
(Emscripten's) socket module has them, and its constants: a socket is a TCP
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
    # An address the resolver made up connects to the name it stands for.
    host = _names.get(host, host)
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

    def __init__(self, family=-1, type=-1, proto=0, fileno=None):
        if family == -1:
            family = _std.AF_INET
        if type == -1:
            type = _std.SOCK_STREAM
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


# The resolver, as Emscripten's (Pyodide's): there is no DNS, so a name
# gets a made-up address, 172.29.<n>.0 for the n-th name looked up, which
# connecting maps back to the name (cloudflare:sockets resolves it then).
_addrs = {}  # name -> made-up address
_names = {}  # made-up address -> name
_next_addr = [0]


def _is_ipv4(host):
    import ipaddress

    try:
        ipaddress.IPv4Address(host)
    except ValueError:
        return False
    return True


def _lookup(name):
    if _is_ipv4(name):
        return name
    addr = _addrs.get(name)
    if addr is None:
        _next_addr[0] += 1
        n = _next_addr[0]
        # Emscripten's spelling, which for n > 255 isn't a dotted quad.
        addr = f"172.29.{n & 0xFF}.{n & 0xFF00}"
        _addrs[name] = addr
        _names[addr] = name
    return addr


def _host(host):
    if isinstance(host, (bytes, bytearray)):
        host = bytes(host).decode()
    if not isinstance(host, str):
        raise TypeError(f"str, bytes or bytearray expected, not {type(host).__name__}")
    return host


def getaddrinfo(host, port, family=0, type=0, proto=0, flags=0):
    if isinstance(port, (bytes, bytearray)):
        port = bytes(port).decode()
    if isinstance(port, str):
        if port.isdigit():
            port = int(port)
        else:
            try:
                port = getservbyname(port)
            except OSError:
                raise _std.gaierror(getattr(_std, "EAI_SERVICE", -8), "Servname not supported for ai_socktype") from None
    if port is None:
        port = 0
    if host is None:
        addr = "0.0.0.0" if flags & getattr(_std, "AI_PASSIVE", 1) else "127.0.0.1"
    else:
        addr = _lookup(_host(host))
    return [(_std.AF_INET, _std.SOCK_STREAM, _std.IPPROTO_TCP, "", (addr, port))]


def getservbyname(name, proto=None):
    ports = {"http": 80, "https": 443, "ftp": 21, "ssh": 22, "smtp": 25, "domain": 53, "imap": 143, "imaps": 993,
             "pop3": 110, "pop3s": 995, "smtps": 465, "submission": 587}
    if name not in ports:
        raise OSError("service/proto not found")
    return ports[name]


def gethostbyname(host):
    return _lookup(_host(host))


def gethostbyname_ex(host):
    host = _host(host)
    return (host, [host], [_lookup(host)])


def gethostbyaddr(addr):
    addr = _host(addr)
    if not _is_ipv4(addr):
        raise _std.herror(1, "Unknown host")
    return gethostbyname_ex(_names.get(addr, addr))


def gethostname():
    return "emscripten"


def getnameinfo(sockaddr, flags):
    host, port = sockaddr[0], sockaddr[1]
    return (_names.get(host, host), str(port))


# Emscripten's values, which Pyodide's socket module has: WASI numbers
# address families and socket types differently.
_FAMILIES = {"AF_UNSPEC": 0, "AF_UNIX": 1, "AF_INET": 2, "AF_INET6": 10}
_KINDS = {"SOCK_STREAM": 1, "SOCK_DGRAM": 2, "SOCK_RAW": 3, "SOCK_SEQPACKET": 5}


def _constants(module):
    import enum

    wasi = {name: getattr(module, name) for name in _FAMILIES if hasattr(module, name)}
    module.AddressFamily = enum.IntEnum("AddressFamily", _FAMILIES, module="socket")
    module.SocketKind = enum.IntEnum("SocketKind", _KINDS, module="socket")
    for name in _FAMILIES:
        setattr(module, name, module.AddressFamily[name])
    for name in _KINDS:
        setattr(module, name, module.SocketKind[name])
    # The C functions taking a family still want WASI's numbers.
    to_wasi = {_FAMILIES[name]: v for name, v in wasi.items()}
    inet_pton, inet_ntop = module.inet_pton, module.inet_ntop

    def pton(family, ip):
        return inet_pton(to_wasi.get(family, family), ip)

    def ntop(family, packed):
        return inet_ntop(to_wasi.get(family, family), packed)

    pton.__name__, ntop.__name__ = "inet_pton", "inet_ntop"
    module.inet_pton, module.inet_ntop = pton, ntop
    module.has_ipv6 = False


def patch(module):
    _constants(module)
    module.socket = module.SocketType = socket
    module.getaddrinfo = getaddrinfo
    module.gethostbyname = gethostbyname
    module.gethostbyname_ex = gethostbyname_ex
    module.gethostbyaddr = gethostbyaddr
    module.gethostname = gethostname
    module.getnameinfo = getnameinfo
    module.getservbyname = getservbyname
