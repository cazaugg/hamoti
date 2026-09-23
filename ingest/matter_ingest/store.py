import asyncio
import logging
from datetime import datetime, timezone
from pathlib import Path

import psycopg
from psycopg.types.json import Json

from .identity import build_node_row

log = logging.getLogger("matter.store")

# Bundled by the Dockerfile into /app. Applied idempotently on startup (in
# order) so a fresh database is never left without the tables, the cluster
# registry or the convenience views.
SCHEMA_FILES = [
    Path(__file__).resolve().parent.parent / "schema.sql",
    Path(__file__).resolve().parent.parent / "cluster_seed.sql",
]


def _split_statements(sql: str) -> list[str]:
    """Split a SQL script on semicolons, ignoring single-quoted strings and
    ``--`` line comments. Sufficient for schema.sql (no dollar-quoting)."""
    statements: list[str] = []
    buf: list[str] = []
    in_string = False
    i, n = 0, len(sql)
    while i < n:
        ch = sql[i]
        if in_string:
            buf.append(ch)
            in_string = ch != "'"
        elif ch == "'":
            buf.append(ch)
            in_string = True
        elif ch == "-" and i + 1 < n and sql[i + 1] == "-":
            newline = sql.find("\n", i)
            i = n if newline == -1 else newline
            continue
        elif ch == ";":
            statement = "".join(buf).strip()
            if statement:
                statements.append(statement)
            buf = []
        else:
            buf.append(ch)
        i += 1
    tail = "".join(buf).strip()
    if tail:
        statements.append(tail)
    return statements


UPSERT_NODE = """
INSERT INTO matter_nodes (
    node_id, device_uuid, identity_source, identity_value, label, vendor_id,
    vendor_name, product_id, product_name, serial_number, unique_id,
    thread_ext_address, available, date_commissioned, last_interview, last_seen, raw, updated_at
) VALUES (
    %(node_id)s, %(device_uuid)s, %(identity_source)s, %(identity_value)s, %(label)s, %(vendor_id)s,
    %(vendor_name)s, %(product_id)s, %(product_name)s, %(serial_number)s, %(unique_id)s,
    %(thread_ext_address)s, %(available)s, %(date_commissioned)s, %(last_interview)s, now(), %(raw)s, now()
)
ON CONFLICT (node_id) DO UPDATE SET
    device_uuid = EXCLUDED.device_uuid,
    identity_source = EXCLUDED.identity_source,
    identity_value = EXCLUDED.identity_value,
    label = EXCLUDED.label,
    vendor_id = EXCLUDED.vendor_id,
    vendor_name = EXCLUDED.vendor_name,
    product_id = EXCLUDED.product_id,
    product_name = EXCLUDED.product_name,
    serial_number = EXCLUDED.serial_number,
    unique_id = EXCLUDED.unique_id,
    thread_ext_address = EXCLUDED.thread_ext_address,
    available = EXCLUDED.available,
    date_commissioned = EXCLUDED.date_commissioned,
    last_interview = EXCLUDED.last_interview,
    last_seen = now(),
    raw = EXCLUDED.raw,
    updated_at = now()
"""


def _parse_ts(value):
    if not value:
        return None
    if isinstance(value, datetime):
        return value
    dt = datetime.fromisoformat(str(value))
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt


def _clean_row(row: dict) -> dict:
    out = dict(row)
    out["date_commissioned"] = _parse_ts(out.get("date_commissioned"))
    out["last_interview"] = _parse_ts(out.get("last_interview"))
    out["raw"] = Json(out.get("raw") or {})
    return out


class Store:
    def __init__(self, dsn: str, batch_size: int = 500, flush_interval: float = 1.0):
        self.dsn = dsn
        self.batch_size = batch_size
        self.flush_interval = flush_interval
        self._conn: psycopg.AsyncConnection | None = None
        self._queue: asyncio.Queue | None = None
        self._worker: asyncio.Task | None = None
        self._dropped = 0

    async def start(self):
        self._conn = await self._connect()
        await self._ensure_schema()
        self._queue = asyncio.Queue(maxsize=200_000)
        self._worker = asyncio.create_task(self._flush_loop())

    async def close(self):
        if self._worker:
            self._worker.cancel()
        if self._conn:
            try:
                await self._conn.close()
            except Exception:
                pass

    async def _connect(self) -> psycopg.AsyncConnection:
        for attempt in range(10):
            try:
                conn = await psycopg.AsyncConnection.connect(
                    self.dsn, autocommit=True, connect_timeout=5
                )
                return conn
            except psycopg.OperationalError as e:
                if attempt == 9:
                    raise
                log.warning("db connect failed (%s), retrying", e)
                await asyncio.sleep(2 * attempt + 1)
        raise RuntimeError("unreachable")

    async def _ensure_schema(self) -> None:
        for path in SCHEMA_FILES:
            if not path.exists():
                log.warning(
                    "schema file %s not found; skipping (is it bundled?)", path
                )
                continue
            statements = _split_statements(path.read_text(encoding="utf-8"))
            for statement in statements:
                async with self._conn.cursor() as cur:
                    await cur.execute(statement)
                    if cur.description is not None:
                        await cur.fetchall()
            log.info("applied %s (%s statement(s))", path.name, len(statements))

    async def put(self, kind: str, record: tuple):
        try:
            self._queue.put_nowait((kind, record))
        except asyncio.QueueFull:
            self._dropped += 1
            if self._dropped % 1000 == 1:
                log.warning("queue full, dropped %s events total", self._dropped)

    async def upsert_node(self, node: dict, compressed_fabric_id):
        row = _clean_row(build_node_row(node, compressed_fabric_id))
        async with self._conn.transaction():
            await self._conn.execute(UPSERT_NODE, row)

    async def sync_nodes(self, nodes: list[dict], compressed_fabric_id):
        if not nodes:
            return
        rows = [_clean_row(build_node_row(n, compressed_fabric_id)) for n in nodes]
        async with self._conn.transaction():
            await self._conn.cursor().executemany(UPSERT_NODE, rows)
        log.info("synced %s node(s)", len(rows))

    async def remove_node(self, node_id: int):
        async with self._conn.transaction():
            await self._conn.execute("DELETE FROM matter_nodes WHERE node_id = %s", (node_id,))

    async def _flush_loop(self):
        while True:
            batch = []
            try:
                item = await self._queue.get()
                batch.append(item)
                loop = asyncio.get_running_loop()
                deadline = loop.time() + self.flush_interval
                while len(batch) < self.batch_size:
                    timeout = deadline - loop.time()
                    if timeout <= 0:
                        break
                    try:
                        batch.append(await asyncio.wait_for(self._queue.get(), timeout))
                    except TimeoutError:
                        break
            except asyncio.CancelledError:
                raise
            if batch:
                await self._write(batch)

    async def _write(self, batch: list[tuple[str, tuple]]):
        attrs = [rec for kind, rec in batch if kind == "attr"]
        evs = [(rec[0], rec[1], Json(rec[2])) for kind, rec in batch if kind == "event"]
        for attempt in (1, 2):
            try:
                async with self._conn.transaction():
                    if attrs:
                        await self._conn.cursor().executemany(
                            "INSERT INTO attribute_updates (node_id, attribute_path, "
                            "endpoint_id, cluster_id, attribute_id, value) "
                            "VALUES (%s, %s, %s, %s, %s, %s)",
                            attrs,
                        )
                    if evs:
                        await self._conn.cursor().executemany(
                            "INSERT INTO events (event_type, node_id, data) VALUES (%s, %s, %s)",
                            evs,
                        )
                return
            except (psycopg.OperationalError, psycopg.InterfaceError) as e:
                log.error("db write failed (attempt %s): %s", attempt, e)
                if attempt == 2:
                    log.error("dropping batch of %s record(s)", len(batch))
                    return
                try:
                    await self._conn.close()
                except Exception:
                    pass
                await asyncio.sleep(2)
                self._conn = await self._connect()
                await self._ensure_schema()
            except Exception:
                log.exception("unexpected write error, dropping batch of %s", len(batch))
                return
