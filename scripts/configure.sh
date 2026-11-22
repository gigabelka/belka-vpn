#!/usr/bin/env bash
# configure.sh — create belka-vpn env files without hardcoded server IPs.
#
# Interactive (on a server, as root):
#   bash scripts/configure.sh --role foreign
#   bash scripts/configure.sh --role ru
#
# Interactive (locally, then copy both files):
#   bash scripts/configure.sh --role both --output-dir ./env
#
# Non-interactive (values from the environment):
#   RU_PUBLIC_IP=... FOREIGN_PUBLIC_IP=... \
#     bash scripts/configure.sh --non-interactive --role both --output-dir /tmp/belka-env

set -euo pipefail
umask 077

ROLE=both
OUT_DIR=""
NON_INTERACTIVE=0

RU_PUBLIC_IP=${RU_PUBLIC_IP:-}
FOREIGN_PUBLIC_IP=${FOREIGN_PUBLIC_IP:-}
AWG_PORT=${AWG_PORT:-443}
TUNNEL_NET=${TUNNEL_NET:-172.16.0.0/24}
FOREIGN_TUNNEL_IP=${FOREIGN_TUNNEL_IP:-172.16.0.1}
RU_TUNNEL_IP=${RU_TUNNEL_IP:-172.16.0.2}
SOCKS_PORT=${SOCKS_PORT:-1080}
AWG_MTU=${AWG_MTU:-1280}
SSH_PORT=${SSH_PORT:-22}
REALITY_SNI=${REALITY_SNI:-www.microsoft.com}
ENABLE_FAIL2BAN=${ENABLE_FAIL2BAN:-1}
HARDEN_SSH=${HARDEN_SSH:-0}
INSTALL_HIDDIFY=${INSTALL_HIDDIFY:-1}
HIDDIFY_INSTALL_URL=${HIDDIFY_INSTALL_URL:-https://i.hiddify.com/release}
FOREIGN_HANDOFF_FILE=${FOREIGN_HANDOFF_FILE:-/etc/belka-vpn/foreign-handoff.env}
# FOREIGN only: RU's firewall is owned by Hiddify Manager, so ru.env always
# gets ENABLE_UFW=0.
FOREIGN_ENABLE_UFW=${ENABLE_UFW:-1}
AWG_ENABLE_S3S4=${AWG_ENABLE_S3S4:-0}
# FOREIGN only: Google domains over IPv6 (native, or HE tunnelbroker 6in4).
GOOGLE_IPV6_EGRESS=${GOOGLE_IPV6_EGRESS:-0}
HE_SERVER_IPV4=${HE_SERVER_IPV4:-}
HE_CLIENT_IPV6=${HE_CLIENT_IPV6:-}

usage() {
  cat <<'EOF'
Usage: configure.sh [options]

Options:
  --role ru|foreign|both   Which env files to create (default: both)
  --output-dir DIR         Destination (default: /etc/belka-vpn for root, ./env otherwise)
  --non-interactive        Read values from the environment; fail if a required IP is missing
  -h, --help               Show this help

Created files:
  ru.env       — Russian entry server
  foreign.env  — foreign egress server

No private keys, passwords or tokens are written.
EOF
}

say() { printf '%s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

while (( $# )); do
  case "$1" in
    --role) ROLE=$2; shift 2 ;;
    --output-dir) OUT_DIR=$2; shift 2 ;;
    --non-interactive) NON_INTERACTIVE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

case "$ROLE" in
  ru|foreign|both) ;;
  *) die "--role must be ru, foreign or both" ;;
esac

is_ipv4() {
  local ip=$1
  [[ $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  local -a o
  IFS=. read -r -a o <<< "$ip"
  local n
  for n in "${o[@]}"; do
    (( 10#$n >= 0 && 10#$n <= 255 )) || return 1
  done
  return 0
}

is_port() {
  [[ $1 =~ ^[0-9]+$ ]] || return 1
  (( 10#$1 >= 1 && 10#$1 <= 65535 ))
}

is_private_ip() {
  case "$1" in
    10.*|127.*|169.254.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*)
      return 0 ;;
    # 100.64.0.0/10 (CGNAT): second octet 64..127
    100.6[4-9].*|100.[7-9][0-9].*|100.1[01][0-9].*|100.12[0-7].*)
      return 0 ;;
    *) return 1 ;;
  esac
}

ask_required_ip() {
  local var=$1 label=$2 value
  while true; do
    if (( NON_INTERACTIVE )); then
      value=${!var:-}
    else
      read -r -p "$label (IPv4): " value
    fi
    if [[ -z $value ]]; then
      if (( NON_INTERACTIVE )); then
        die "$var is required (set it in the environment)"
      fi
      warn "$label is required"
      continue
    fi
    if ! is_ipv4 "$value"; then
      if (( NON_INTERACTIVE )); then
        die "$var is not a valid IPv4 address: $value"
      fi
      warn "not a valid IPv4 address: $value"
      continue
    fi
    if [[ $value == 0.0.0.0 ]]; then
      if (( NON_INTERACTIVE )); then
        die "$var must not be 0.0.0.0"
      fi
      warn "0.0.0.0 is not a server address"
      continue
    fi
    # A private/loopback/CGNAT address cannot be the peer's public endpoint,
    # and FOREIGN's UFW rule would admit the wrong source.
    if is_private_ip "$value"; then
      if (( NON_INTERACTIVE )); then
        die "$var must be a public IPv4 address, not private/loopback/CGNAT: $value"
      fi
      warn "$value is a private/loopback/CGNAT address; enter the public IPv4"
      continue
    fi
    printf -v "$var" '%s' "$value"
    return 0
  done
}

ask_value() {
  local var=$1 label=$2 default=$3 value
  if (( NON_INTERACTIVE )); then
    value=${!var:-$default}
  else
    read -r -p "$label [$default]: " value
    value=${value:-$default}
  fi
  printf -v "$var" '%s' "$value"
}

ask_ipv4() {
  local var=$1 label=$2 default=$3 value
  while true; do
    if (( NON_INTERACTIVE )); then
      value=${!var:-$default}
    else
      read -r -p "$label [$default]: " value
      value=${value:-$default}
    fi
    if is_ipv4 "$value"; then
      printf -v "$var" '%s' "$value"
      return 0
    fi
    if (( NON_INTERACTIVE )); then
      die "$var is not a valid IPv4 address: $value"
    fi
    warn "not a valid IPv4 address: $value"
  done
}

ask_port() {
  local var=$1 label=$2 default=$3 value
  while true; do
    if (( NON_INTERACTIVE )); then
      value=${!var:-$default}
    else
      read -r -p "$label [$default]: " value
      value=${value:-$default}
    fi
    if is_port "$value"; then
      printf -v "$var" '%s' "$value"
      return 0
    fi
    if (( NON_INTERACTIVE )); then
      die "$var is not a valid port: $value"
    fi
    warn "port must be 1..65535"
  done
}

ip_int() {
  local -a o
  IFS=. read -r -a o <<< "$1"
  printf '%s\n' $(( (10#${o[0]} << 24) | (10#${o[1]} << 16) | (10#${o[2]} << 8) | 10#${o[3]} ))
}

# Same rules as validate_tunnel_net in lib.sh: CIDR /8../30, no host bits,
# both tunnel IPs are host addresses inside it.
check_tunnel_net() {
  local net=${TUNNEL_NET%/*} prefix=${TUNNEL_NET##*/} net_i mask ip v
  [[ $TUNNEL_NET == */* && $prefix =~ ^[0-9]{1,2}$ ]] && is_ipv4 "$net" \
    || die "TUNNEL_NET must be CIDR like 172.16.0.0/24: $TUNNEL_NET"
  prefix=$((10#$prefix))
  (( prefix >= 8 && prefix <= 30 )) || die "TUNNEL_NET prefix must be /8../30: $TUNNEL_NET"
  net_i=$(ip_int "$net")
  mask=$(( (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF ))
  (( (net_i & mask) == net_i )) || die "TUNNEL_NET has host bits set: $TUNNEL_NET"
  for v in FOREIGN_TUNNEL_IP RU_TUNNEL_IP; do
    ip=$(ip_int "${!v}")
    (( (ip & mask) == net_i )) || die "$v=${!v} is outside TUNNEL_NET=$TUNNEL_NET"
    (( ip != net_i && ip != (net_i | (~mask & 0xFFFFFFFF)) )) \
      || die "$v=${!v} is the network or broadcast address of $TUNNEL_NET"
  done
}

ask_required_ip RU_PUBLIC_IP "Russian server public IP"
ask_required_ip FOREIGN_PUBLIC_IP "Foreign server public IP"
[[ $RU_PUBLIC_IP != "$FOREIGN_PUBLIC_IP" ]] \
  || die "RU_PUBLIC_IP and FOREIGN_PUBLIC_IP must differ"

ask_port AWG_PORT "AmneziaWG UDP port" "$AWG_PORT"
ask_value TUNNEL_NET "Tunnel network" "$TUNNEL_NET"
ask_ipv4 FOREIGN_TUNNEL_IP "Foreign tunnel IP" "$FOREIGN_TUNNEL_IP"
ask_ipv4 RU_TUNNEL_IP "RU tunnel IP" "$RU_TUNNEL_IP"
[[ $FOREIGN_TUNNEL_IP != "$RU_TUNNEL_IP" ]] \
  || die "tunnel IPs must differ"
check_tunnel_net
ask_port SOCKS_PORT "SOCKS port on the foreign tunnel IP" "$SOCKS_PORT"
ask_port SSH_PORT "SSH port" "$SSH_PORT"
ask_value AWG_MTU "AmneziaWG MTU" "$AWG_MTU"
ask_value REALITY_SNI "Reality SNI candidate" "$REALITY_SNI"

if [[ -z $OUT_DIR ]]; then
  if (( EUID == 0 )); then
    OUT_DIR=/etc/belka-vpn
  else
    OUT_DIR=./env
  fi
fi

if [[ ! -d $OUT_DIR ]]; then
  mkdir -p -m 700 "$OUT_DIR"
fi

write_env() {
  local dst=$1
  local tmp
  tmp=$(mktemp)
  cat > "$tmp"
  install -m 600 "$tmp" "$dst"
  chmod 600 "$dst" 2>/dev/null || true
  rm -f "$tmp"
  say "created $dst (0600)"
}

write_ru_env() {
  write_env "$OUT_DIR/ru.env" <<EOF
# Generated by scripts/configure.sh — public data only.
# /etc/belka-vpn/ru.env
RU_PUBLIC_IP=${RU_PUBLIC_IP}
FOREIGN_PUBLIC_IP=${FOREIGN_PUBLIC_IP}

AWG_PORT=${AWG_PORT}
TUNNEL_NET=${TUNNEL_NET}
FOREIGN_TUNNEL_IP=${FOREIGN_TUNNEL_IP}
RU_TUNNEL_IP=${RU_TUNNEL_IP}
AWG_MTU=${AWG_MTU}
SOCKS_PORT=${SOCKS_PORT}
SSH_PORT=${SSH_PORT}

ENABLE_UFW=0
ENABLE_FAIL2BAN=${ENABLE_FAIL2BAN}
INSTALL_HIDDIFY=${INSTALL_HIDDIFY}
HIDDIFY_INSTALL_URL=${HIDDIFY_INSTALL_URL}
HARDEN_SSH=${HARDEN_SSH}
REALITY_SNI=${REALITY_SNI}
FOREIGN_HANDOFF_FILE=${FOREIGN_HANDOFF_FILE}
EOF
}

write_foreign_env() {
  write_env "$OUT_DIR/foreign.env" <<EOF
# Generated by scripts/configure.sh — public data only.
# /etc/belka-vpn/foreign.env
FOREIGN_PUBLIC_IP=${FOREIGN_PUBLIC_IP}
RU_PUBLIC_IP=${RU_PUBLIC_IP}

AWG_PORT=${AWG_PORT}
TUNNEL_NET=${TUNNEL_NET}
FOREIGN_TUNNEL_IP=${FOREIGN_TUNNEL_IP}
RU_TUNNEL_IP=${RU_TUNNEL_IP}
AWG_MTU=${AWG_MTU}
SOCKS_PORT=${SOCKS_PORT}
SSH_PORT=${SSH_PORT}

ENABLE_UFW=${FOREIGN_ENABLE_UFW}
ENABLE_FAIL2BAN=${ENABLE_FAIL2BAN}
AWG_ENABLE_S3S4=${AWG_ENABLE_S3S4}
HARDEN_SSH=${HARDEN_SSH}

# Google domains over IPv6 when Google geolocates the IPv4 exit as RU.
GOOGLE_IPV6_EGRESS=${GOOGLE_IPV6_EGRESS}
HE_SERVER_IPV4=${HE_SERVER_IPV4}
HE_CLIENT_IPV6=${HE_CLIENT_IPV6}
EOF
}

case "$ROLE" in
  both) write_ru_env; write_foreign_env ;;
  ru) write_ru_env ;;
  foreign) write_foreign_env ;;
esac

say ""
say "Next steps:"
if [[ $ROLE == both ]]; then
  say "  Copy the files to the servers:"
  say "    scp $OUT_DIR/ru.env root@${RU_PUBLIC_IP}:/etc/belka-vpn/ru.env"
  say "    scp $OUT_DIR/foreign.env root@${FOREIGN_PUBLIC_IP}:/etc/belka-vpn/foreign.env"
  say "  Or run this script separately on each server."
elif [[ $ROLE == foreign ]]; then
  say "  bash scripts/install-foreign.sh --env-file $OUT_DIR/foreign.env"
else
  say "  bash scripts/install-ru.sh --env-file $OUT_DIR/ru.env"
fi
say "  No private keys or passwords are stored in these files."
