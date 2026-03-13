# Headscale Stack Bootstrap

Bootstrap pro cisty Debian 13:

- nainstaluje `curl`, Docker a Dockge
- v Dockeru nasadi Headscale, Headplane a Caddy
- vytvori Headscale uzivatele a vygeneruje klice
- pripravi subnet router na hostu pres `tailscaled`, ne v kontejneru

## Konfigurace

Zkopiruj `env.example` do `env` a uprav hlavne:

- `VPN_DOMAIN`
- `AD_DOMAIN` nebo `SEARCH_DOMAIN`
- `AD_DNS_SERVER` nebo `DNS_SERVER`
- `LOCAL_SUBNET` nebo `LAN_SUBNET`

Dalsi uzitecne promenne:

- `ACME_EMAIL`
- `HEADSCALE_USER`
- `TAILNET_DOMAIN`
- `DOCKGE_PORT`
- `TAILSCALE_AUTH_KEY`
- `ROUTER_HOSTNAME`
- `ROUTER_ADVERTISE_ROUTES`

## Pouziti

Control server:

```bash
git clone git@github.com:pokys/Headscale-stack-bootstrap.git
cd Headscale-stack-bootstrap
cp env.example env
nano env
sudo ./install.sh control
```

Subnet router na hostu:

```bash
sudo ./install.sh router
```

Pokud neni vyplnene `TAILSCALE_AUTH_KEY`, skript po instalaci routeru vypise presny `tailscale up` prikaz pro rucni pripojeni.

Ukazkovy rucni prikaz pro router:

```bash
tailscale up \
  --login-server https://VPN_DOMAIN \
  --auth-key AUTH_KEY \
  --advertise-routes ROUTER_ADVERTISE_ROUTES \
  --hostname ROUTER_HOSTNAME \
  --accept-dns=false
```

Pouzij ho hlavne kdyz:

- je problem s DNS behem `./install.sh router`
- chces router prihlasit rucne az po oprave site
- potrebujes znovu spustit `tailscale up` bez celeho bootstrapu

Ukazkovy rucni prikaz pro pridani bezneho PC:

```bash
tailscale up \
  --login-server https://VPN_DOMAIN \
  --auth-key AUTH_KEY \
  --hostname PC_HOSTNAME \
  --accept-dns=true
```

Pouzij ho hlavne kdyz:

- chces rucne pripojit Windows, Linux nebo macOS klienta
- potrebujes otestovat novy auth key mimo bootstrap
- nechces na klientovi zadavat subnet route parametry

## Doporuceny postup test deploye

1. Priprav cisty Debian 13 server pro control node.
2. Nastav DNS zaznam `VPN_DOMAIN` na verejnou IP control serveru.
3. Naklonuj repo, vytvor `env` a vypln realne hodnoty.
4. Spust `sudo ./install.sh control`.
5. Pockej, az dobehnou kontejnery a zkontroluj `docker ps`.
6. Otevri `https://VPN_DOMAIN/admin`.
7. Zkontroluj soubory `/root/headscale_api_key.txt`, `/root/headscale_auth_key.txt` a `/root/headscale-bootstrap.txt`.
8. Priprav druhy cisty Debian 13 server pro subnet router.
9. Zkopiruj na nej stejny `env`, pripadne uprav `ROUTER_HOSTNAME` a `ROUTER_ADVERTISE_ROUTES`.
10. Spust `sudo ./install.sh router`.
11. Pokud nebyl vyplnen `TAILSCALE_AUTH_KEY`, spust vypsany `tailscale up` prikaz rucne.
12. Ve Headscale schval subnet routes, pokud nebude povoleni automaticke.

## Kontrolni checklist

Po `control` instalaci:

- `docker ps` obsahuje `headscale`, `headplane`, `caddy` a `dockge`
- `curl -I http://127.0.0.1:8080` na hostu vraci odpoved od Headscale
- `https://VPN_DOMAIN/admin` se otevre
- `/root/headscale_api_key.txt` existuje a neni prazdny
- `/root/headscale_auth_key.txt` existuje a neni prazdny
- `/opt/stacks/headscale-stack/data/headscale/noise_private.key` existuje

Po `router` instalaci:

- `systemctl status tailscaled` je aktivni
- `tailscale status` ukazuje pripojeny router
- `tailscale status --json` obsahuje inzerovanou sit
- route `ROUTER_ADVERTISE_ROUTES` je ve Headscale videt a schvalena
- klient pripojeny do tailnetu se dostane do `LOCAL_SUBNET`

## Vysledek

- Dockge: `http://SERVER_IP:DOCKGE_PORT`
- Headplane: `https://VPN_DOMAIN/admin`
- Headscale API: `https://VPN_DOMAIN`
- API key: `/root/headscale_api_key.txt`
- Auth key: `/root/headscale_auth_key.txt`
- Shrnuti instalace: `/root/headscale-bootstrap.txt`
