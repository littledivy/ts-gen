"""numpy on the WASI Python Worker."""

import numpy as np

# numpy loads these lazily; import them here so the build-time snapshot has them.
import numpy.fft
import numpy.linalg
import numpy.random

from workers import Response, WorkerEntrypoint


def routes(path):
    if path == "/":
        return {"numpy": np.__version__, "sum": int(np.arange(10).sum())}
    if path == "/matmul":
        a = np.arange(6, dtype=np.float64).reshape(2, 3)
        b = np.arange(6, dtype=np.float64).reshape(3, 2)
        return {"matmul": (a @ b).tolist()}
    if path == "/ufunc":
        x = np.linspace(0, np.pi, 5)
        return {"sin": np.round(np.sin(x), 6).tolist(), "add_reduce": float(np.add.reduce(x))}
    if path == "/linalg":
        a = np.array([[3.0, 1.0], [1.0, 2.0]])
        return {"solve": np.linalg.solve(a, np.array([9.0, 8.0])).tolist(), "det": round(float(np.linalg.det(a)), 6)}
    if path == "/fft":
        return {"fft": np.round(np.abs(np.fft.fft([1.0, 0.0, -1.0, 0.0])), 6).tolist()}
    if path == "/random":
        g = np.random.default_rng(42)
        return {"normal": np.round(g.normal(size=3), 6).tolist(), "integers": g.integers(0, 100, 3).tolist()}
    return None


class Default(WorkerEntrypoint):
    async def fetch(self, request):
        path = request.url.split("://", 1)[-1].partition("/")[2].partition("?")[0]
        body = routes("/" + path)
        return Response.json(body) if body is not None else Response("not found\n", 404)
