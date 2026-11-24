"""A Worker for soak/soak.mjs: each route does one thing that holds state
across the Python/JS boundary, so a soak shows whether that state is
released."""

import asyncio
import json
import os
import sys
from urllib.parse import parse_qs, urlsplit

import js
from js import Object, Promise, WebSocketPair
from pyodide.ffi import create_once_callable, create_proxy, to_js

from workers import DurableObject, Response, WorkerEntrypoint

# Grows with every request to /grow: a module-level leak on purpose, to check
# that the soak sees one.
_grown = []


def _json(data, status=200):
    return Response(json.dumps(data), status=status, headers={"content-type": "application/json"})


async def _background(n):
    await asyncio.sleep(0.001)
    return n


class Default(WorkerEntrypoint):
    async def fetch(self, request):
        u = urlsplit(request.url)
        path, q = u.path, parse_qs(u.query)

        if path == "/":
            return Response("ok")

        # A Python function passed to JS for the length of a call. JS calls
        # it while Python runs, so each call's result is a promise.
        if path == "/implicit":
            doubled = await Promise.all(js.Array.of(1, 2, 3).map(lambda x, *_: x * 2))
            return _json(doubled.to_py())

        # create_proxy, destroyed after use, as the SDK does with bodies.
        if path == "/proxy":
            px = create_proxy(lambda: 7)
            r = await js.Reflect.apply(px, None, js.Array.of())
            px.destroy()
            return _json(r)

        # create_proxy never destroyed.
        if path == "/proxy-kept":
            px = create_proxy(lambda: 7)
            return _json(await js.Reflect.apply(px, None, js.Array.of()))

        # A cycle across the boundary: a Python callback, stored on a JS
        # object, that holds that JS object.
        if path == "/cycle":
            o = Object.new()

            def cb(*_):
                return o.n

            o.n = 5
            o.cb = cb
            return _json(await o.cb())

        if path == "/cycle-proxy":
            o = Object.new()

            def cb2(*_):
                return o.n

            o.n = 6
            o.cb = create_proxy(cb2)
            return _json(await o.cb())

        # A JS promise whose then() calls back into Python.
        if path == "/then":
            p = Promise.resolve(3).then(create_once_callable(lambda v: v + 1))
            return _json(await p)

        # Concurrency within a request.
        if path == "/gather":
            r = await asyncio.gather(*(_background(i) for i in range(8)))
            return _json(sum(r))

        # Work that outlives the response.
        if path == "/wait-until":
            self.ctx.waitUntil(create_proxy(_background(1)))
            return Response("ok")

        # A task left running after the response, with nothing awaiting it.
        if path == "/orphan":
            asyncio.ensure_future(_background(2))
            return Response("ok")

        if path == "/raise":
            raise ValueError("raised on purpose")

        # A trap: the instance must be replaced.
        if path == "/trap":
            os.abort()

        # A trap after an await, while other requests are suspended in the
        # same instance.
        if path == "/trap-later":
            await asyncio.sleep(0.005)
            os.abort()

        if path == "/sleep":
            await asyncio.sleep(float(q.get("s", ["0.01"])[0]))
            return Response("ok")

        if path == "/grow":
            _grown.append(bytearray(1024))
            return _json(len(_grown))

        if path == "/mem":
            # Grows linear memory by n MiB of live Python objects, then frees
            # them: the high-water mark stays (Wasm memory can't shrink).
            n = int(q.get("n", ["8"])[0])
            junk = [bytearray(1 << 20) for _ in range(n)]
            size = sum(len(j) for j in junk)
            del junk
            return _json(size)

        if path.startswith("/do/"):
            name = path[len("/do/") :].split("/")[0]
            stub = self.env.SOAK.get(self.env.SOAK.idFromName(name))
            return await stub.fetch(request)

        return Response("not found", status=404)


class Soak(DurableObject):
    def __init__(self, ctx, env):
        super().__init__(ctx, env)
        # Long-lived state: bounded, and holding JS values across requests.
        self.recent = []
        self.storage = ctx.storage
        self.hits = 0

    async def fetch(self, request):
        path = urlsplit(request.url).path
        if path.endswith("/ws"):
            client, server = WebSocketPair.new().object_values()
            self.ctx.acceptWebSocket(server)
            return Response(None, status=101, web_socket=client)
        self.hits += 1
        n = (await self.storage.get("n") or 0) + 1
        await self.storage.put("n", n)
        self.storage.sql.exec("CREATE TABLE IF NOT EXISTS hits (at INTEGER)")
        self.storage.sql.exec("INSERT INTO hits VALUES (?1)", n)
        # The last 100 requests' headers, as JS objects.
        self.recent.append(request.headers)
        del self.recent[:-100]
        return _json({"n": n, "hits": self.hits, "recent": len(self.recent)})

    async def webSocketMessage(self, ws, message):
        self.hits += 1
        await self.storage.put("ws", self.hits)
        ws.send(f"echo {message} {self.hits}")

    async def webSocketClose(self, ws, code, reason, wasClean):
        ws.close(code, reason)
