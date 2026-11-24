"""Lets the top level make a fixed number of entropy calls."""

import _cf_runtime

# The message import_patch_manager's blocked calls raise with.
TOP_LEVEL_ENTROPY_ERROR = _cf_runtime._ENTROPY_MSG


def allow_bad_entropy_calls(n):
    """A context manager letting the top level make exactly `n` host entropy
    calls (getentropy, os.urandom, native packages' seeds), as in Pyodide; it
    fails if fewer were made."""
    return _cf_runtime._allow_entropy(n)
