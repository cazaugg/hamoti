# Hamoti Smart Home Stack — Home Assistant + Matter + Open Thread + Ikea

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
| homeassistant            | 8123/tcp via `docker-proxy` 0.0.0.0        | HTTP                  | HA frontend/API/websocket                                                                  | ✅ HA login, but **plain HTTP** — bypasses Traefik's TLS |

##### Internal — Docker network only

| Container     | Port            | Service                                                      |
| ------------- | --------------- | ------------------------------------------------------------ |
| homeassistant | 8123/tcp        | same frontend, reachable by peer containers (Traefik's path) |
| homeassistant | 1900/udp        | SSDP discovery (bridge-isolated)                             |
| homeassistant | 5353/udp        | mDNS (bridge-isolated — why OTBR mDNS auto-discovery fails)  |
| homeassistant | 2 ephemeral tcp | transient runtime listeners                                  |

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
      - '8123:8123'
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

Deploy via Coolify (or plain `docker compose up -d`). Wait until all three
containers are healthy.

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

Open `http://<host-ip>:8123`, setup the admin login and go to `Settings -> System -> Network -> Reverse Proxy` and enable `Trust X-Forwarded-For` and add Trusted Proxies `10.0.0.0/8`

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
```

## Security notes

All three management interfaces are **unauthenticated** and bound to `0.0.0.0`,
reachable by anything on the LAN (host firewall is currently inactive):

| Port | Service       | Exposure                                                     |
| ---- | ------------- | ------------------------------------------------------------ |
| 8081 | OTBR web UI   | full border-router control                                   |
| 8082 | OTBR REST API | read/write Thread dataset incl. **network key in plaintext** |
| 5580 | matter-server | commission rogue devices, control/reset all Matter devices   |

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
