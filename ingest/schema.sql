CREATE EXTENSION IF NOT EXISTS timescaledb;

-- Migrate the hypertable time dimension from the legacy column name `ts` to
-- `time`. The DO body is single-quoted (not $$) on purpose: the lightweight
-- statement splitter in store.py treats everything between quotes as one
-- statement, so this stays a single statement there too.
DO '
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_schema = ''public'' AND table_name = ''attribute_updates''
                 AND column_name = ''ts'') THEN
        ALTER TABLE attribute_updates RENAME COLUMN ts TO time;
    END IF;
    IF EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_schema = ''public'' AND table_name = ''events''
                 AND column_name = ''ts'') THEN
        ALTER TABLE events RENAME COLUMN ts TO time;
    END IF;
END
';

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
    time           timestamptz NOT NULL DEFAULT now(),
    node_id        integer     NOT NULL,
    attribute_path text        NOT NULL,
    endpoint_id    integer     NOT NULL,
    cluster_id     integer     NOT NULL,
    attribute_id   integer     NOT NULL,
    value          jsonb
);
SELECT create_hypertable('attribute_updates', 'time', if_not_exists => TRUE);
ALTER INDEX IF EXISTS attribute_updates_node_path_ts
    RENAME TO attribute_updates_node_path_time;
CREATE INDEX IF NOT EXISTS attribute_updates_node_path_time
    ON attribute_updates (node_id, attribute_path, time DESC);

CREATE TABLE IF NOT EXISTS events (
    time       timestamptz NOT NULL DEFAULT now(),
    event_type text        NOT NULL,
    node_id    integer,
    data       jsonb       NOT NULL
);
SELECT create_hypertable('events', 'time', if_not_exists => TRUE);
-- TimescaleDB names its default time index after the time column; rename the
-- ones created before the `ts` -> `time` migration.
ALTER INDEX IF EXISTS attribute_updates_ts_idx RENAME TO attribute_updates_time_idx;
ALTER INDEX IF EXISTS events_ts_idx RENAME TO events_time_idx;
ALTER INDEX IF EXISTS events_type_ts RENAME TO events_type_time;
ALTER INDEX IF EXISTS events_node_ts RENAME TO events_node_time;
CREATE INDEX IF NOT EXISTS events_type_time ON events (event_type, time DESC);
CREATE INDEX IF NOT EXISTS events_node_time ON events (node_id, time DESC);

ALTER TABLE attribute_updates
    SET (timescaledb.compress, timescaledb.compress_segmentby = 'node_id, attribute_path');
SELECT add_compression_policy('attribute_updates', INTERVAL '7 days', if_not_exists => TRUE);
SELECT add_retention_policy('attribute_updates', INTERVAL '180 days', if_not_exists => TRUE);

ALTER TABLE events
    SET (timescaledb.compress, timescaledb.compress_segmentby = 'event_type');
SELECT add_compression_policy('events', INTERVAL '7 days', if_not_exists => TRUE);
SELECT add_retention_policy('events', INTERVAL '365 days', if_not_exists => TRUE);

-- ---------------------------------------------------------------------------
-- Standard cluster / attribute registry
--
-- Populated from the connectedhomeip ZCL data model by
-- ingest/tools/generate_cluster_seed.py; the generated ingest/cluster_seed.sql
-- is applied by the ingest service on startup (after this file). Only standard
-- clusters are included - manufacturer-specific clusters (0xFC00+) are not.
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS matter_clusters (
    cluster_id integer PRIMARY KEY,
    name       text    NOT NULL,
    category   text
);

CREATE TABLE IF NOT EXISTS matter_cluster_attributes (
    cluster_id   integer NOT NULL,
    attribute_id integer NOT NULL,
    name         text    NOT NULL,
    type         text,
    is_optional  boolean NOT NULL DEFAULT false,
    is_nullable  boolean NOT NULL DEFAULT false,
    PRIMARY KEY (cluster_id, attribute_id)
);

-- Which standard attribute is a measurement and how to interpret its raw value.
-- `encoding`:
--   linear      -> value = raw * scale
--   log10       -> illuminance: lux = 10^((raw - 1) / 10000)
--   enum        -> value = raw (enum code), no unit
--   device_unit -> value = raw; unit reported by the device (MeasurementUnit 0x0008)
CREATE TABLE IF NOT EXISTS matter_measurement_map (
    cluster_id   integer NOT NULL,
    attribute_id integer NOT NULL DEFAULT 0,
    measurement  text    NOT NULL,
    unit         text,
    default_unit text,
    encoding     text    NOT NULL DEFAULT 'linear',
    scale        numeric NOT NULL DEFAULT 1,
    spec_ref     text,
    PRIMARY KEY (cluster_id, attribute_id)
);

-- Migrate pre-existing installations.
ALTER TABLE matter_measurement_map
    ADD COLUMN IF NOT EXISTS default_unit text;

-- MeasurementUnitEnum (Matter 1.2 Application Cluster Spec 2.10.5.1).
CREATE TABLE IF NOT EXISTS matter_measurement_unit_codes (
    code   integer PRIMARY KEY,
    name   text NOT NULL,
    symbol text NOT NULL
);

INSERT INTO matter_measurement_unit_codes (code, name, symbol) VALUES
    (0, 'PPM',  'ppm'),
    (1, 'PPB',  'ppb'),
    (2, 'PPT',  'ppt'),
    (3, 'MGM3', 'mg/m3'),
    (4, 'UGM3', 'ug/m3'),
    (5, 'NGM3', 'ng/m3'),
    (6, 'PM3',  'particles/m3'),
    (7, 'BQM3', 'Bq/m3')
ON CONFLICT (code) DO UPDATE SET name = EXCLUDED.name, symbol = EXCLUDED.symbol;

-- Curated standard measurement attributes. Encodings come from the Matter
-- Application Cluster Specification; `spec_ref` records the cluster ID.
-- `unit` is the fixed unit (NULL for device-reported or unitless values).
-- `default_unit` is only a fallback for 'device_unit' measurements when the
-- device does not report MeasurementUnit (0x0008); a device-reported unit
-- always wins over it.
INSERT INTO matter_measurement_map
    (cluster_id, attribute_id, measurement, unit, default_unit, encoding, scale, spec_ref) VALUES
    (1024,  0, 'illuminance',           'lux',  NULL,     'log10',        1,    '0x0400'),
    (1026,  0, 'temperature',           'C',    NULL,     'linear',       0.01, '0x0402'),
    (1027,  0, 'pressure',              'kPa',  NULL,     'linear',       0.1,  '0x0403'),
    (1028,  0, 'flow',                  'm3/h', NULL,     'linear',       0.1,  '0x0404'),
    (1029,  0, 'humidity',              '%',    NULL,     'linear',       0.01, '0x0405'),
    (1031,  0, 'leaf_wetness',          '%',    NULL,     'linear',       0.01, '0x0407'),
    (1032,  0, 'soil_moisture',         '%',    NULL,     'linear',       0.01, '0x0408'),
    (91,    0, 'air_quality',           NULL,   NULL,     'enum',         1,    '0x005B'),
    (1036,  0, 'co',                    NULL,   NULL,     'device_unit',  1,    '0x040C'),
    (1037,  0, 'co2',                   NULL,   'ppm',    'device_unit',  1,    '0x040D'),
    (1043,  0, 'no2',                   NULL,   NULL,     'device_unit',  1,    '0x0413'),
    (1045,  0, 'ozone',                 NULL,   NULL,     'device_unit',  1,    '0x0415'),
    (1066,  0, 'pm25',                  NULL,   'ug/m3',  'device_unit',  1,    '0x042A'),
    (1067,  0, 'formaldehyde',          NULL,   NULL,     'device_unit',  1,    '0x042B'),
    (1068,  0, 'pm1',                   NULL,   'ug/m3',  'device_unit',  1,    '0x042C'),
    (1069,  0, 'pm10',                  NULL,   'ug/m3',  'device_unit',  1,    '0x042D'),
    (1070,  0, 'tvoc',                  NULL,   'ug/m3',  'device_unit',  1,    '0x042E'),
    (1071,  0, 'radon',                 NULL,   'Bq/m3',  'device_unit',  1,    '0x042F'),
    (47,   11, 'battery_voltage',       'mV',   NULL,     'linear',       1,    '0x002F'),
    (47,   12, 'battery_percent',       '%',    NULL,     'linear',       0.5,  '0x002F'),
    (47,   13, 'battery_time_remaining','s',    NULL,     'linear',       1,    '0x002F')
ON CONFLICT (cluster_id, attribute_id) DO UPDATE SET
    measurement  = EXCLUDED.measurement,
    unit         = EXCLUDED.unit,
    default_unit = EXCLUDED.default_unit,
    encoding     = EXCLUDED.encoding,
    scale        = EXCLUDED.scale,
    spec_ref     = EXCLUDED.spec_ref;

-- Path+time index for measurement queries; the existing (node_id,
-- attribute_path, time) index still serves the per-node unit lookups.
ALTER INDEX IF EXISTS attribute_updates_cluster_attr_ts
    RENAME TO attribute_updates_cluster_attr_time;
CREATE INDEX IF NOT EXISTS attribute_updates_cluster_attr_time
    ON attribute_updates (cluster_id, attribute_id, time DESC);

-- ---------------------------------------------------------------------------
-- Convenience views
-- ---------------------------------------------------------------------------

DROP VIEW IF EXISTS matter_measurements;
DROP VIEW IF EXISTS matter_attributes;
DROP VIEW IF EXISTS matter_sensors;

-- One row per node with the display name resolved once.
CREATE VIEW matter_sensors AS
SELECT n.node_id,
       n.device_uuid,
       COALESCE(NULLIF(nn.custom_name, ''), NULLIF(n.label, ''), 'node ' || n.node_id) AS sensor,
       nn.custom_name,
       n.label,
       n.product_name AS product,
       n.vendor_name  AS vendor,
       n.serial_number,
       n.unique_id,
       n.identity_source,
       n.available,
       n.date_commissioned,
       n.last_interview,
       n.last_seen
FROM matter_nodes n
LEFT JOIN node_names nn ON nn.device_uuid = n.device_uuid;

-- Every attribute update, enriched with cluster/attribute names and, when the
-- attribute is a known measurement, a scaled numeric value and resolved unit.
CREATE VIEW matter_attributes AS
SELECT a.time,
       a.node_id,
       s.device_uuid,
       COALESCE(s.sensor, 'node ' || a.node_id) AS sensor,
       a.endpoint_id,
       a.cluster_id,
       c.name  AS cluster,
       c.category,
       a.attribute_id,
       ca.name AS attribute,
       a.attribute_path,
       m.measurement,
       m.encoding,
       -- fixed unit, else device-reported (MeasurementUnit), else fallback default
       COALESCE(m.unit, muc.symbol, m.default_unit) AS unit,
       CASE
           WHEN jsonb_typeof(a.value) <> 'number' THEN NULL
           WHEN m.encoding = 'log10'
               THEN power(10::numeric, ((a.value::text)::numeric - 1) / 10000)
           ELSE (a.value::text)::numeric * COALESCE(m.scale, 1)
       END AS value,
       a.value AS raw_value
FROM attribute_updates a
LEFT JOIN matter_sensors s ON s.node_id = a.node_id
LEFT JOIN matter_clusters c ON c.cluster_id = a.cluster_id
LEFT JOIN matter_cluster_attributes ca
       ON ca.cluster_id = a.cluster_id AND ca.attribute_id = a.attribute_id
LEFT JOIN matter_measurement_map m
       ON m.cluster_id = a.cluster_id AND m.attribute_id = a.attribute_id
-- Resolve the unit the device itself reported (MeasurementUnit, attr 0x0008)
-- for 'device_unit' measurements. Uses the (node_id, attribute_path, time) index.
LEFT JOIN LATERAL (
    SELECT (u.value::text)::int AS unit_code
    FROM attribute_updates u
    WHERE m.encoding = 'device_unit'
      AND u.node_id = a.node_id
      AND u.attribute_path = a.endpoint_id || '/' || a.cluster_id || '/8'
      AND jsonb_typeof(u.value) = 'number'
    ORDER BY u.time DESC
    LIMIT 1
) mu ON TRUE
LEFT JOIN matter_measurement_unit_codes muc ON muc.code = mu.unit_code;

-- Just the measurements, with the unit already resolved.
CREATE VIEW matter_measurements AS
SELECT time,
       node_id,
       device_uuid,
       sensor,
       measurement,
       unit,
       value,
       raw_value,
       cluster,
       attribute,
       endpoint_id,
       cluster_id,
       attribute_id,
       attribute_path,
       encoding
FROM matter_attributes
WHERE measurement IS NOT NULL;
