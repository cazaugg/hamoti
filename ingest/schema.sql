CREATE EXTENSION IF NOT EXISTS timescaledb;

CREATE TABLE IF NOT EXISTS matter_nodes (
    node_id            integer PRIMARY KEY,
    device_uuid        text        NOT NULL UNIQUE,
    identity_source    text        NOT NULL,
    identity_value     text,
    label              text,
    vendor_id          integer,
    vendor_name        text,
    product_id         integer,
    product_name       text,
    serial_number      text,
    unique_id          text,
    thread_ext_address text,
    available          boolean,
    date_commissioned  timestamptz,
    last_interview     timestamptz,
    last_seen          timestamptz NOT NULL DEFAULT now(),
    raw                jsonb,
    updated_at         timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS node_names (
    device_uuid text        PRIMARY KEY,
    custom_name text        NOT NULL CHECK (length(custom_name) <= 64),
    updated_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS attribute_updates (
    ts             timestamptz NOT NULL DEFAULT now(),
    node_id        integer     NOT NULL,
    attribute_path text        NOT NULL,
    endpoint_id    integer     NOT NULL,
    cluster_id     integer     NOT NULL,
    attribute_id   integer     NOT NULL,
    value          jsonb
);
SELECT create_hypertable('attribute_updates', 'ts', if_not_exists => TRUE);
CREATE INDEX IF NOT EXISTS attribute_updates_node_path_ts
    ON attribute_updates (node_id, attribute_path, ts DESC);

CREATE TABLE IF NOT EXISTS events (
    ts         timestamptz NOT NULL DEFAULT now(),
    event_type text        NOT NULL,
    node_id    integer,
    data       jsonb       NOT NULL
);
SELECT create_hypertable('events', 'ts', if_not_exists => TRUE);
CREATE INDEX IF NOT EXISTS events_type_ts ON events (event_type, ts DESC);
CREATE INDEX IF NOT EXISTS events_node_ts ON events (node_id, ts DESC);

ALTER TABLE attribute_updates
    SET (timescaledb.compress, timescaledb.compress_segmentby = 'node_id, attribute_path');
SELECT add_compression_policy('attribute_updates', INTERVAL '7 days', if_not_exists => TRUE);
SELECT add_retention_policy('attribute_updates', INTERVAL '180 days', if_not_exists => TRUE);

ALTER TABLE events
    SET (timescaledb.compress, timescaledb.compress_segmentby = 'event_type');
SELECT add_compression_policy('events', INTERVAL '7 days', if_not_exists => TRUE);
SELECT add_retention_policy('events', INTERVAL '365 days', if_not_exists => TRUE);
