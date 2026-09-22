# Hamoti Smart Home Stack — Home Assistant + Matter + Open Thread + Ikea + Grafana

This setup runs cheap Ikea matter sensors like Timmerflotte and connects them to home assistant without the official Ikea matter bridge.

You can turn an old laptop into a matter server by adding a thread radio stick and a bunch of open source software. It works, but no part of it is mature. Especially the software stack seems very much experimental. The official Open Thread Border Router has no authentication, neither does the python matter server. And the Home Assistant App cant pair matter devices on Graphene OS because its implementation is fundamentally unsafe. Unfortunately and as far as im aware, there are no alternatives in mid 2026.

The guide wil help you set it up, but please shield the services from internet access.

## Setup

### Hardware

- Ikea Timmerflotte Sensor: Temperature and Humidity Sensor
- Ikea Alpstuga Sensor: Air Quality Sensor
- Sonoff ZBDongle-E (USB - Stick): Thread Network Radio
- Old Lenovo Laptop as server running Ubuntu 24.4, for pairing the devices i use the bluetooth radio on this laptop. Its network connection is done over ethernet.

> ⚠️ The ZBDongle-E ships with **Zigbee** firmware. It cannot speak to OTBR until flashed with OpenThread / Matter firmware — flash via the official web flasher <https://dongle.sonoff.tech/sonoff-dongle-flasher/> The compose below expects 460800 baud.

The Timmerflotte Sensor are battery powered and turned off most of the time. In contrast, the Alpstuga is always powered over USB and therefore acts as a thread network repeater or range extender.

### Software

- Open Thread Border Router
- Python Matter Server
- Home Assistant Server
- Home Assistant Phone App
- Docker compose
- TimescaleDB (history storage)
- Grafana (dashboards)
- Matter ingest + naming (monitoring helpers)

Additionally i use coolify to manage the apps, but this is optional and has little to do with the rest of the setup.

#### Exposed services inventory

| Container                | Port                                       | Protocol              | Service                                                                                    | Auth                                                     |
| ------------------------ | ------------------------------------------ | --------------------- | ------------------------------------------------------------------------------------------ | -------------------------------------------------------- |
| otbr (host net)          | 8081/tcp                                   | HTTP                  | Web UI                                                                                     | ❌ none                                                  |
| otbr (host net)          | 8082/tcp                                   | REST                  | Thread dataset/config API ⚠️ leaks network key in plaintext                              | ❌ none                                                  |
| otbr (host net)          | 5353/udp                                   | mDNS                  | `_meshcop._udp` border-router advertisement (by design)                                    | n/a                                                      |
| otbr (host net)          | 61631/udp, 54877/udp (`enp0s25`)           | Thread backbone       | Thread-over-infrastructure traffic                                                         | Thread crypto                                            |
| matter-server (host net) | 5580/tcp                                   | WebSocket + dashboard | Full fabric control: commission/reset/control all nodes                                    | ❌ none                                                  |
| matter-server (host net) | 5353/udp + ~30 ephemeral udp ports (v4+v6) | mDNS + CHIP           | Operational discovery & CASE sessions — **must stay reachable** for Matter devices to work | Matter crypto                                            |
| homeassistant            | 8123/tcp via Coolify + `127.0.0.1:18123`   | HTTP                  | HA frontend/API/websocket                                                                  | ✅ HA login, but **plain HTTP** — bypasses Traefik's TLS |
| grafana                  | 3000/tcp via Coolify + `127.0.0.1:13000`   | HTTP                  | Grafana dashboards                                                                         | ✅ Grafana login                                          |
| naming                   | 8080/tcp via Coolify + `127.0.0.1:18080`   | HTTP                  | Sensor naming UI (writes to TimescaleDB)                                                   | ❌ none                                                  |
| timescaledb              | 127.0.0.1:5432                             | PostgreSQL            | History database, loopback-only                                                            | ✅ DB password                                           |
| ingest (host net)        | —                                          | WebSocket client      | Read-only Matter firehose → TimescaleDB, no listener                                       | n/a                                                      |

##### Internal — Docker network only

| Container     | Port            | Service                                                      |
| ------------- | --------------- | ------------------------------------------------------------ |
| homeassistant | 8123/tcp        | same frontend, reachable by peer containers (Traefik's path) |
| homeassistant | 1900/udp        | SSDP discovery (bridge-isolated)                             |
| homeassistant | 5353/udp        | mDNS (bridge-isolated — why OTBR mDNS auto-discovery fails)  |
| homeassistant | 2 ephemeral tcp | transient runtime listeners                                  |
| timescaledb   | 5432/tcp        | PostgreSQL, reachable by grafana/naming over the compose net |
| grafana       | 3000/tcp        | dashboard, reachable by peer containers                      |
| naming        | 8080/tcp        | naming API/UI, reachable by peer containers                  |

OTBR and matter-server have no docker-internal footprint: being host-networked,
everything they expose lands directly on the host/LAN.

## Terminology

The Matter World is a hot mess and nowhere near easy to use. Quick start:

- Thread Network: The sensor connects to a radio network called Thread. Thread uses a radio protocol called IEEE 802.15.4 (the same as Zigbee) to send radio messages. Although Thread is similar to Zigbee, its not the same. Thread is a mesh network, which means any device that is constantly powered can relay messages and expand the reach of the network.
- Thread Border Router: Since Thread is a totally different network than WIFI or Ethernet, we need a device that translates (routes) messages between a computer network (wifi or ethernet) and the thread network. This is a border router.
- Matter: Matter is the protocol which is used to send data over the thread network. It is not the network or the radio. Matter defines how devices are paired, updated and how they format data the send and receive.
- Matter Server: The software that handles all matter aspects of the device. This is the one doing the device paring for example.
- Home Assistant: HA is the smart home app im using. It has a server and a webapp. In theory it has a matter server integrated, but HA has troubles in ipv6 networks. Since thread works on ipv6 only, this is a problem and lead me to use the Python-Matter-Server.

## Docker Compose

This docker compose is used with coolify, if you replace the env variables it should run without coolify as well.

```yaml
services:
  otbr:
    image: 'openthread/border-router:latest'
    network_mode: host
    privileged: true
    environment:
      - 'OT_RCP_DEVICE=spinel+hdlc+uart:///dev/ttyUSB_thread?uart-baudrate=460800'
      - OT_INFRA_IF=enp0s25
      - OT_THREAD_IF=wpan0
      - OT_LOG_LEVEL=7
      - OT_WEB_LISTEN_ADDR=0.0.0.0
      - OT_WEB_LISTEN_PORT=8081
      - OT_REST_LISTEN_ADDR=0.0.0.0
      - OT_REST_LISTEN_PORT=8082
    devices:
      - '/dev/serial/by-id/usb-Itead_Sonoff_Zigbee_3.0_USB_Dongle_Plus_V2_d64c43c71ef4ef11859ebd1b6d9880ab-if00-port0:/dev/ttyUSB_thread'
    volumes:
      - '/data/smart-home/otbr:/data'

  matter-server:
    image: 'ghcr.io/home-assistant-libs/python-matter-server:stable'
    network_mode: host
    security_opt:
      - 'apparmor:unconfined'
    volumes:
      - '/data/smart-home/matter:/data'
      - '/run/dbus:/run/dbus:ro'
    command: '--storage-path /data --primary-interface enp0s25 --bluetooth-adapter 0'
    healthcheck:
      test:
        - CMD-SHELL
        - 'python3 -c "import socket; socket.create_connection((\"localhost\", 5580), 3)" || exit 1'
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 30s

  homeassistant:
    image: 'ghcr.io/home-assistant/home-assistant:latest'
    environment:
      - SERVICE_URL_HOMEASSISTANT_8123
      - 'TZ=${TZ:-UTC}'
    ports:
      - '127.0.0.1:18123:8123'
    volumes:
      - '/data/smart-home/assistant:/config'
      - '/run/dbus:/run/dbus:ro'
    privileged: true
    healthcheck:
      test:
        - CMD
        - curl
        - '-f'
        - 'http://localhost:8123'
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 60s

  timescaledb:
    image: 'timescale/timescaledb:latest-pg17'
    container_name: matter-timescaledb
    restart: unless-stopped
    environment:
      POSTGRES_DB: matter
      POSTGRES_USER: matter
      POSTGRES_PASSWORD: '${POSTGRES_PASSWORD:?set in .env}'
      TZ: '${TZ:-UTC}'
    volumes:
      - '/data/smart-home/timescaledb:/var/lib/postgresql/data'
      - './ingest/schema.sql:/docker-entrypoint-initdb.d/01-schema.sql:ro'
    ports:
      - '127.0.0.1:5432:5432'
    healthcheck:
      test:
        - CMD-SHELL
        - 'pg_isready -U matter -d matter'
      interval: 5s
      timeout: 3s
      retries: 20

  grafana:
    image: 'grafana/grafana:13.2.1'
    container_name: matter-grafana
    restart: unless-stopped
    depends_on:
      timescaledb:
        condition: service_healthy
    # The /data mount does not support changing ownership, so Grafana must run as root here.
    user: '0:0'
    environment:
      GF_SECURITY_ADMIN_USER: '${GRAFANA_ADMIN_USER:-admin}'
      GF_SECURITY_ADMIN_PASSWORD: '${GRAFANA_ADMIN_PASSWORD:?set in .env}'
      GF_USERS_ALLOW_SIGN_UP: 'false'
      GF_ANALYTICS_REPORTING_ENABLED: 'false'
      GF_ANALYTICS_CHECK_FOR_UPDATES: 'false'
      POSTGRES_PASSWORD: '${POSTGRES_PASSWORD}'
      TZ: '${TZ:-UTC}'
    volumes:
      - '/data/smart-home/grafana:/var/lib/grafana'
      - './grafana/provisioning:/etc/grafana/provisioning:ro'
      - './grafana/dashboards:/var/lib/grafana/dashboards:ro'
    ports:
      - '127.0.0.1:13000:3000'

  naming:
    build: ./naming
    container_name: matter-naming
    restart: unless-stopped
    depends_on:
      timescaledb:
        condition: service_healthy
    environment:
      MATTER_DSN: 'postgresql://matter:${POSTGRES_PASSWORD}@timescaledb:5432/matter'
    ports:
      - '127.0.0.1:18080:8080'

  ingest:
    build: ./ingest
    container_name: matter-ingest
    restart: unless-stopped
    network_mode: host
    depends_on:
      timescaledb:
        condition: service_healthy
    environment:
      MATTER_WS_URL: '${MATTER_WS_URL:-ws://localhost:5580/ws}'
      MATTER_DSN: 'postgresql://matter:${POSTGRES_PASSWORD}@localhost:5432/matter'
      MATTER_LOG_LEVEL: '${MATTER_LOG_LEVEL:-INFO}'
      MATTER_DEBUG_JSONL: '${MATTER_DEBUG_JSONL:-}'
    volumes:
      - '/data/smart-home/ingest:/data'
```

## Setup from scratch

### 1. Flash the dongle with OpenThread / Matter firmware

Stock ZBDongle-E runs Zigbee coordinator firmware — OTBR cannot use it. Use the Sonoff web flasher <https://dongle.sonoff.tech/sonoff-dongle-flasher/> The docker compose expects 460800 baud.

### 2. Host preparation

```bash
# Bluetooth stack (needed by matter-server for BLE commissioning)
apt install bluez
systemctl enable --now bluetooth
bluetoothctl power on                     # hci0 must show Powered: yes

# IPv6 forwarding (Thread ↔ LAN routing)
sysctl -w net.ipv6.conf.all.forwarding=1   # persist in /etc/sysctl.conf or sysctl.d
```

### 3. Deploy the stack

Create `.env` from `.env.example` and set `POSTGRES_PASSWORD` /
`GRAFANA_ADMIN_PASSWORD`, then deploy via Coolify (or plain
`docker compose up -d --build`). Wait until all containers are healthy.

### 4. Form the Thread network

If the docker container are running, setup a new thread network using the CLI. You can customise the network name, in this example its `smart-home-net`.

```bash
docker exec otbr-ptw97r4t9xl2477dasdnnlux sh -c '
ot-ctl dataset init new          # generates ALL-random strong values
ot-ctl dataset networkname smart-home-net
ot-ctl dataset commit active
ot-ctl ifconfig up
ot-ctl thread start'
```

This can also be done in the OTBR web UI. Open the OTBR web UI at `http://<host-ip>:8081` → **Form** tab:

- Enter a network name (e.g. `smart-home-net`)
- Fill all the fields
- Click **Form**

Verify:

```bash
docker exec otbr-<uuid> ot-ctl state        # → leader
curl -s http://<host-ip>:8082/node/dataset/active   # shows name/extpanid/key/channel
```

> Do NOT keep the default test credentials (`00112233...`). Always re-form with
> generated values.

### 5. Home Assistant access

When HA is served behind a reverse proxy, the first access must bypass the proxy to setup the configuration.

Reach HA without the proxy first. From your workstation, tunnel the break-glass port: `ssh -L 18123:127.0.0.1:18123 <host>` then open `http://localhost:18123` (or use the domain Coolify assigned to HA). Set up the admin login, then go to `Settings -> System -> Network -> Reverse Proxy` and enable `Trust X-Forwarded-For` and add Trusted Proxies `10.0.0.0/8`

Restart the container and now you should be able to access through the proxy and https (if proxy is correctly setup).

> Note: In earlier HA version, this config could be done in `configuration.yaml`, but this file no longer supports http setup.

### 6. Home Assistant integrations

**Matter integration**
Settings → Devices & Services → Add Integration → **Matter** → URL:

```txt
ws://<host-ip>:5580/ws
```

**OpenThread Border Router integration**
Settings → Devices & Services → Add Integration → **OpenThread Border Router** → URL:

```txt
http://<host-ip>:8082     ← REST API port, NOT 8081!
```

Auto-discovery does **not** work in this setup: OTBR announces itself via mDNS on
the host network, but HA runs on a Docker bridge network and multicast doesn't
cross that boundary. Manual add is therefore mandatory.

Verify: Settings → Devices & Services → **Thread** shows the border router with an
active dataset (ExtPanID matching step 4). With a single network it becomes the
preferred one automatically. Check that `/data/smart-home/assistant/.storage/thread.datasets`
now contains the dataset TLV.

### 7. Pairing devices

#### Path A — normal (HA companion app)

Phone with the HA companion app, Bluetooth ON, same LAN as the server:

1. Put the device into pairing mode (TIMMERFLOTTE: insert batteries, LED blinks)
2. HA app → Settings → Devices & Services → Matter → **Add Device** → scan QR
3. Confirm joining the Thread network

#### Path B — GrapheneOS / no suitable phone (server-side BLE)

Android commissioning runs inside Google Play Services, which requires the
privileged `READ_WIFI_CREDENTIAL` permission. GrapheneOS doesn't grant it and
won't-fix it due to security concerns — the app always
fails with "No Wi-Fi connection". Commission from the server instead:

Prerequisites: `bluez` installed + `bluetooth.service` active + `hci0` powered +
matter-server started with `--bluetooth-adapter 0`.

The matter-server does **not** fetch the Thread dataset itself — normally the HA
app pushes it during commissioning. Without an app, push it manually once (and
after every matter-server restart):

```bash
TLV=$(python3 -c "import json; d=json.load(open('/data/smart-home/assistant/.storage/thread.datasets')); print(d['data']['datasets'][0]['tlv'])")
docker exec matter-server-<uuid> python3 - <<EOF
import asyncio, aiohttp
from matter_server.client import MatterClient

async def main():
    async with aiohttp.ClientSession() as session:
        client = MatterClient('ws://localhost:5580/ws', session)
        t = asyncio.create_task(client.start_listening())
        while client.server_info is None:
            await asyncio.sleep(0.2)
        await client.set_thread_operational_dataset('$TLV')
        print('dataset pushed')
        await client.disconnect()
        t.cancel()

asyncio.run(main())
EOF
```

Then:

1. Device into pairing mode, **directly next to the server** (<50 cm)
2. Open `http://<host-ip>:5580` → **Commission device** → enter the 11-digit
   manual pairing code (printed under the QR code)
3. Wait up to ~60 s discovery + 1–3 min commissioning

Success looks like:

```txt
matter-server log: "Commissioned Node ID: N ... successful"
                   "<Node:N> Subscription succeeded"
ot-ctl child table: device appears
```

#### BLE commissioning lessons learned

- **Fresh alkaline batteries.** Weak/NiMH cells brown out during the certificate
  exchange (the most radio-intensive phase) → HCI supervision timeout (0x08),
  failure at `SendOpCertSigningRequest`.
- **Distance matters**: >1 m caused repeated mid-handshake drops; <50 cm worked.
- Don't run `bluetoothctl scan` or other BT activity during commissioning.
- After a failed attempt, re-trigger pairing mode before retrying. On Ikea devices this is done by pressing the reset button for >10 seconds.

## Monitoring & History (TimescaleDB + Grafana)

A read-only WebSocket client (`ingest`) taps the same Matter firehose as Home
Assistant and stores every attribute update in TimescaleDB, where Grafana renders
a provisioned dashboard. HA is untouched by this — the ingest client only listens.

| Service | Container | Port | Purpose |
| --- | --- | --- | --- |
| TimescaleDB | `matter-timescaledb` | 127.0.0.1:5432 | storage (hypertables + retention/compression) |
| Grafana | `matter-grafana` | 3000 (break-glass `127.0.0.1:13000`) | dashboards |
| Naming UI | `matter-naming` | 8080 (break-glass `127.0.0.1:18080`) | give sensors friendly names |
| Ingest | `matter-ingest` | — | read-only WebSocket client, stores the firehose |

### First start

The stack needs two secrets. Create `.env` from the example and fill them in:

```bash
cp .env.example .env
# edit POSTGRES_PASSWORD and GRAFANA_ADMIN_PASSWORD
docker compose up -d --build
```

On first start TimescaleDB initializes from `ingest/schema.sql` (tables,
hypertables, compression, retention), Grafana auto-provisions the
`Matter TimescaleDB` datasource and the **Matter Sensors** dashboard, and the
ingest connects to `ws://localhost:5580/ws` (host network) and syncs all nodes.

Check it's alive:

```bash
docker compose ps
docker compose logs -f ingest
```

### Open the UIs

| UI | URL | Login |
| --- | --- | --- |
| Grafana dashboard | https://grafana.\<domain\>/d/matter-sensors (or `ssh -L 13000:127.0.0.1:13000`) | `admin` / `GRAFANA_ADMIN_PASSWORD` |
| Sensor naming | https://naming.\<domain\>/ (or `ssh -L 18080:127.0.0.1:18080`) | HTTP BasicAuth |

Custom names set in the naming UI appear in Grafana within ~30 s, without a restart.

### Query the database

```bash
docker exec -it matter-timescaledb psql -U matter -d matter
```

Tables: `matter_nodes` (identity/metadata), `attribute_updates` (raw firehose),
`events` (node lifecycle), `node_names` (custom names).

> TimescaleDB is only published on `127.0.0.1:5432`, so it is not reachable from
> the LAN. The ingest container reaches it via the loopback publish because it
> runs on the host network.

### Common operations

```bash
docker compose stop                          # stop (data persists)
docker compose start                         # start again
docker compose restart ingest                # reconnect + full node resync
docker compose up -d --build ingest          # apply ingest code changes
docker compose down                          # stop + remove containers
```

Changing the Grafana admin password: `GF_SECURITY_ADMIN_PASSWORD` only applies on
the **first** boot with an empty database. For a running instance:

```bash
docker exec matter-grafana grafana cli admin reset-admin-password 'new-password'
```

### Where the monitoring data lives

```
/data/smart-home/timescaledb/   database
/data/smart-home/grafana/       grafana.db, plugins
/data/smart-home/ingest/        raw frame capture (debug)
```

Retention (attribute updates 180 d, events 365 d) and compression (after 7 d) are
applied by `ingest/schema.sql` **only on a fresh** `/data/smart-home/timescaledb`.
Changing it on an existing database needs manual SQL.

## Cheat sheet

```bash
# Thread state
docker exec otbr-<uuid> ot-ctl state              # leader = OK
docker exec otbr-<uuid> ot-ctl child table        # joined devices
docker exec otbr-<uuid> ot-ctl networkname

# Thread dataset (contains networkKey in plaintext!)
curl -s http://<host-ip>:8082/node/dataset/active

# Matter server state
curl http://<host-ip>:5580                      # dashboard
docker logs -f matter-server-<uuid>

# HA storage locations
/data/smart-home/assistant/.storage/core.config_entries   # integration config
/data/smart-home/assistant/.storage/thread.datasets       # preferred dataset TLV

# Monitoring
docker compose logs -f ingest                   # Matter firehose -> TimescaleDB
docker exec -it matter-timescaledb psql -U matter -d matter
curl -s http://localhost:18080/api/nodes        # naming API (on the host)
```

## Security notes

The Thread/Matter management interfaces are **unauthenticated**. OTBR's web UI
listens on loopback only; the rest listen on `0.0.0.0` but `firewall/apply.sh`
restricts them to loopback + the Docker subnets:

| Port | Service       | Exposure                                                     |
| ---- | ------------- | ------------------------------------------------------------ |
| 8081 | OTBR web UI   | full border-router control                                   |
| 8082 | OTBR REST API | read/write Thread dataset incl. **network key in plaintext** |
| 5580 | matter-server | commission rogue devices, control/reset all Matter devices   |

Additional monitoring interfaces:

| Port | Service     | Auth / exposure                                                   |
| ---- | ----------- | ----------------------------------------------------------------- |
| 3000 | grafana     | Grafana login; Coolify-published, break-glass `127.0.0.1:13000`   |
| 8080 | naming UI   | HTTP BasicAuth via Traefik; break-glass `127.0.0.1:18080` (no auth) |
| 5432 | timescaledb | password-protected, **loopback only** (`127.0.0.1`)               |

**HA Bluetooth warning** ("adapter requires additional permissions"): cosmetic.
HA sees `hci0` via D-Bus but can't get kernel MGMT control because it runs in a
bridge netns. Advertisement-based BLE still works partially; if unwanted, remove
the `/run/dbus` mount from the homeassistant service.

## Installed extras

- **HACS** in `/config/custom_components/hacs` (installed via
  `wget -O - https://get.hacs.xyz | bash -` inside the container, then restart).
  Configure under Settings → Devices & Services → HACS with a GitHub account.

## Device notes

### IKEA TIMMERFLOTTE

- Matter-over-Thread only (no Zigbee fallback), 2× AAA
- Measurement interval: **~5 min fixed**, not configurable (°C/°F switch only);
  button press triggers immediate reading/report
- NiMH (LADDA 1.2 V) officially supported but fuel gauge reads pessimistically;
  some units drop off early. Alkaline AAAs last longest. Watch the battery entity
  and swap proactively so the sensor doesn't leave the mesh silently.

### IKEA ALPSTUGA

- For the sensor to receive correct time from home assistant, you need to install the integration `Mater Time Sync` from HACS (Home Assistant Community Store).
