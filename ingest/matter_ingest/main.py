import asyncio
import logging
import os

from psycopg.types.json import Json

from .client import MatterClient
from .config import load
from .store import Store

log = logging.getLogger("matter.main")

KNOWN_EVENTS = {
    "attribute_updated",
    "node_added",
    "node_removed",
    "node_updated",
    "server_info_updated",
    "shutting_down",
}


def _node_id(data) -> int | None:
    if isinstance(data, dict):
        node_id = data.get("node_id")
    elif isinstance(data, list) and data:
        node_id = data[0]
    else:
        node_id = None
    return int(node_id) if node_id is not None else None


def _path_ids(path: str) -> tuple[int, int, int]:
    endpoint, cluster, attribute = str(path).split("/")
    return int(endpoint), int(cluster), int(attribute)


def make_event_handler(store: Store, fabric_state: dict):
    async def on_event(msg: dict):
        event = msg.get("event")
        data = msg.get("data")
        node_id = _node_id(data) if isinstance(data, (dict, list)) else None

        if event == "attribute_updated":
            if isinstance(data, list):
                node_id, path, value = int(data[0]), str(data[1]), data[2]
                endpoint_id, cluster_id, attribute_id = _path_ids(path)
            else:
                data = data or {}
                node_id = int(data["node_id"])
                path = data.get("attribute_path")
                if path is None:
                    path = (
                        f"{data.get('endpoint_id')}/{data.get('cluster_id')}/"
                        f"{data.get('attribute_id')}"
                    )
                endpoint_id, cluster_id, attribute_id = _path_ids(path)
                value = data.get("attribute_value", data.get("new_value"))
            await store.put(
                "attr",
                (node_id, path, endpoint_id, cluster_id, attribute_id, Json(value)),
            )
        elif event in ("node_added", "node_updated"):
            if isinstance(data, dict) and "attributes" in data:
                try:
                    await store.upsert_node(data, fabric_state.get("compressed_fabric_id"))
                except Exception:
                    log.exception("failed to upsert node %s", node_id)
            if node_id is not None:
                await store.put("event", (event, node_id, Json(data)))
        elif event == "node_removed":
            if node_id is not None:
                try:
                    await store.remove_node(node_id)
                except Exception:
                    log.exception("failed to remove node %s", node_id)
            await store.put("event", (event, node_id, Json(data or {})))
        else:
            if event not in KNOWN_EVENTS:
                log.info("unknown event type %s", event)
            await store.put("event", (event, node_id, Json(data if isinstance(data, (dict, list)) else {})))

    return on_event


async def run():
    cfg = load()
    logging.basicConfig(
        level=cfg.log_level,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )
    store = Store(cfg.dsn)
    await store.start()
    fabric_state: dict = {}
    backoff = 2.0
    session = 0

    while True:
        client = MatterClient(cfg.ws_url, debug_jsonl=cfg.debug_jsonl)
        client.event_handler = make_event_handler(store, fabric_state)
        try:
            await client.connect()
            nodes = await client.command("start_listening", timeout=60)
            fabric_state["compressed_fabric_id"] = client.server_info.get("compressed_fabric_id")
            await store.sync_nodes(nodes or [], fabric_state["compressed_fabric_id"])
            session += 1
            log.info("session %s: listening (%s node(s))", session, len(nodes or []))
            backoff = 2.0
            await client.wait_closed()
        except Exception as e:
            log.warning("session %s ended: %s", session, e)
        finally:
            await client.close()
        await asyncio.sleep(backoff)
        backoff = min(backoff * 2, 60)


if __name__ == "__main__":
    assert os.environ.get("MATTER_DSN"), "MATTER_DSN is required"
    asyncio.run(run())
