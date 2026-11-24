"""The part of Pyodide's _pyodide_core that Python Workers tests use."""


def trigger_fatal_error():
    """Fails as Pyodide's fatal errors do: the runtime's on_fatal handler
    aborts the isolate (_cf_runtime.on_fatal)."""
    from _cf_runtime import on_fatal

    on_fatal(SystemError("trigger_fatal_error() was called"))
