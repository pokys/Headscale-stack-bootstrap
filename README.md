# Headscale Stack Bootstrap

Bootstrap deployment for:

- Headscale
- Headplane
- Caddy
- Dockge

Designed for Debian / Ubuntu servers.

## Features

- automatic Docker installation
- Dockge stack manager
- Headscale server
- Headplane GUI
- Caddy reverse proxy
- automatic key generation
- MagicDNS support

## Usage

Clone repo:

git clone https://github.com/pokys/Headscale-stack-bootstrap
cd Headscale-stack-bootstrap

Configure environment:

cp env.example env
nano env

Install control server:

sudo ./install.sh control

Install subnet router:

sudo ./install.sh router

## Services

Dockge:

http://SERVER_IP:5001

Headplane:

https://VPN_DOMAIN
