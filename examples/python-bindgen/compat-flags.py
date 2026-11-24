"""The compatibility flags the snapshot is built with, for build.sh:

    python3 compat-flags.py DATE [FLAG...]

prints, as a Python dict, each flag the runtime or the SDK asks about
before the snapshot is taken, on or off for a Worker with this
compatibility date and these compatibility_flags, as workerd decides it
(src/workerd/io/compatibility-date.capnp). A flag that isn't in the table
is on when it is given. After the snapshot, flags come from the Worker's
own Cloudflare.compatibilityFlags instead.
"""

import sys

# name: (enable date, disable flag, (implying flag, after date))
TABLE = {
    "python_workers": (None, None, ("python_workers_development", "2000-01-01")),
    "python_workflows": (None, "disable_python_workflows", ("python_workers", "2025-09-20")),
    "python_no_global_handlers": ("2025-08-14", "disable_python_no_global_handlers", None),
    "python_workers_force_new_vendor_path": ("2025-08-11", None, None),
    "python_dedicated_snapshot": (None, "disable_python_dedicated_snapshot", ("python_workers_20250116", "2025-10-16")),
    "python_workers_20250116": (None, "no_python_workers_20250116", ("python_workers", "2025-09-29")),
    "python_check_rng_state": (None, "disable_python_check_rng_state", ("python_workers", "2025-12-16")),
    "python_workflows_implicit_dependencies": (None, "no_python_workflows_implicit_dependencies", ("python_workers", "2026-02-25")),
    "python_request_headers_preserve_commas": ("2026-02-17", "disable_python_request_headers_preserve_commas", None),
    "python_process_pth_files": ("2026-05-26", "disable_python_process_pth_files", None),
    "python_shared_standard_library": (None, None, ("python_workers", "2026-11-19")),
    "python_dedicated_snapshot_keep_import_caches": (
        None,
        "no_python_dedicated_snapshot_keep_import_caches",
        ("python_workers", "2026-12-10"),
    ),
}


def resolve(date, given):
    on = {}

    def flag(name):
        if name in on:
            return on[name]
        enable, disable, implied = TABLE.get(name, (None, None, None))
        if name in given:
            v = True
        elif disable is not None and disable in given:
            v = False
        else:
            v = bool(enable and date >= enable) or bool(implied and date >= implied[1] and flag(implied[0]))
        on[name] = v
        return v

    return {name: flag(name) for name in sorted(set(TABLE) | set(given))}


if __name__ == "__main__":
    date = sys.argv[1]
    given = {f for a in sys.argv[2:] for f in a.replace(",", " ").split()}
    print(repr(resolve(date, given)))
