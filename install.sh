#!/usr/bin/env bash

set -e

ROLE=$1

if [ -z "$ROLE" ]; then
 echo "Usage: install.sh [control|router]"
 exit 1
fi

source ./env

apt update
apt install -y curl ca-certificates gnupg lsb-release ethtool

if ! command -v docker >/dev/null; then

install -m 0755 -d /etc/apt/keyrings

curl -fsSL https://download.docker.com/linux/debian/gpg \
| gpg --dearmor -o /etc/apt/keyrings/docker.gpg

echo \
"deb [arch=$(dpkg --print-architecture) \
signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/debian \
$(lsb_release -cs) stable" \
| tee /etc/apt/sources.list.d/docker.list

apt update

apt install -y \
docker-ce \
docker-ce-cli \
containerd.io \
docker-compose-plugin

systemctl enable docker
systemctl start docker

fi

if [ "$ROLE" = "control" ]; then

echo "Installing Dockge"

mkdir -p /opt/dockge

cat <<EOF > /opt/dockge/compose.yaml
services:
 dockge:
  image: louislam/dockge
  restart: unless-stopped
  ports:
   - 5001:5001
  volumes:
   - /var/run/docker.sock:/var/run/docker.sock
   - ./data:/app/data
   - /opt/stacks:/opt/stacks
EOF

cd /opt/dockge
docker compose up -d

mkdir -p /opt/stacks
cp -r stacks/headscale-stack /opt/stacks/

cd /opt/stacks/headscale-stack

mkdir -p data/headscale

docker run --rm \
-v $(pwd)/data/headscale:/var/lib/headscale \
headscale/headscale generate private-key \
> data/headscale/noise_private.key

docker compose up -d

sleep 10

docker exec headscale headscale users create company || true

APIKEY=$(docker exec headscale headscale apikeys create | tail -n1)

echo $APIKEY > /root/headscale_api_key.txt

AUTHKEY=$(docker exec headscale \
headscale preauthkeys create \
--user 1 \
--reusable \
--expiration 720h | tail -n1)

echo $AUTHKEY > /root/headscale_auth_key.txt

echo "Headscale installed"

fi

if [ "$ROLE" = "router" ]; then

curl -fsSL https://tailscale.com/install.sh | sh

systemctl enable tailscaled
systemctl start tailscaled

cat <<EOF >> /etc/sysctl.conf

net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1

net.core.rmem_max=2500000
net.core.wmem_max=2500000

EOF

sysctl -p

IFACE=$(ip route get 1 | awk '{print $5;exit}')

ethtool -K $IFACE rx-udp-gro-forwarding on || true
ethtool -K $IFACE rx-gro-list off || true
ethtool -K $IFACE tx-udp-segmentation on || true

echo "Router ready"

fi
