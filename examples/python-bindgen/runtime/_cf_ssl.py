"""The ssl module over cloudflare:sockets' startTls(), as Python Workers
provide it: there is no OpenSSL here. wrap_socket upgrades a socket from
_cf_sockets in place; workerd verifies the certificate, against the name
given as server_hostname, whatever verify_mode says. The ssl module this
replaces is the stdlib's, which needs _ssl.
"""

import enum
import os

OPENSSL_VERSION = "workerd startTls"
OPENSSL_VERSION_INFO = (3, 0, 0, 0, 0)
OPENSSL_VERSION_NUMBER = 0x30000000
HAS_SNI = True
HAS_ALPN = False
HAS_NEVER_CHECK_COMMON_NAME = True
HAS_TLSv1_3 = True
HAS_ECDH = True
HAS_NPN = False
CHANNEL_BINDING_TYPES = []


class VerifyMode(enum.IntEnum):
    CERT_NONE = 0
    CERT_OPTIONAL = 1
    CERT_REQUIRED = 2


CERT_NONE, CERT_OPTIONAL, CERT_REQUIRED = VerifyMode


class VerifyFlags(enum.IntFlag):
    VERIFY_DEFAULT = 0
    VERIFY_CRL_CHECK_LEAF = 0x4
    VERIFY_CRL_CHECK_CHAIN = 0xC
    VERIFY_X509_STRICT = 0x20
    VERIFY_X509_TRUSTED_FIRST = 0x8000
    VERIFY_X509_PARTIAL_CHAIN = 0x80000


globals().update(VerifyFlags.__members__)


class _SSLMethod(enum.IntEnum):
    PROTOCOL_TLS = 2
    PROTOCOL_TLS_CLIENT = 16
    PROTOCOL_TLS_SERVER = 17


PROTOCOL_TLS, PROTOCOL_TLS_CLIENT, PROTOCOL_TLS_SERVER = _SSLMethod
PROTOCOL_SSLv23 = PROTOCOL_TLS


class Options(enum.IntFlag):
    OP_ALL = 0x80000054
    OP_NO_SSLv2 = 0
    OP_NO_SSLv3 = 0x2000000
    OP_NO_TLSv1 = 0x4000000
    OP_NO_TLSv1_1 = 0x10000000
    OP_NO_TLSv1_2 = 0x8000000
    OP_NO_TLSv1_3 = 0x20000000
    OP_NO_COMPRESSION = 0x20000
    OP_NO_TICKET = 0x4000
    OP_NO_RENEGOTIATION = 0x40000000
    OP_CIPHER_SERVER_PREFERENCE = 0x400000
    OP_SINGLE_DH_USE = 0
    OP_SINGLE_ECDH_USE = 0
    OP_ENABLE_MIDDLEBOX_COMPAT = 0x100000
    OP_IGNORE_UNEXPECTED_EOF = 0x80


globals().update(Options.__members__)


class TLSVersion(enum.IntEnum):
    MINIMUM_SUPPORTED = -2
    SSLv3 = 0x300
    TLSv1 = 0x301
    TLSv1_1 = 0x302
    TLSv1_2 = 0x303
    TLSv1_3 = 0x304
    MAXIMUM_SUPPORTED = -1


class Purpose(enum.Enum):
    SERVER_AUTH = "1.3.6.1.5.5.7.3.1"
    CLIENT_AUTH = "1.3.6.1.5.5.7.3.2"


class SSLError(OSError):
    pass


class SSLZeroReturnError(SSLError):
    pass


class SSLWantReadError(SSLError):
    pass


class SSLWantWriteError(SSLError):
    pass


class SSLSyscallError(SSLError):
    pass


class SSLEOFError(SSLError):
    pass


class SSLCertVerificationError(SSLError, ValueError):
    pass


CertificateError = SSLCertVerificationError


class SSLContext:
    def __init__(self, protocol=PROTOCOL_TLS_CLIENT, *args, **kwargs):
        self.protocol = protocol
        client = protocol != PROTOCOL_TLS_SERVER
        self.check_hostname = client
        self.verify_mode = CERT_REQUIRED if client else CERT_NONE
        self.verify_flags = VERIFY_DEFAULT
        self.options = OP_ALL
        self.minimum_version = TLSVersion.MINIMUM_SUPPORTED
        self.maximum_version = TLSVersion.MAXIMUM_SUPPORTED
        self.post_handshake_auth = None
        self.hostname_checks_common_name = False
        self.keylog_filename = None
        self.sni_callback = None

    def load_default_certs(self, purpose=Purpose.SERVER_AUTH):
        pass

    def load_verify_locations(self, cafile=None, capath=None, cadata=None):
        pass

    def set_default_verify_paths(self):
        pass

    def load_cert_chain(self, certfile, keyfile=None, password=None):
        raise NotImplementedError("client certificates are not supported by cloudflare:sockets")

    def set_ciphers(self, ciphers):
        pass

    def set_alpn_protocols(self, protocols):
        pass

    def set_ecdh_curve(self, name):
        pass

    def get_ca_certs(self, binary_form=False):
        return []

    def cert_store_stats(self):
        return {"crl": 0, "x509": 0, "x509_ca": 0}

    def wrap_socket(self, sock, server_side=False, do_handshake_on_connect=True,
                    suppress_ragged_eofs=True, server_hostname=None, session=None):
        if server_side:
            raise NotImplementedError("TLS servers are not supported by cloudflare:sockets")
        from _cf_runtime import _run

        if not hasattr(sock, "_aupgrade"):
            raise TypeError("wrap_socket takes a socket from the socket module")
        _run(sock._aupgrade(server_hostname))
        sock.__class__ = SSLSocket
        sock.server_hostname = server_hostname
        sock.context = self
        return sock


class SSLSocket:
    """A socket upgraded by SSLContext.wrap_socket. Its class is set on the
    socket itself, so it is also a socket.socket."""

    def do_handshake(self):
        pass

    def version(self):
        return "TLSv1.3"

    def cipher(self):
        return None

    def selected_alpn_protocol(self):
        return None

    def getpeercert(self, binary_form=False):
        return {} if not binary_form else None

    def unwrap(self):
        return self

    def pending(self):
        return len(self._buf)


def _make_sslsocket_class():
    # SSLSocket is a socket.socket, so that isinstance checks hold.
    import socket

    global SSLSocket
    SSLSocket = type("SSLSocket", (SSLSocket, socket.socket), {})


_make_sslsocket_class()


def create_default_context(purpose=Purpose.SERVER_AUTH, *, cafile=None, capath=None, cadata=None):
    return SSLContext(PROTOCOL_TLS_CLIENT if purpose == Purpose.SERVER_AUTH else PROTOCOL_TLS_SERVER)


_create_default_https_context = create_default_context
_create_stdlib_context = create_default_context


def get_default_verify_paths():
    return None


def match_hostname(cert, hostname):
    pass


def DER_cert_to_PEM_cert(der):
    raise NotImplementedError


def PEM_cert_to_DER_cert(pem):
    raise NotImplementedError


def RAND_bytes(n):
    return os.urandom(n)


def RAND_status():
    return True


class MemoryBIO:
    def __init__(self):
        raise NotImplementedError("ssl.MemoryBIO needs OpenSSL, which isn't available here")


class SSLObject:
    def __init__(self, *args, **kwargs):
        raise NotImplementedError("ssl.SSLObject needs OpenSSL, which isn't available here")


class SSLSession:
    pass
