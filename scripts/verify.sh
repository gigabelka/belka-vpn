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

check_hiddify_routing() {
  local cfg=/opt/hiddify-manager/generated/xray.json
  [[ -d /opt/hiddify-manager ]] || return 0
  if [[ ! -r $cfg ]]; then
    warn "Hiddify xray config not found: $cfg (panel not applied yet?)"
    return 0
  fi
  if ! command -v jq >/dev/null 2>&1; then
    warn "jq not found; skipping Hiddify routing checks"
    return 0
  fi
  if ! jq -e . "$cfg" >/dev/null 2>&1; then
    bad "Hiddify generated xray config is not valid JSON"
    return 0
  fi

  # Hiddify 14.x writes SOCKS endpoints as settings.address/port and tags them socks-<id>;
  # older layouts use settings.servers[0]. Support both.
  local socks_count socks_tags tags_json tag domain_count google_count telegram_count
  local domain_idx telegram_idx
  socks_count=$(jq --arg ip "$FOREIGN_TUNNEL_IP" --arg port "$SOCKS_PORT" '
    [.outbounds[]?
     | select(.protocol == "socks")
     | select((.settings.address // (.settings.servers // [])[0].address // "") == $ip)
     | select(((.settings.port // (.settings.servers // [])[0].port // "") | tostring) == $port)
    ] | length' "$cfg")
  socks_tags=$(jq -r --arg ip "$FOREIGN_TUNNEL_IP" --arg port "$SOCKS_PORT" '
    .outbounds[]?
    | select(.protocol == "socks")
    | select((.settings.address // (.settings.servers // [])[0].address // "") == $ip)
    | select(((.settings.port // (.settings.servers // [])[0].port // "") | tostring) == $port)
    | .tag // empty' "$cfg")
  tags_json=$(printf '%s\n' "$socks_tags" | jq -R . | jq -s 'map(select(length > 0))')

  if (( socks_count >= 2 )); then
    ok "Hiddify has ${socks_count} SOCKS outbound(s) to ${FOREIGN_TUNNEL_IP}:${SOCKS_PORT}"
  else
    bad "Hiddify has ${socks_count} SOCKS outbound(s) to ${FOREIGN_TUNNEL_IP}:${SOCKS_PORT} (expected 2)"
  fi

  while IFS= read -r tag; do
    [[ -n $tag ]] || continue
    if jq -e --arg t "$tag" '
        [.routing.rules[]?
         | select(.outboundTag == $t)
         | select((((.domain // []) | length) > 0) or (((.ip // []) | length) > 0))
        ] | length > 0' "$cfg" >/dev/null 2>&1; then
      ok "Hiddify routing rule for outbound ${tag}"
    else
      bad "Hiddify has no routing rule for outbound ${tag}"
    fi
  done <<< "$socks_tags"

  domain_count=$(jq --argjson tags "$tags_json" '
    [.routing.rules[]?
     | select(.outboundTag as $t | ($tags | index($t // "")) != null)
     | select(((.domain // []) | length) > 0)
    ] | length' "$cfg")
  if (( domain_count > 0 )); then
    ok "Hiddify routes domain/geosite lists to a SOCKS outbound"
  else
    bad "Hiddify has no domain/geosite rule pointing to a SOCKS outbound"
  fi

  # Google coverage guards Gemini/YouTube: accept the forms Hiddify emits for a
  # bare site entry plus the geosite tag.
  google_count=$(jq --argjson tags "$tags_json" '
    [.routing.rules[]?
     | select(.outboundTag as $t | ($tags | index($t // "")) != null)
     | (.domain // [])[]
     | select(. == "google.com" or . == "domain:google.com" or . == "full:google.com"
              or . == "geosite:google")] | length' "$cfg")
  if (( google_count > 0 )); then
    ok "Hiddify routes google.com/geosite:google to a SOCKS outbound"
  else
    bad "Hiddify routes no google.com/geosite:google rule to a SOCKS outbound"
  fi

  telegram_count=$(jq --argjson tags "$tags_json" '
    [.routing.rules[]?
     | select(.outboundTag as $t | ($tags | index($t // "")) != null)
     | select(((.ip // []) | index("geoip:telegram")) != null)
    ] | length' "$cfg")
  if (( telegram_count > 0 )); then
    ok "Hiddify routes geoip:telegram to a SOCKS outbound"
  else
    bad "Hiddify has no geoip:telegram rule pointing to a SOCKS outbound"
  fi

  domain_idx=$(jq --argjson tags "$tags_json" '
    [.routing.rules | to_entries[]?
     | select(.value.outboundTag as $t | ($tags | index($t // "")) != null)
     | select(((.value.domain // []) | length) > 0)
     | .key] | min // -1' "$cfg")
  telegram_idx=$(jq '
    [.routing.rules | to_entries[]?
     | select(((.value.ip // []) | index("geoip:telegram")) != null)
     | .key] | min // -1' "$cfg")
  if [[ $domain_idx != -1 && $telegram_idx != -1 ]] && (( domain_idx < telegram_idx )); then
    ok "Hiddify rule order: domain lists are matched before geoip:telegram"
  else
    bad "Hiddify rule order is wrong: domain lists must be matched before geoip:telegram"
  fi

  if jq -e '
      [.routing.rules[]? | ((.domain // [])[]), ((.ip // [])[])
       | select(. == "geoip:google")] | length > 0' "$cfg" >/dev/null 2>&1; then
    bad "Hiddify routing contains geoip:google (forbidden)"
  else
    ok "Hiddify routing does not use geoip:google"
  fi

  if jq -e '
      [.inbounds[]?
       | select(.protocol == "vless"
                and (.sniffing.enabled // false)
                and ((.sniffing.routeOnly // false) == false))
      ] | length > 0' "$cfg" >/dev/null 2>&1; then
    ok "Hiddify VLESS inbound sniffs SNI (routeOnly=false)"
  else
    bad "Hiddify VLESS inbounds do not sniff SNI with routeOnly=false"
  fi
}

# Signed-out probe through FOREIGN: checks the exit IP, not Google account eligibility.
check_gemini() {
  local country code tmp
  country=$(curl -4 -fsS --max-time 15 --socks5-hostname "${FOREIGN_TUNNEL_IP}:${SOCKS_PORT}" \
    https://ipinfo.io/country 2>/dev/null | tr -d '[:space:]' || true)
  case "$country" in
    "") warn "Gemini: could not determine FOREIGN exit country (ipinfo.io)" ;;
    RU) bad "Gemini: FOREIGN egress geolocates to Russia" ;;
    *)  ok "Gemini: FOREIGN exit country is ${country}" ;;
  esac

  tmp=$(mktemp)
  code=$(curl -4 -sS -L --compressed --max-time 25 \
    -H 'Accept-Language: ru-RU,ru;q=0.9,en;q=0.8' \
    --socks5-hostname "${FOREIGN_TUNNEL_IP}:${SOCKS_PORT}" \
    -o "$tmp" -w '%{http_code}' \
    'https://gemini.google.com/?hl=ru' 2>/dev/null || true)
  if grep -aEqi 'not available in your country|not available in your region|недоступен в вашей стране|не поддерживается в вашей стране' "$tmp"; then
    warn "Gemini shows a region-block page via FOREIGN (check exit IP/account country)"
  elif [[ $code == 2* || $code == 3* ]]; then
    ok "Gemini via FOREIGN returns ${code} (exit-level check, no region marker)"
  else
    warn "Gemini via FOREIGN returned ${code:-no response}; check manually"
  fi
  rm -f "$tmp"
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
  check_hiddify_routing

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

  check_gemini

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
