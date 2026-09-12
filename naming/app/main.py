import os
from contextlib import asynccontextmanager
from pathlib import Path

import psycopg
from fastapi import FastAPI, HTTPException
from fastapi.responses import HTMLResponse
from pydantic import BaseModel

DSN = os.environ["MATTER_DSN"]
MAX_NAME = 64
INDEX = Path(__file__).parent / "static" / "index.html"

ENSURE_SCHEMA = """
CREATE TABLE IF NOT EXISTS node_names (
    device_uuid text        PRIMARY KEY,
    custom_name text        NOT NULL CHECK (length(custom_name) <= 64),
    updated_at  timestamptz NOT NULL DEFAULT now()
)
"""

SELECT_NODES = """
SELECT n.node_id,
       n.device_uuid,
       nn.custom_name,
       n.label,
       n.product_name  AS product,
       n.vendor_name   AS vendor,
       n.unique_id,
       n.available
FROM matter_nodes n
LEFT JOIN node_names nn ON nn.device_uuid = n.device_uuid
ORDER BY n.node_id
"""


def conn() -> psycopg.Connection:
    return psycopg.connect(DSN, autocommit=True, connect_timeout=5)


@asynccontextmanager
async def lifespan(_app: FastAPI):
    with conn() as c, c.cursor() as cur:
        cur.execute(ENSURE_SCHEMA)
    yield


app = FastAPI(lifespan=lifespan, title="Matter sensor naming")


class NameIn(BaseModel):
    device_uuid: str
    custom_name: str = ""


@app.get("/api/nodes")
def list_nodes():
    with conn() as c, c.cursor() as cur:
        cur.execute(SELECT_NODES)
        cols = [d.name for d in cur.description]
        rows = [dict(zip(cols, row)) for row in cur.fetchall()]
    return rows


@app.post("/api/names")
def set_name(body: NameIn):
    name = body.custom_name.strip()
    if not body.device_uuid:
        raise HTTPException(400, "device_uuid is required")
    if len(name) > MAX_NAME:
        raise HTTPException(400, f"name too long (max {MAX_NAME})")
    with conn() as c, c.cursor() as cur:
        cur.execute("SELECT 1 FROM matter_nodes WHERE device_uuid = %s", (body.device_uuid,))
        if cur.fetchone() is None:
            raise HTTPException(404, "unknown device")
        if name:
            cur.execute(
                """
                INSERT INTO node_names (device_uuid, custom_name)
                VALUES (%s, %s)
                ON CONFLICT (device_uuid)
                DO UPDATE SET custom_name = EXCLUDED.custom_name, updated_at = now()
                """,
                (body.device_uuid, name),
            )
        else:
            cur.execute("DELETE FROM node_names WHERE device_uuid = %s", (body.device_uuid,))
    return {"ok": True, "custom_name": name or None}


@app.get("/", response_class=HTMLResponse)
def index():
    return INDEX.read_text(encoding="utf-8")
