#!/usr/bin/env bash
# Runs as root inside the proxy container (called by devbox).
#   $1 = sandbox subnet, e.g. 10.213.88.0/24
#   $2 = this container's address on the sandbox network, e.g. 10.213.88.2/24
set -euo pipefail
SUBNET="$1"
ADDR="$2"
export DEBIAN_FRONTEND=noninteractive

for _ in $(seq 60); do getent hosts deb.debian.org >/dev/null && break; sleep 1; done

# eth0 = uplink (DHCP, default route). eth1 = isolated sandbox network:
# static address, no gateway, configured independently of the image's network manager.
cat >/etc/systemd/system/devbox-sandbox-net.service <<EOF
[Unit]
Description=Static address on the sandbox network
After=network.target
Before=squid.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/ip link set eth1 up
ExecStart=/usr/sbin/ip addr replace $ADDR dev eth1

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now devbox-sandbox-net.service

apt-get update -q
apt-get install -yq --no-install-recommends squid

install -m 0644 /root/allowed-domains.txt /root/denied-domains.txt /etc/squid/
echo '# locked: only domains in allowed-domains.txt' >/etc/squid/devbox-mode.conf

cat >/etc/squid/squid.conf <<EOF
http_port 3128

acl sandbox src $SUBNET
acl allowed dstdomain "/etc/squid/allowed-domains.txt"
acl Safe_ports port 80 443
acl SSL_ports port 443
acl CONNECT method CONNECT

http_access deny !Safe_ports
http_access deny CONNECT !SSL_ports
http_access deny !sandbox
# "devbox unlock <vm>" opens the proxy for one VM here; "devbox lock" clears it.
include /etc/squid/devbox-mode.conf
acl denied dstdomain "/etc/squid/denied-domains.txt"
http_access deny denied
http_access allow allowed
http_access deny all

cache deny all
forwarded_for delete
via off

logformat devbox %{%Y-%m-%dT%H:%M:%S}tl %>a %Ss/%03>Hs %rm %ru
access_log daemon:/var/log/squid/access.log logformat=devbox
coredump_dir /var/spool/squid
EOF

squid -k parse
systemctl enable squid
systemctl restart squid
echo "proxy ready on ${ADDR%/*}:3128"
