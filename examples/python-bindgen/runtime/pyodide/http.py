"""pyodide.http on the WASI runtime: pyfetch and FetchResponse."""

import json as _json

import js
from _cf_runtime import JsException, to_js


class BodyUsedError(OSError):
    pass


class HttpStatusError(OSError):
    def __init__(self, status, status_text, url):
        self.status = status
        self.status_text = status_text
        self.url = url
        super().__init__(f"{status} {'Client' if status < 500 else 'Server'} Error: {status_text} for url: {url}")


class FetchResponse:
    """A JS Response, with Pyodide's Python API."""

    def __init__(self, url, js_response, abort_controller=None, abort_signal=None):
        self._url = url
        self.js_response = js_response
        self.abort_controller = abort_controller
        self.abort_signal = abort_signal

    @property
    def body_used(self):
        return self.js_response.bodyUsed

    @property
    def headers(self):
        return {k: v for k, v in self.js_response.headers}

    @property
    def ok(self):
        return self.js_response.ok

    @property
    def redirected(self):
        return self.js_response.redirected

    @property
    def status(self):
        return self.js_response.status

    @property
    def status_text(self):
        return self.js_response.statusText

    @property
    def type(self):
        return self.js_response.type

    @property
    def url(self):
        return self.js_response.url

    def _raise_if_failed(self):
        if self.js_response.bodyUsed:
            raise BodyUsedError("Body already used")

    def raise_for_status(self):
        if 400 <= self.status < 600:
            raise HttpStatusError(self.status, self.status_text, self.url)

    def clone(self):
        if self.js_response.bodyUsed:
            raise BodyUsedError("Body already used")
        return type(self)(self._url, self.js_response.clone())

    async def buffer(self):
        self._raise_if_failed()
        return await self.js_response.arrayBuffer()

    async def text(self):
        self._raise_if_failed()
        return await self.js_response.text()

    async def string(self):
        return await self.text()

    async def json(self, **kwargs):
        self._raise_if_failed()
        return _json.loads(await self.text(), **kwargs)

    async def memoryview(self):
        return memoryview(await self.bytes())

    async def bytes(self):
        self._raise_if_failed()
        return bytes(await self.js_response.arrayBuffer())

    def abort(self, reason=None):
        if self.abort_controller is not None:
            self.abort_controller.abort(reason)


async def pyfetch(url, **kwargs):
    fetcher = kwargs.pop("fetcher", None) or js.fetch
    try:
        return FetchResponse(url, await fetcher(url, to_js(kwargs, dict_converter=js.Object.fromEntries)))
    except JsException as e:
        raise OSError(e.message) from None
