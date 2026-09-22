# Host firewall

Closes the Thread/Matter management APIs (`8082`, `5580`) to everything except
the host's loopback and the Docker bridge subnets. Run on the Docker host that
runs Coolify and this stack — **not** from another machine.

## Usage

```bash
# preview, no changes, no root needed
DRY_RUN=1 ./firewall/apply.sh

# apply (as root)
sudo ./firewall/apply.sh

# inspect
sudo ./firewall/verify.sh
```

Keep your current SSH session open and confirm you can open a **second** one
before you rely on the result.

## What it does

| Rule | Purpose |
| --- | --- |
| `default deny incoming` | everything not explicitly allowed is dropped |
| allow `22` from `ADMIN_CIDR` | SSH |
| allow `80`,`443` | Traefik entrypoints |
| allow `in on wpan0` | Thread radio (crypto-protected, not internet-routable) |
| allow `5353/udp` | mDNS discovery |
| allow `8082`,`5580` from Docker subnets | Home Assistant / ingest only |
| `DOCKER-USER` block | stops LAN/WAN reaching any *published* Docker port other than 80/443 |

`8081` and the break-glass loopback ports `18123`, `13000` and `18080` are not
listed because `docker-compose.yml` binds them to `127.0.0.1`; they are gone
from the network before the firewall even matters. The web UIs that Coolify
publishes itself (`8123`, `3000`, `8080`) are covered by the `DOCKER-USER`
block below, which only lets 80/443 (and, with `ALLOW_ADMIN_TO_PUBLISHED=1`,
`ADMIN_CIDR`) through.

## Configuration

Set these as environment variables before running:

| Variable | Default | Meaning |
| --- | --- | --- |
| `ADMIN_CIDR` | `192.168.1.0/24` | where SSH (and, if enabled, published ports) are reachable from |
| `SSH_PORT` | `22` | |
| `PROTECTED_TCP_PORTS` | `8082 5580` | host-net ports restricted to Docker subnets |
| `THREAD_IF` | `wpan0` | Thread radio interface, left unfiltered |
| `ALLOW_ADMIN_TO_PUBLISHED` | `1` | `0` = LAN may only reach 80/443 |
| `ALLOW_MDNS` | `1` | allow `5353/udp` |
| `ALLOW_THREAD_BACKBONE` | `0` | allow `61631/udp`,`54877/udp` on the LAN (Thread-over-IP) |
| `ENABLE_DOCKER_USER` | `1` | `0` = skip the `DOCKER-USER` block |
| `DRY_RUN` | `0` | `1` = print, do not apply |

Example, stricter:

```bash
sudo ALLOW_ADMIN_TO_PUBLISHED=0 ALLOW_MDNS=0 ./firewall/apply.sh
```

## Reverting

```bash
sudo ufw disable
```

To remove only this block and keep ufw running:

```bash
sudo DRY_RUN=0 ENABLE_DOCKER_USER=0 ./firewall/apply.sh   # strips the DOCKER-USER block
```

## Caveats

- **Re-run after a Coolify redeploy** if Docker subnets change. The script
  deletes its old `# hamoti-docker` rules first, so it is safe to repeat.
- **Test from another machine.** Connecting to the host's own LAN IP goes over
  `lo`, which ufw always accepts, so blocked ports can look open.
- **IPv6:** the host has IPv6 forwarding on for Thread. Confirm
  `IPV6=yes` in `/etc/default/ufw` (the script warns if not) and test over
  IPv6 from outside too.
- **Reboot once** to confirm the rules survive (`DOCKER-USER` ordering between
  `ufw.service` and `docker.service` is the usual culprit if they don't).
