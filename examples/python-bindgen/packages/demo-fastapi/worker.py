"""FastAPI on the WASI Python Worker: JSON, a path parameter, a validated
POST body and FastAPI's own 404."""

from fastapi import FastAPI
from pydantic import BaseModel, Field

import asgi
from workers import WorkerEntrypoint

app = FastAPI()


class Item(BaseModel):
    name: str = Field(min_length=1)
    price: float = Field(gt=0)
    tags: list[str] = []


@app.get("/")
async def root():
    return {"message": "Hello from FastAPI on WASI"}


@app.get("/items/{item_id}")
async def read_item(item_id: int, q: str | None = None):
    return {"item_id": item_id, "q": q}


@app.post("/items")
async def create_item(item: Item):
    return {"created": item.model_dump(), "total": round(item.price * 1.2, 2)}


@app.get("/env")
async def env_var(request: __import__("fastapi").Request):
    return {"greeting": getattr(request.scope["env"], "GREETING", None)}


class Default(WorkerEntrypoint):
    async def fetch(self, request):
        return await asgi.fetch(app, request, self.env)
