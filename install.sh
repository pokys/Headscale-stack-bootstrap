#!/usr/bin/env bash

set -Eeuo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

ROLE="${1:-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-${SCRIPT_DIR}/env}"
STACK_SRC_DIR="${SCRIPT_DIR}/stacks/headscale-stack"
STACK_DST_DIR="/opt/stacks/headscale-stack"
DOCKGE_DIR="/opt/dockge"
STACK_ENV_FILE="${STACK_DST_DIR}/.env"
HEADSCALE_CONFIG_PATH="/etc/headscale/config.yaml"

log() {
  printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"
}

headscale_exec() {
  docker exec headscale headscale --config "${HEADSCALE_CONFIG_PATH}" "$@"
}

get_headscale_user_id() {
  headscale_exec users list --output json \
    | jq -r --arg user "${HEADSCALE_USER}" '.[] | select(.name == $user) | .id' \
    | head -n1
}

usage() {
  echo "Usage: sudo ./install.sh [control|router]"
}

require_root() {
  if [ "${EUID}" -ne 0 ]; then
    echo "Run this script as root."
    exit 1
  fi
}

load_env() {
  if [ ! -f "${ENV_FILE}" ]; then
    echo "Missing env file: ${ENV_FILE}"
    echo "Create it first: cp env.example env"
    exit 1
  fi

  # shellcheck disable=SC1090
  source "${ENV_FILE}"

  : "${VPN_DOMAIN:?Missing VPN_DOMAIN in ${ENV_FILE}}"

  LOCAL_SUBNET="${LOCAL_SUBNET:-${LAN_SUBNET:-}}"
  AD_DNS_SERVER="${AD_DNS_SERVER:-${DNS_SERVER:-}}"
  AD_DOMAIN="${AD_DOMAIN:-${SEARCH_DOMAIN:-}}"
  TAILNET_DOMAIN="${TAILNET_DOMAIN:-tailnet.internal}"
  ACME_EMAIL="${ACME_EMAIL:-myemail+letsencrypt@example.com}"
  HEADSCALE_USER="${HEADSCALE_USER:-company}"
  DOCKGE_PORT="${DOCKGE_PORT:-5001}"
  HEADPLANE_HEADSCALE_URL_MODE="${HEADPLANE_HEADSCALE_URL_MODE:-internal}"
  TAILSCALE_AUTH_KEY="${TAILSCALE_AUTH_KEY:-}"
  ROUTER_HOSTNAME="${ROUTER_HOSTNAME:-$(hostname -s)}"
  ROUTER_ADVERTISE_ROUTES="${ROUTER_ADVERTISE_ROUTES:-${LOCAL_SUBNET}}"

  : "${LOCAL_SUBNET:?Missing LOCAL_SUBNET or LAN_SUBNET in ${ENV_FILE}}"
  : "${AD_DNS_SERVER:?Missing AD_DNS_SERVER or DNS_SERVER in ${ENV_FILE}}"
  : "${AD_DOMAIN:?Missing AD_DOMAIN or SEARCH_DOMAIN in ${ENV_FILE}}"
}

install_base_packages() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y curl ca-certificates gnupg jq lsb-release ethtool openssl procps
}

install_docker() {
  if command -v docker >/dev/null 2>&1; then
    systemctl enable docker
    systemctl start docker
    return
  fi

  install -m 0755 -d /etc/apt/keyrings

  curl -fsSL https://download.docker.com/linux/debian/gpg \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg

  echo \
    "deb [arch=$(dpkg --print-architecture) \
signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/debian \
$(lsb_release -cs) stable" \
    > /etc/apt/sources.list.d/docker.list

  apt-get update
  apt-get install -y \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-compose-plugin

  systemctl enable docker
  systemctl start docker
}

replace_yaml_value() {
  local file="$1"
  local key="$2"
  local value="$3"
  sed -i "s|^${key}: .*|${key}: ${value}|" "${file}"
}

replace_indented_value() {
  local file="$1"
  local indent="$2"
  local value="$3"
  sed -i "s|^${indent}- .*|${indent}- ${value}|" "${file}"
}

replace_first_match() {
  local file="$1"
  local pattern="$2"
  local replacement="$3"
  sed -i "0,/${pattern}/s||${replacement}|" "${file}"
}

configure_control_stack() {
  local headscale_cfg="${STACK_DST_DIR}/config/headscale/config.yaml"
  local headplane_cfg="${STACK_DST_DIR}/config/headplane/config.yaml"
  local caddy_cfg="${STACK_DST_DIR}/config/caddy/Caddyfile"
  local cookie_secret
  local headplane_headscale_url

  cookie_secret="$(openssl rand -hex 16)"
  headplane_headscale_url="http://headscale:8080"

  case "${HEADPLANE_HEADSCALE_URL_MODE}" in
    internal)
      ;;
    public)
      headplane_headscale_url="https://${VPN_DOMAIN}"
      ;;
    *)
      echo "Invalid HEADPLANE_HEADSCALE_URL_MODE: ${HEADPLANE_HEADSCALE_URL_MODE}"
      echo "Supported values: internal, public"
      exit 1
      ;;
  esac

  replace_yaml_value "${headscale_cfg}" "server_url" "https://${VPN_DOMAIN}"
  replace_yaml_value "${headscale_cfg}" "  base_domain" "${TAILNET_DOMAIN}"
  replace_first_match "${headscale_cfg}" "^      - .*" "      - ${AD_DNS_SERVER}"
  replace_first_match "${headscale_cfg}" "^    - .*" "    - ${AD_DOMAIN}"

  replace_yaml_value "${headplane_cfg}" "  cookie_secret" "${cookie_secret}"
  replace_yaml_value "${headplane_cfg}" "  url" "${headplane_headscale_url}"

  sed -i "s|^vpn\.corp\.cz {|${VPN_DOMAIN} {|" "${caddy_cfg}"
  sed -i "s|^    tls .*|    tls ${ACME_EMAIL}|" "${caddy_cfg}"
}

write_stack_env() {
  cat > "${STACK_ENV_FILE}" <<EOF
ROOT_API_KEY=
EOF
}

install_dockge() {
  mkdir -p "${DOCKGE_DIR}/data"

  cat > "${DOCKGE_DIR}/compose.yaml" <<EOF
services:
 dockge:
  image: louislam/dockge
  restart: unless-stopped
  ports:
   - ${DOCKGE_PORT}:5001
  volumes:
   - /var/run/docker.sock:/var/run/docker.sock
   - ./data:/app/data
   - /opt/stacks:/opt/stacks
EOF

  cd "${DOCKGE_DIR}"
  docker compose up -d
}

deploy_control_stack() {
  mkdir -p /opt/stacks
  mkdir -p "${STACK_DST_DIR}"
  cp -r "${STACK_SRC_DIR}/." "${STACK_DST_DIR}/"

  mkdir -p "${STACK_DST_DIR}/data/headscale"
  mkdir -p "${STACK_DST_DIR}/data/caddy"

  configure_control_stack
  write_stack_env

  if [ ! -s "${STACK_DST_DIR}/data/headscale/noise_private.key" ]; then
    docker run --rm \
      -v "${STACK_DST_DIR}/data/headscale:/var/lib/headscale" \
      headscale/headscale generate private-key \
      > "${STACK_DST_DIR}/data/headscale/noise_private.key"
  fi

  cd "${STACK_DST_DIR}"
  docker compose up -d
}

wait_for_headscale() {
  local retries=20

  until headscale_exec users list >/dev/null 2>&1; do
    retries=$((retries - 1))
    if [ "${retries}" -le 0 ]; then
      echo "Headscale did not become ready in time."
      exit 1
    fi
    sleep 3
  done
}

create_headscale_assets() {
  local api_key
  local user_id

  headscale_exec users create "${HEADSCALE_USER}" >/dev/null 2>&1 || true
  user_id="$(get_headscale_user_id)"

  if [ -z "${user_id}" ] || [ "${user_id}" = "null" ]; then
    echo "Unable to resolve Headscale user ID for ${HEADSCALE_USER}."
    exit 1
  fi

  if [ ! -s /root/headscale_api_key.txt ]; then
    headscale_exec apikeys create \
      | awk 'NF { line = $0 } END { print line }' \
      > /root/headscale_api_key.txt
  fi

  api_key="$(tr -d '\r\n' < /root/headscale_api_key.txt)"
  sed -i "s|^ROOT_API_KEY=.*|ROOT_API_KEY=${api_key}|" "${STACK_ENV_FILE}"
  (
    cd "${STACK_DST_DIR}"
    docker compose up -d headplane
  )

  if [ ! -s /root/headscale_auth_key.txt ]; then
    headscale_exec preauthkeys create \
      --user "${user_id}" \
      --reusable \
      --expiration 720h \
      | awk 'NF { line = $0 } END { print line }' \
      > /root/headscale_auth_key.txt
  fi
}

write_control_summary() {
  cat > /root/headscale-bootstrap.txt <<EOF
VPN domain: ${VPN_DOMAIN}
AD domain: ${AD_DOMAIN}
AD DNS server: ${AD_DNS_SERVER}
Local subnet: ${LOCAL_SUBNET}
Headscale user: ${HEADSCALE_USER}
Tailnet domain: ${TAILNET_DOMAIN}
Dockge URL: http://$(hostname -I | awk '{print $1}'):${DOCKGE_PORT}
Headplane URL: https://${VPN_DOMAIN}/admin
Headscale API key: /root/headscale_api_key.txt
Headscale auth key: /root/headscale_auth_key.txt
Headscale noise key: ${STACK_DST_DIR}/data/headscale/noise_private.key
Headplane env file: ${STACK_ENV_FILE}
EOF
}

print_control_summary() {
  cat <<EOF

Generated artifacts:
- Headscale API key: /root/headscale_api_key.txt
- Headscale auth key: /root/headscale_auth_key.txt
- Headscale noise key: ${STACK_DST_DIR}/data/headscale/noise_private.key
- Headplane env with ROOT_API_KEY: ${STACK_ENV_FILE}
- Deployment summary: /root/headscale-bootstrap.txt
EOF
}

install_control() {
  install_base_packages
  install_docker
  install_dockge
  deploy_control_stack
  wait_for_headscale
  create_headscale_assets
  write_control_summary
  log "Headscale control node is ready"
  print_control_summary
}

install_tailscale() {
  if ! command -v tailscale >/dev/null 2>&1; then
    curl -fsSL https://tailscale.com/install.sh | sh
  fi

  systemctl enable tailscaled
  systemctl start tailscaled
}

configure_router_host() {
  cat > /etc/sysctl.d/99-headscale-router.conf <<EOF
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
net.core.rmem_max=2500000
net.core.wmem_max=2500000
EOF

  sysctl --system >/dev/null

  IFACE="$(ip route get 1 | awk '{print $5;exit}')"
  if [ -n "${IFACE}" ]; then
    ethtool -K "${IFACE}" rx-udp-gro-forwarding on || true
    ethtool -K "${IFACE}" rx-gro-list off || true
    ethtool -K "${IFACE}" tx-udp-segmentation on || true
  fi
}

connect_router() {
  if [ -z "${TAILSCALE_AUTH_KEY}" ]; then
    log "Subnet router is installed on host. Connect it manually with:"
    echo "tailscale up --login-server https://${VPN_DOMAIN} --auth-key <AUTH_KEY> --advertise-routes ${ROUTER_ADVERTISE_ROUTES} --hostname ${ROUTER_HOSTNAME} --accept-dns=false"
    return
  fi

  tailscale up \
    --login-server "https://${VPN_DOMAIN}" \
    --auth-key "${TAILSCALE_AUTH_KEY}" \
    --advertise-routes "${ROUTER_ADVERTISE_ROUTES}" \
    --hostname "${ROUTER_HOSTNAME}" \
    --accept-dns=false
}

install_router() {
  install_base_packages
  install_tailscale
  configure_router_host
  connect_router
  log "Subnet router on host is ready"
}

main() {
  if [ -z "${ROLE}" ]; then
    usage
    exit 1
  fi

  require_root
  load_env

  case "${ROLE}" in
    control)
      install_control
      ;;
    router)
      install_router
      ;;
    *)
      usage
      exit 1
      ;;
  esac
}

main "$@"
