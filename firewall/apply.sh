#!/usr/bin/env bash
#
# hamoti host firewall
# ====================
#
# Run this as root ON THE DOCKER HOST (the machine that runs Coolify + the
# hamoti stack). It is not meant to be run from another machine.
#
# Goal
# ----
# From outside (LAN + WAN, IPv4 and IPv6) only the Traefik entrypoints
# (80/443) answer. The unauthenticated management APIs of the Thread/Matter
# stack are reachable only from the host's own loopback and from Docker
# bridge subnets (i.e. Home Assistant and the ingest client):
#
#   8082/tcp  OpenThread Border Router REST  (leaks the Thread network key)
#   5580/tcp  python-matter-server WebSocket (full Matter fabric control)
#
# Everything else inbound is denied by the ufw default policy.
#
# Why two rule sets?
# ------------------
#   * 8082 / 5580 live in the HOST network namespace (network_mode: host), so
#     packets to them hit the INPUT chain -> normal ufw rules work.
#   * Published Docker ports are DNAT'ed and travel the FORWARD chain, where
#     ufw's INPUT rules never see them. They are handled in DOCKER-USER below
#     (belt and braces; the compose file already binds them to 127.0.0.1).
#
# Re-run me after a Coolify redeploy changes Docker subnet ranges.
#
set -euo pipefail

# ---------------------------------------------------------------------------
# CONFIG - review before running
# ---------------------------------------------------------------------------
# Where you administrate the host from (SSH). Narrow this to your workstation
# if you can.
ADMIN_CIDR="${ADMIN_CIDR:-192.168.1.0/24}"

SSH_PORT="${SSH_PORT:-22}"

# Host-net management TCP ports that must not be reachable from LAN/WAN.
PROTECTED_TCP_PORTS="${PROTECTED_TCP_PORTS:-8082 5580}"

# Thread radio interface created by the OTBR container (host network).
# All traffic on this interface is left untouched: it is Thread's own
# crypto-protected mesh and is not routable from the internet.
THREAD_IF="${THREAD_IF:-wpan0}"

# 1 = ADMIN_CIDR may still reach published Docker ports (e.g. the Coolify UI on
# 8000). 0 = only 80/443 are reachable from the LAN. 8082/5580 are NOT affected
# by this switch; they stay loopback+Docker only either way.
ALLOW_ADMIN_TO_PUBLISHED="${ALLOW_ADMIN_TO_PUBLISHED:-1}"

# Defence in depth for PUBLISHED Docker ports via the DOCKER-USER chain.
# The compose file already binds the web UIs to loopback, so the INPUT rules
# above are what actually protect 8082/5580. Set to 0 if this ever conflicts
# with Traefik on your Docker/ufw version.
ENABLE_DOCKER_USER="${ENABLE_DOCKER_USER:-1}"

# mDNS discovery. Harmless to allow and avoids surprises with device
# discovery; set to 0 if you want to be strict.
ALLOW_MDNS="${ALLOW_MDNS:-1}"

# Thread-over-infrastructure UDP on the Ethernet LAN. Not needed when every
# Thread device talks over the radio; enable if Thread discovery breaks.
ALLOW_THREAD_BACKBONE="${ALLOW_THREAD_BACKBONE:-0}"

# 1 = print the commands instead of applying them.
DRY_RUN="${DRY_RUN:-0}"
# ---------------------------------------------------------------------------

log() { printf '%s\n' "$*"; }
run() { if [[ "$DRY_RUN" == "1" ]]; then printf '  [dry-run] %s\n' "$*"; else "$@"; fi; }

if [[ "${EUID:-$(id -u)}" -ne 0 && "$DRY_RUN" != "1" ]]; then
  echo "error: run me as root (sudo $0)" >&2
  exit 1
fi

if ! command -v ufw >/dev/null 2>&1 && [[ "$DRY_RUN" != "1" ]]; then
  echo "error: ufw is not installed. Install it first: apt install ufw" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Discover Docker bridge subnets (IPv4 + IPv6)
# ---------------------------------------------------------------------------
if command -v docker >/dev/null 2>&1; then
  mapfile -t ALL_SUBNETS < <(
    docker network ls -q 2>/dev/null \
      | xargs -r docker network inspect \
          --format '{{range .IPAM.Config}}{{.Subnet}}{{"\n"}}{{end}}' 2>/dev/null \
      | sed '/^$/d' | sort -u
  )
else
  ALL_SUBNETS=()
fi

DOCKER_V4=()
DOCKER_V6=()
for s in "${ALL_SUBNETS[@]+"${ALL_SUBNETS[@]}"}"; do
  if [[ "$s" == *:* ]]; then DOCKER_V6+=("$s"); else DOCKER_V4+=("$s"); fi
done

log "== Docker subnets discovered =="
log "  IPv4: ${DOCKER_V4[*]:-<none>}"
log "  IPv6: ${DOCKER_V6[*]:-<none>}"
log ""

if [[ ${#DOCKER_V4[@]} -eq 0 && ${#DOCKER_V6[@]} -eq 0 ]]; then
  log "WARNING: no Docker subnets found. Is Docker running?"
  log "         Without them 8082/5580 will be loopback-only, which breaks HA."
  log "         Re-run this script once Docker is up."
fi

# ---------------------------------------------------------------------------
# Remove our previous Docker-subnet rules so this stays re-runnable and stale
# ranges do not linger.
# ---------------------------------------------------------------------------
if [[ "$DRY_RUN" != "1" ]]; then
  while :; do
    n="$(ufw status numbered 2>/dev/null \
          | grep -F '# hamoti-docker' \
          | sed -E 's/^\[[[:space:]]*([0-9]+)\].*/\1/' \
          | sort -rn | head -n1 || true)"
    [[ -z "$n" ]] && break
    ufw --force delete "$n" >/dev/null
  done
fi

# ---------------------------------------------------------------------------
# Base policy
# ---------------------------------------------------------------------------
log "== Applying base policy =="
run ufw default deny incoming
run ufw default allow outgoing
run ufw allow from "$ADMIN_CIDR" to any port "$SSH_PORT" proto tcp comment 'hamoti-ssh'
run ufw allow 80/tcp comment 'hamoti-public'
run ufw allow 443/tcp comment 'hamoti-public'
run ufw allow in on "$THREAD_IF" comment 'hamoti-thread-radio'

if [[ "$ALLOW_MDNS" == "1" ]]; then
  run ufw allow 5353/udp comment 'hamoti-mdns'
fi
if [[ "$ALLOW_THREAD_BACKBONE" == "1" ]]; then
  run ufw allow 61631/udp comment 'hamoti-thread-backbone'
  run ufw allow 54877/udp comment 'hamoti-thread-backbone'
fi

# ---------------------------------------------------------------------------
# Management APIs: loopback comes for free (lo is accepted by ufw); allow the
# Docker subnets explicitly and nothing else. This is what keeps 8082/5580 off
# the LAN and off the internet.
# ---------------------------------------------------------------------------
log "== Restricting $PROTECTED_TCP_PORTS to Docker subnets =="
for net in "${DOCKER_V4[@]+"${DOCKER_V4[@]}"}"; do
  for p in $PROTECTED_TCP_PORTS; do
    run ufw allow from "$net" to any port "$p" proto tcp comment 'hamoti-docker'
  done
done
for net in "${DOCKER_V6[@]+"${DOCKER_V6[@]}"}"; do
  for p in $PROTECTED_TCP_PORTS; do
    run ufw allow from "$net" to any port "$p" proto tcp comment 'hamoti-docker'
  done
done

# ---------------------------------------------------------------------------
# DOCKER-USER: last line of defence for PUBLISHED ports (FORWARD chain).
# Persisted in /etc/ufw/after.rules and /etc/ufw/after6.rules.
# ---------------------------------------------------------------------------
build_docker_user_block() {
  local family="$1"; shift
  local -a subnets=("$@")
  local out=$'# BEGIN HAMOTI DOCKER-USER\n*filter\n:DOCKER-USER - [0:0]'
  out+=$'\n-A DOCKER-USER -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN'
  out+=$'\n-A DOCKER-USER -m conntrack --ctstate INVALID -j DROP'
  for s in "${subnets[@]+"${subnets[@]}"}"; do
    out+=$'\n'"-A DOCKER-USER -s $s -j RETURN"
  done
  if [[ "$ALLOW_ADMIN_TO_PUBLISHED" == "1" ]]; then
    if [[ "$family" == "v6" ]]; then
      if [[ "$ADMIN_CIDR" == *:* ]]; then
        out+=$'\n'"-A DOCKER-USER -s $ADMIN_CIDR -j RETURN"
      fi
    else
      if [[ "$ADMIN_CIDR" != *:* ]]; then
        out+=$'\n'"-A DOCKER-USER -s $ADMIN_CIDR -j RETURN"
      fi
    fi
  fi
  out+=$'\n-A DOCKER-USER -p tcp -m multiport --dports 80,443 -j RETURN'
  out+=$'\n-A DOCKER-USER -j DROP'
  out+=$'\nCOMMIT\n# END HAMOTI DOCKER-USER'
  printf '%s' "$out"
}

remove_block() {
  local file="$1" tmp
  [[ -f "$file" ]] || return 0
  if [[ "$DRY_RUN" == "1" ]]; then
    log "  [dry-run] would strip HAMOTI block from $file"
    return 0
  fi
  tmp="$(mktemp)"
  sed '/^# BEGIN HAMOTI DOCKER-USER$/,/^# END HAMOTI DOCKER-USER$/d' "$file" > "$tmp"
  cat "$tmp" > "$file"
  rm -f "$tmp"
}

install_block() {
  local file="$1" block="$2" tmp
  if [[ "$DRY_RUN" == "1" ]]; then
    log "  [dry-run] would update $file with:"
    printf '%s\n' "$block" | sed 's/^/    /'
    return 0
  fi
  tmp="$(mktemp)"
  if [[ -f "$file" ]]; then
    sed '/^# BEGIN HAMOTI DOCKER-USER$/,/^# END HAMOTI DOCKER-USER$/d' "$file" > "$tmp"
  else
    : > "$tmp"
  fi
  printf '%s\n' "$block" >> "$tmp"
  cat "$tmp" > "$file"
  rm -f "$tmp"
}

log "== Updating DOCKER-USER in /etc/ufw/after.rules and after6.rules =="
if [[ "$ENABLE_DOCKER_USER" == "1" ]]; then
  install_block /etc/ufw/after.rules  "$(build_docker_user_block v4 "${DOCKER_V4[@]+"${DOCKER_V4[@]}"}")"
  install_block /etc/ufw/after6.rules "$(build_docker_user_block v6 "${DOCKER_V6[@]+"${DOCKER_V6[@]}"}")"
else
  log "  ENABLE_DOCKER_USER=0 - removing any previous hamoti block"
  remove_block /etc/ufw/after.rules
  remove_block /etc/ufw/after6.rules
fi

# ---------------------------------------------------------------------------
# Enable / reload
# ---------------------------------------------------------------------------
log "== Enabling and reloading ufw =="
if [[ "$DRY_RUN" == "1" ]]; then
  log "  [dry-run] ufw --force enable && ufw reload"
else
  ufw --force enable >/dev/null
  ufw reload >/dev/null
fi

if grep -q '^IPV6=yes' /etc/default/ufw 2>/dev/null; then
  log "IPv6 filtering: enabled (/etc/default/ufw IPV6=yes)"
else
  log "WARNING: IPv6 filtering looks disabled. Set IPV6=yes in /etc/default/ufw"
  log "         and re-run, or IPv6 will bypass these rules."
fi

log ""
log "Done. Next steps:"
log "  1. Confirm you can still SSH in from a SECOND session before closing this one."
log "  2. Run ./firewall/verify.sh on the host."
log "  3. From another machine, run: nmap -Pn -p 80,443,3000,8080,8081,8123,8082,5580 <host>"
log "     Only 80 and 443 should be open."
log "  4. Reboot once and re-check, to confirm the rules survive."
log ""
log "Note: 8081/8123/3000/8080 are loopback-bound by docker-compose and should"
log "      already be gone; 8082/5580 are what this firewall closes off."
