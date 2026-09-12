import asyncio
import itertools
import json
import logging

from websockets.asyncio.client import connect

log = logging.getLogger("matter.client")


class MatterServerError(Exception):
    pass


class MatterClient:
    def __init__(self, url: str, debug_jsonl: str | None = None):
        self.url = url
        self.debug_jsonl = debug_jsonl
        self.server_info: dict = {}
        self.event_handler = None
        self._ws = None
        self._recv_task = None
        self._pending: dict[str, asyncio.Future] = {}
        self._ids = itertools.count(1)
        self._debug_file = None

    async def connect(self):
        self._ws = await connect(
            self.url,
            ping_interval=30,
            ping_timeout=20,
            max_size=None,
            open_timeout=20,
        )
        if self.debug_jsonl:
            self._debug_file = open(self.debug_jsonl, "a", encoding="utf-8")
        self._recv_task = asyncio.create_task(self._recv_loop())

    async def close(self):
        if self._recv_task:
            self._recv_task.cancel()
        if self._ws:
            await self._ws.close()
        if self._debug_file:
            self._debug_file.close()
            self._debug_file = None

    async def wait_closed(self):
        if self._recv_task:
            await self._recv_task

    async def command(self, command: str, args: dict | None = None, timeout: float = 30.0):
        if self._ws is None:
            raise MatterServerError("not connected")
        mid = str(next(self._ids))
        fut = asyncio.get_running_loop().create_future()
        self._pending[mid] = fut
        await self._ws.send(json.dumps({"message_id": mid, "command": command, "args": args or {}}))
        try:
            resp = await asyncio.wait_for(fut, timeout)
        except TimeoutError:
            self._pending.pop(mid, None)
            raise
        if "result" in resp:
            return resp["result"]
        raise MatterServerError(
            f"{command} failed: error_code={resp.get('error_code')} details={resp.get('details')}"
        )

    async def _recv_loop(self):
        close_code = close_reason = None
        try:
            async for raw in self._ws:
                if self._debug_file:
                    self._debug_file.write(raw + "\n")
                    self._debug_file.flush()
                msg = json.loads(raw)
                mid = msg.get("message_id")
                fut = self._pending.pop(mid, None) if mid is not None else None
                if fut is not None and not fut.done():
                    fut.set_result(msg)
                elif "event" in msg:
                    if self.event_handler is not None:
                        await self.event_handler(msg)
                else:
                    self.server_info = msg
                    log.info(
                        "server: fabric=%s schema=v%s sdk=%s",
                        msg.get("compressed_fabric_id"),
                        msg.get("schema_version"),
                        msg.get("sdk_version"),
                    )
        except Exception as e:
            for fut in self._pending.values():
                if not fut.done():
                    fut.set_exception(e)
            self._pending.clear()
            raise
        finally:
            for fut in self._pending.values():
                if not fut.done():
                    fut.set_exception(MatterServerError("connection closed"))
            self._pending.clear()
            close_code = getattr(self._ws, "close_code", None)
            close_reason = getattr(self._ws, "close_reason", None)
            log.info("connection closed: code=%s reason=%s", close_code, close_reason)
