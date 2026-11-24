"""The Worker's compatibility flags, read from Cloudflare.compatibilityFlags."""

import _cfjs


def __getattr__(name):
    if name.startswith("__"):
        raise AttributeError(name)
    flags = _cfjs.get(_cfjs.getattr(_cfjs.lazy("globalThis"), "Cloudflare"), "compatibilityFlags")
    return bool(_cfjs.get(flags, name))
