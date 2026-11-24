"""MarkupSafe's C speedups on the WASI Python Worker."""

import markupsafe
from markupsafe import _speedups

from workers import Response, WorkerEntrypoint


class Default(WorkerEntrypoint):
    async def fetch(self, request):
        return Response.json({
            "escaped": str(markupsafe.escape("<b>\"hi\" & 'bye'</b>")),
            # "built-in": the C extension linked into the module.
            "speedups": _speedups.__spec__.origin,
        })
