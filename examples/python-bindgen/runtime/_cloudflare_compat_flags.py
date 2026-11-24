"""The Worker's compatibility flags, read from Cloudflare.compatibilityFlags.

While the snapshot is built there is no JS, and the flags are the ones
build.sh resolved for the build's compatibility date and flags
(_cf_config.COMPAT_FLAGS).
"""

import _cfjs
import _cfvfs


def __getattr__(name):
    if name.startswith("__"):
        raise AttributeError(name)
    if not _cfvfs.active():
        try:
            import _cf_config
        except ImportError:
            return False
        return bool(getattr(_cf_config, "COMPAT_FLAGS", {}).get(name, False))
    flags = _cfjs.get(_cfjs.getattr(_cfjs.lazy("globalThis"), "Cloudflare"), "compatibilityFlags")
    return bool(_cfjs.get(flags, name))
