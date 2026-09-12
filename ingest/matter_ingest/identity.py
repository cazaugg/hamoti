import uuid


def _attr(attrs: dict, path: str):
    val = attrs.get(path)
    if val in ("", None):
        return None
    return val


def build_node_row(node: dict, compressed_fabric_id) -> dict:
    attrs = node.get("attributes") or {}
    node_id = node["node_id"]
    label = _attr(attrs, "0/40/5")
    vendor_name = _attr(attrs, "0/40/1")
    vendor_id = _attr(attrs, "0/40/2")
    product_name = _attr(attrs, "0/40/3")
    product_id = _attr(attrs, "0/40/4")
    serial = _attr(attrs, "0/40/15")
    unique_id = _attr(attrs, "0/40/18")

    if unique_id:
        source, value = "unique_id", str(unique_id)
    elif serial:
        source, value = "serial_number", str(serial)
    else:
        source, value = "synthetic", None

    if value:
        device_uuid = str(uuid.uuid5(uuid.NAMESPACE_URL, f"matter:{source}:{value}"))
        identity_value = value
    else:
        device_uuid = str(uuid.uuid5(uuid.NAMESPACE_URL, f"matter:{compressed_fabric_id}:{node_id}"))
        identity_value = device_uuid

    return {
        "node_id": node_id,
        "device_uuid": device_uuid,
        "identity_source": source,
        "identity_value": identity_value,
        "label": label,
        "vendor_id": vendor_id,
        "vendor_name": vendor_name,
        "product_id": product_id,
        "product_name": product_name,
        "serial_number": serial,
        "unique_id": unique_id,
        "thread_ext_address": None,
        "available": bool(node.get("available", False)),
        "date_commissioned": node.get("date_commissioned"),
        "last_interview": node.get("last_interview"),
        "raw": node,
    }
