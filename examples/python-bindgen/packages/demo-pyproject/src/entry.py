# A Worker laid out as Python Workers' templates are: pyproject.toml lists
# the dependencies, and `wrangler dev` builds them in (wrangler.toml's
# [build] runs ../../build.sh, which syncs pyproject.toml).
import msgspec
import yaml
from dateutil import parser

from workers import Response, WorkerEntrypoint


class Event(msgspec.Struct):
    name: str
    at: str


class Default(WorkerEntrypoint):
    async def fetch(self, request):
        doc = yaml.safe_load("name: launch\nat: \"2026-11-24T10:00:00Z\"\n")
        event = msgspec.convert(doc, Event)
        when = parser.isoparse(event.at)
        body = msgspec.json.encode({"event": event, "weekday": when.strftime("%A"), "libyaml": yaml.__with_libyaml__})
        return Response(body.decode(), headers={"content-type": "application/json"})
