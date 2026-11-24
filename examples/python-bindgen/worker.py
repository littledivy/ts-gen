"""The spec Worker (e2e.sh checks it), in Python, on the Python Workers SDK."""

import json
from urllib.parse import urlsplit

from js import Date, console
from workers import DurableObject, Response, WorkerEntrypoint, fetch


def _json(data, status=200):
    return Response(json.dumps(data, separators=(",", ":")), status=status, headers={"content-type": "application/json"})


def _origin(url):
    u = urlsplit(url)
    return f"{u.scheme}://{u.netloc}"


async def _upstream(res):
    body = (await res.text()).removesuffix("\n")
    return _json({"status": res.status, "body": body})


class Default(WorkerEntrypoint):
    async def fetch(self, request):
        env = self.env
        path = urlsplit(request.url).path

        if path.startswith("/do/"):
            stub = env.COUNTER.get(env.COUNTER.idFromName(path[len("/do/") :]))
            res = await stub.fetch("https://counter/")
            return Response(await res.bytes(), status=res.status, headers={"content-type": "application/json"})

        if path == "/":
            greeting = getattr(env, "GREETING", None) or "Hello"
            return Response(f"{greeting} from Python!\n")

        if path == "/kv":
            n = int(await env.KV.get("n") or 0) + 1
            await env.KV.put("n", str(n))
            keys = (await env.KV.list()).keys
            return _json({"count": n, "keys": [k.name for k in keys]})

        if path == "/r2":
            await env.BUCKET.put("hello.txt", "hi from Python", httpMetadata={"contentType": "text/plain"})
            obj = await env.BUCKET.get("hello.txt")
            listed = await env.BUCKET.list()
            return _json(
                {
                    "key": obj.key,
                    "size": obj.size,
                    "contentType": obj.httpMetadata.contentType,
                    "body": await obj.text(),
                    "listed": len(listed.objects),
                }
            )

        if path == "/d1":
            await env.DB.exec("CREATE TABLE IF NOT EXISTS notes (id INTEGER PRIMARY KEY, body TEXT)")
            inserted = await env.DB.prepare("INSERT INTO notes (body) VALUES (?1)").bind("from Python").run()
            rows = await env.DB.prepare("SELECT COUNT(*) AS n FROM notes").first("n")
            return _json({"inserted": inserted.meta.last_row_id, "rows": rows})

        if path == "/fetch":
            return await _upstream(await fetch(_origin(request.url) + "/"))

        if path == "/service":
            return await _upstream(await env.SELF.fetch(_origin(request.url) + "/"))

        if path == "/queue":
            await env.QUEUE.send("hello")
            return _json({"sent": True})

        if path == "/log":
            console.log("hello from Python")
            return Response("logged")

        return Response("not found\n", status=404)


class Counter(DurableObject):
    async def fetch(self, request):
        storage = self.ctx.storage
        n = (await storage.get("n") or 0) + 1
        await storage.put("n", n)
        storage.sql.exec("CREATE TABLE IF NOT EXISTS hits (at INTEGER)")
        storage.sql.exec("INSERT INTO hits VALUES (?1)", n)
        hits = storage.sql.exec("SELECT COUNT(*) AS c FROM hits").one().c
        if not await storage.getAlarm():
            await storage.setAlarm(Date.now() + 60_000)
        return _json({"id": str(self.ctx.id), "count": n, "hits": hits, "alarm": True})

    async def alarm(self):
        print("alarm in Python")
