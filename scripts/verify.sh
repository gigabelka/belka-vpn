#!/usr/bin/env bash
# verify.sh — end-to-end checks for belka-vpn.
#
# On RU:  bash scripts/verify.sh
# On FOREIGN:  bash scripts/verify.sh --role foreign
#
# Exit code 0 only when there are no FAIL results.

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

TARGET_ROLE=ru
while (( $# )); do
  case "$1" in
    --role) TARGET_ROLE=$2; shift 2 ;;
    -h|--help)
      echo "Usage: verify.sh [--role ru|foreign]"
      exit 0
      ;;
    *) echo "unknown argument: $1" >&2; exit 1 ;;
  esac
done

belka_init verify
need_root
case "$TARGET_ROLE" in
  ru) ENV_FILE=${ENV_FILE:-/etc/belka-vpn/ru.env} ;;
  foreign) ENV_FILE=${ENV_FILE:-/etc/belka-vpn/foreign.env} ;;
  *) die "role must be ru or foreign" ;;
esac
load_env_file "$ENV_FILE" || warn "env file not found: $ENV_FILE"
apply_defaults

if [[ $TARGET_ROLE == ru ]]; then
  if [[ -r /etc/belka-vpn/foreign-handoff.env ]]; then
    load_handoff /etc/belka-vpn/foreign-handoff.env
  elif [[ -r /root/belka-foreign-handoff.env ]]; then
    load_handoff /root/belka-foreign-handoff.env
  else
    warn "FOREIGN handoff not found; using env defaults for the tunnel endpoints"
  fi
fi

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); log PASS "$*"; }
bad() { FAIL=$((FAIL + 1)); log FAIL "$*"; }

check_awg() {
  if systemctl is-active -q awg-quick@awg0; then
    ok "awg-quick@awg0 is active"
  else
    bad "awg-quick@awg0 is not active"
    return
  fi

  local hs age rx
  hs=$(awg show awg0 latest-handshakes 2>/dev/null | awk 'NR==1{print $2}')
  hs=${hs:-0}
  age=$(( $(date +%s) - hs ))
  if (( hs > 0 && age < 180 )); then
    ok "AmneziaWG handshake ${age}s ago"
  else
    bad "AmneziaWG handshake missing/stale (${age}s)"
  fi

  rx=$(awg show awg0 transfer 2>/dev/null | awk 'NR==1{print $2}')
  if (( ${rx:-0} > 0 )); then
    ok "AmneziaWG RX ${rx} bytes"
  else
    bad "no RX traffic on awg0"
  fi
}

check_foreign() {
  check_awg
  if systemctl is-active -q xray; then
    ok "xray is active"
  else
    bad "xray is not active"
  fi
  if ss -lntp 2>/dev/null | grep -Fq "${FOREIGN_TUNNEL_IP}:${SOCKS_PORT}"; then
    ok "SOCKS listens on ${FOREIGN_TUNNEL_IP}:${SOCKS_PORT}"
  else
    bad "SOCKS does not listen on ${FOREIGN_TUNNEL_IP}:${SOCKS_PORT}"
  fi
  if ss -lntu 2>/dev/null | grep -Eq "0\.0\.0\.0:${SOCKS_PORT}|\[::\]:${SOCKS_PORT}"; then
    bad "SOCKS is exposed publicly on port ${SOCKS_PORT}"
  else
    ok "SOCKS is not exposed publicly"
  fi
  if ufw status 2>/dev/null | grep -q "Status: active"; then
    ok "ufw is active"
  else
    warn "ufw is not active (check provider firewall)"
  fi
}

check_ru() {
  check_awg

  if timeout 5 bash -c "</dev/tcp/${FOREIGN_TUNNEL_IP}/${SOCKS_PORT}" 2>/dev/null; then
    ok "SOCKS TCP reachable at ${FOREIGN_TUNNEL_IP}:${SOCKS_PORT}"
  else
    bad "SOCKS TCP unreachable at ${FOREIGN_TUNNEL_IP}:${SOCKS_PORT}"
    return
  fi

  local egress code
  egress=$(curl -4 -fsS --max-time 15 --socks5-hostname "${FOREIGN_TUNNEL_IP}:${SOCKS_PORT}" \
    https://api.ipify.org 2>/dev/null || true)
  if [[ $egress == "${FOREIGN_PUBLIC_IP}" ]]; then
    ok "egress via FOREIGN is ${egress}"
  elif [[ -n $egress ]]; then
    warn "egress via FOREIGN is ${egress}, expected ${FOREIGN_PUBLIC_IP} (NAT?)"
  else
    bad "SOCKS egress check failed"
  fi

  code=$(curl -4 -sS -o /dev/null -w '%{http_code}' --max-time 20 \
    --socks5-hostname "${FOREIGN_TUNNEL_IP}:${SOCKS_PORT}" \
    https://www.youtube.com/generate_204 2>/dev/null || true)
  if [[ $code == 204 ]]; then
    ok "YouTube via FOREIGN returns 204"
  else
    bad "YouTube via FOREIGN returns ${code:-no response}"
  fi

  code=$(curl -4 -sS -o /dev/null -w '%{http_code}' --max-time 20 \
    --socks5-hostname "${FOREIGN_TUNNEL_IP}:${SOCKS_PORT}" \
    https://api.anthropic.com/v1/messages 2>/dev/null || true)
  case "$code" in
    400|401|404|405) ok "Anthropic via FOREIGN returns ${code} (not region-blocked)" ;;
    403) bad "Anthropic returns 403: the exit is still blocked or not FOREIGN" ;;
    *) warn "Anthropic returned ${code:-no response}; check manually" ;;
  esac

  if systemctl list-units --type=service --state=running 'hiddify*' --no-legend 2>/dev/null | grep -q .; then
    ok "Hiddify services are running"
  else
    bad "Hiddify services are not running"
  fi

  if ss -lntp 2>/dev/null | grep -q ':443 '; then
    ok "TCP/443 is listening"
  else
    warn "TCP/443 is not listening yet (Reality inbound not applied?)"
  fi

  if [[ -d /opt/hiddify-manager ]]; then
    ok "Hiddify Manager is installed"
  else
    bad "Hiddify Manager is missing"
  fi
}

if [[ $TARGET_ROLE == foreign ]]; then
  check_foreign
else
  check_ru
fi

log INFO "result: PASS=${PASS} FAIL=${FAIL}"
if (( FAIL > 0 )); then
  exit 1
fi
