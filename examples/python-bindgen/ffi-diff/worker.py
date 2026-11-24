from workers import Response, WorkerEntrypoint

import probe


class Default(WorkerEntrypoint):
    async def fetch(self, request):
        path = request.url.split("/", 3)[3] if request.url.count("/") >= 3 else ""
        if path == "stash":
            return Response(probe.stash())
        if path == "after":
            return Response(probe.after())
        return Response(await probe.run())
