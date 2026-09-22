#!/usr/bin/env bash
#
# hamoti firewall verification - run on the Docker host.
#
set -uo pipefail

LOOPBACK_PORTS=(8081 8082 5580)
# Ports that should NOT be reachable from the network.
EXTERNAL_PORTS=(3000 8080 8081 8123 8082 5580 5432)
PUBLIC_PORTS=(80 443)

echo "==================== ufw ===================="
ufw status verbose 2>/dev/null || echo "(ufw unavailable)"
echo
echo "==================== ufw rules (numbered) ===================="
ufw status numbered 2>/dev/null || true
echo

echo "==================== listening sockets ===================="
if command -v ss >/dev/null 2>&1; then
  ss -tulpnH | awk '{print $1"\t"$5}' | sort -u
else
  netstat -tulpn 2>/dev/null || true
fi
echo

echo "==================== DOCKER-USER (IPv4) ===================="
iptables -S DOCKER-USER 2>/dev/null || echo "(iptables unavailable)"
echo
echo "==================== DOCKER-USER (IPv6) ===================="
ip6tables -S DOCKER-USER 2>/dev/null || echo "(ip6tables unavailable)"
echo

echo "==================== Docker networks ===================="
if command -v docker >/dev/null 2>&1; then
  docker network ls -q 2>/dev/null \
    | xargs -r docker network inspect \
        --format '{{.Name}}  {{range .IPAM.Config}}{{.Subnet}} {{end}}' 2>/dev/null
else
  echo "(docker unavailable)"
fi
echo

echo "==================== loopback reachability (expected: OPEN) ===================="
for p in "${LOOPBACK_PORTS[@]}"; do
  if timeout 2 bash -c "</dev/tcp/127.0.0.1/$p" 2>/dev/null; then
    echo "  OPEN    127.0.0.1:$p"
  else
    echo "  closed  127.0.0.1:$p   <-- if the service is running and bound 0.0.0.0/127.0.0.1 this is unexpected"
  fi
done
echo

echo "==================== Traefik entrypoints (expected: OPEN) ===================="
for p in "${PUBLIC_PORTS[@]}"; do
  if timeout 2 bash -c "</dev/tcp/127.0.0.1/$p" 2>/dev/null; then
    echo "  OPEN    127.0.0.1:$p"
  else
    echo "  closed  127.0.0.1:$p"
  fi
done
echo

cat <<'EOF'
==================== WHAT TO DO NEXT ====================
Do NOT trust a self-test to the host's own LAN IP: traffic to your own address
travels over lo, which ufw always accepts, so blocked ports can look open.

Test from a DIFFERENT machine instead:

  nmap -Pn -p 80,443,3000,8080,8081,8123,8082,5580 <host-lan-ip>

Expected: only 80 and 443 open.

Also test over IPv6 if the host has a global address:

  nmap -6 -Pn -p 5580,8082,80,443 <host-global-v6>

To test from the internet, use a phone on mobile data or an external VPS.
Remember: this host is behind NAT, so unless a port is forwarded it will not be
reachable from the WAN over IPv4 - IPv6 is the one to double-check.
=========================================================
EOF
