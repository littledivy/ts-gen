"""pyodide.code on the WASI runtime."""

from _cf_runtime import relaxed_call  # noqa: F401


def relaxed_wrap(func):
    import functools

    @functools.wraps(func)
    def wrapper(*args, **kwargs):
        return relaxed_call(func, *args, **kwargs)

    return wrapper
