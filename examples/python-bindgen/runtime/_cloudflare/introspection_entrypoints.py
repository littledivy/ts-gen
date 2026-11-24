"""Finds the entry point classes an app's main module exports."""

import inspect
import types


def _getattr_no_get(cls, name):
    for base in cls.__mro__:
        if name in base.__dict__:
            return base.__dict__[name]
    return None


def _collect_methods(cls):
    return sorted(
        n for n in dir(cls) if not n.startswith("_") and isinstance(_getattr_no_get(cls, n), types.FunctionType)
    )


def collect_entrypoint_classes(mod):
    """{name: (kind, class, methods)} for the app's module."""
    from workers import DurableObject, WorkerEntrypoint, WorkflowEntrypoint

    keys = mod.__all__ if hasattr(mod, "__all__") else [k for k in dir(mod) if not k.startswith("_")]
    found = {}
    for k in keys:
        v = getattr(mod, k, None)
        if not inspect.isclass(v):
            continue
        for base, kind in ((DurableObject, "durable-object"), (WorkerEntrypoint, "entrypoint"), (WorkflowEntrypoint, "workflow")):
            if issubclass(v, base) and v is not base:
                found[v.__name__] = (kind, v, _collect_methods(v))
                break
    return found


class CpuLimitExceeded(BaseException):
    pass


def raise_cpu_limit_exceeded(signum, frame):
    raise CpuLimitExceeded("Python Worker exceeded CPU time limit")


# As in Pyodide's introspection module. Here the host stops a Worker over its
# CPU limit itself, so the signal doesn't arrive; the handler is in place for
# code that checks it.
try:
    import signal

    signal.signal(signal.SIGXCPU, raise_cpu_limit_exceeded)
except (AttributeError, ValueError, OSError):
    pass
