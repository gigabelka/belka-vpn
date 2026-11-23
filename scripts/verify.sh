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
  if [[ -r $BELKA_CONFIG_DIR/foreign-handoff.env ]]; then
    load_handoff "$BELKA_CONFIG_DIR/foreign-handoff.env"
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
  local socks_count socks_tags tags_json tag domain_count google_count google_full_count telegram_count
  local ai_count domain_idx telegram_idx
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

  # Google coverage guards Gemini/YouTube: accept the subdomain-matching forms
  # Hiddify emits for a bare site entry plus the geosite tag. An exact
  # full:google.com match does not cover gemini.google.com and friends.
  google_count=$(jq --argjson tags "$tags_json" '
    [.routing.rules[]?
     | select(.outboundTag as $t | ($tags | index($t // "")) != null)
     | (.domain // [])[]
     | select(. == "google.com" or . == "domain:google.com"
              or . == "geosite:google")] | length' "$cfg")
  google_full_count=$(jq --argjson tags "$tags_json" '
    [.routing.rules[]?
     | select(.outboundTag as $t | ($tags | index($t // "")) != null)
     | (.domain // [])[]
     | select(. == "full:google.com")] | length' "$cfg")
  if (( google_count > 0 )); then
    ok "Hiddify routes google.com/geosite:google to a SOCKS outbound"
  elif (( google_full_count > 0 )); then
    warn "Hiddify routes only full:google.com to SOCKS; subdomains (gemini.google.com) are not covered"
  else
    bad "Hiddify routes no google.com/geosite:google rule to a SOCKS outbound"
  fi

  # `.google` (brand TLD), ai.studio and *-unleash.goog are NOT covered by
  # google.com or geosite:google. They must be listed explicitly or come from
  # geosite:google-gemini; otherwise signed-in Gemini can egress Direct with a
  # RU address while the rest goes through FOREIGN (mixed IPs).
  ai_count=$(jq --argjson tags "$tags_json" '
    [.routing.rules[]?
     | select(.outboundTag as $t | ($tags | index($t // "")) != null)
     | (.domain // [])[]
     | select(. == "geosite:google-gemini" or . == "geosite:google-deepmind"
              or . == "ai.studio" or . == "domain:ai.studio" or . == "full:ai.studio"
              or . == "gemini.google" or . == "domain:gemini.google" or . == "full:gemini.google"
              or . == "generativeai.google" or . == "domain:generativeai.google"
              or . == "google.dev" or . == "domain:google.dev")] | length' "$cfg")
  if (( ai_count > 0 )); then
    ok "Hiddify routes Google AI (.google / ai.studio) hosts to a SOCKS outbound"
  else
    warn "Hiddify does not route Google AI hosts (ai.studio, gemini.google, generativeai.google); signed-in Gemini may leave via Direct"
  fi

  # Rutracker/Rutor/Instagram are listed explicitly (no geosite tag is assumed),
  # so a missing entry means that service leaves via Direct with a RU IP.
  blocked_count=$(jq --argjson tags "$tags_json" '
    [.routing.rules[]?
     | select(.outboundTag as $t | ($tags | index($t // "")) != null)
     | (.domain // [])[]
     | select(. == "instagram.com" or . == "domain:instagram.com"
              or . == "rutracker.org" or . == "domain:rutracker.org"
              or . == "rutor.info" or . == "domain:rutor.info")] | length' "$cfg")
  if (( blocked_count >= 3 )); then
    ok "Hiddify routes rutracker.org/rutor.info/instagram.com to a SOCKS outbound"
  elif (( blocked_count > 0 )); then
    warn "Hiddify routes only part of rutracker/rutor/instagram; paste the full /root/belka-foreign-domains.txt"
  else
    bad "Hiddify routes no rutracker/rutor/instagram domains to a SOCKS outbound"
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

  # geoip:google is allowed only in its own IP-only rule (FOREIGN-Google-IP)
  # below the domain rule; mixed with domains, IPOnDemand would resolve Google
  # domains through Russian DNS first.
  if jq -e '
      [.routing.rules[]?
       | select(((.domain // []) | length) > 0)
       | ((.domain // [])[]), ((.ip // [])[])
       | select(. == "geoip:google")] | length > 0' "$cfg" >/dev/null 2>&1; then
    bad "Hiddify has geoip:google in a rule with domains (must be its own FOREIGN-Google-IP outbound)"
  fi

  google_ip_idx=$(jq --argjson tags "$tags_json" '
    [.routing.rules | to_entries[]?
     | select(.value.outboundTag as $t | ($tags | index($t // "")) != null)
     | select(((.value.domain // []) | length) == 0)
     | select(((.value.ip // []) | index("geoip:google")) != null)
     | .key] | min // -1' "$cfg")
  if [[ $google_ip_idx == -1 ]]; then
    warn "Hiddify has no geoip:google rule to a SOCKS outbound (FOREIGN-Google-IP); Google connections without a domain leave via Direct"
  elif [[ $domain_idx != -1 ]] && (( domain_idx < google_ip_idx )); then
    ok "Hiddify routes geoip:google to a SOCKS outbound, after the domain lists"
  else
    bad "Hiddify rule order is wrong: domain lists must be matched before geoip:google"
  fi

  # Block with "Domestic sites" ON emits geoip:ru / domain:ru -> blackhole, so
  # Russian sites stop working instead of leaving via Direct.
  if jq -e '
      [.routing.rules[]?
       | select(.outboundTag == "blackhole")
       | ((.ip // [])[]), ((.domain // [])[])
       | select(. == "geoip:ru" or . == "domain:ru" or . == "geosite:category-ru")
      ] | length > 0' "$cfg" >/dev/null 2>&1; then
    bad "Hiddify blocks Russian sites (geoip:ru/domain:ru -> blackhole); turn off Domestic sites on the Block outbound"
  else
    ok "Hiddify does not blackhole Russian sites (Block: Domestic sites OFF)"
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
  local country code tmp ai_code ai_tmp
  country=$(curl -4 -fsS --max-time 15 --socks5-hostname "${FOREIGN_TUNNEL_IP}:${SOCKS_PORT}" \
    https://ipinfo.io/country 2>/dev/null | tr -d '[:space:]' || true)
  case "$country" in
    "") warn "Gemini: could not determine FOREIGN exit country (ipinfo.io)" ;;
    RU) bad "Gemini: FOREIGN egress geolocates to Russia" ;;
    *)  ok "Gemini: FOREIGN exit country is ${country}" ;;
  esac

  # Gemini enforces Google's own geo database, which can disagree with ipinfo.io.
  local gcountry
  gcountry=$(google_country --socks5-hostname "${FOREIGN_TUNNEL_IP}:${SOCKS_PORT}")
  case "$gcountry" in
    "") warn "Gemini: could not read Google's country for the FOREIGN exit (x-country)" ;;
    ru) warn "Gemini: Google geolocates the FOREIGN exit as RU; signed-in Gemini is blocked (see GOOGLE_IPV6_EGRESS in docs/troubleshooting.md)" ;;
    *)  ok "Gemini: Google sees the FOREIGN exit as ${gcountry}" ;;
  esac

  tmp=$(mktemp)
  code=$(curl -4 -sS -L --compressed --max-time 25 \
    -H 'Accept-Language: ru-RU,ru;q=0.9,en;q=0.8' \
    --socks5-hostname "${FOREIGN_TUNNEL_IP}:${SOCKS_PORT}" \
    -o "$tmp" -w '%{http_code}' \
    'https://gemini.google.com/?hl=ru' 2>/dev/null || true)
  if grep -aEqi 'not available in your country|not available in your region|недоступен в вашей стране|не поддерживается в вашей стране' "$tmp"; then
    warn "Gemini shows a region-block page via FOREIGN (check exit IP x-country and the Google account country)"
  elif [[ $code == 2* || $code == 3* ]]; then
    ok "Gemini via FOREIGN returns ${code} (exit-level check, no region marker)"
  else
    warn "Gemini via FOREIGN returned ${code:-no response}; check manually"
  fi
  rm -f "$tmp"

  # AI Studio is a second Gemini-family host; it exercises the same exit path
  # and a different hostname set (ai.studio, aistudio.google.com).
  ai_tmp=$(mktemp)
  ai_code=$(curl -4 -sS -L --compressed --max-time 25 \
    --socks5-hostname "${FOREIGN_TUNNEL_IP}:${SOCKS_PORT}" \
    -o "$ai_tmp" -w '%{http_code}' \
    'https://aistudio.google.com/' 2>/dev/null || true)
  if grep -aEqi 'not available in your country|not available in your region|недоступен в вашей стране|не поддерживается в вашей стране' "$ai_tmp"; then
    warn "AI Studio shows a region-block page via FOREIGN (check exit IP x-country and the Google account country)"
  elif [[ $ai_code == 2* || $ai_code == 3* ]]; then
    ok "AI Studio via FOREIGN returns ${ai_code}"
  else
    warn "AI Studio via FOREIGN returned ${ai_code:-no response}; check routing and exit IP"
  fi
  rm -f "$ai_tmp"
}

check_foreign() {
  check_awg
  if systemctl is-active -q xray; then
    ok "xray is active"
  else
    bad "xray is not active"
  fi
  if grep -Fq "${FOREIGN_TUNNEL_IP}:${SOCKS_PORT}" <<< "$(ss -lntp 2>/dev/null)"; then
    ok "SOCKS listens on ${FOREIGN_TUNNEL_IP}:${SOCKS_PORT}"
  else
    bad "SOCKS does not listen on ${FOREIGN_TUNNEL_IP}:${SOCKS_PORT}"
  fi
  if grep -Eq "0\.0\.0\.0:${SOCKS_PORT}|\[::\]:${SOCKS_PORT}" <<< "$(ss -lntu 2>/dev/null)"; then
    bad "SOCKS is exposed publicly on port ${SOCKS_PORT}"
  else
    ok "SOCKS is not exposed publicly"
  fi
  if grep -q "Status: active" <<< "$(ufw status 2>/dev/null)"; then
    ok "ufw is active"
  else
    warn "ufw is not active (check provider firewall)"
  fi
  if [[ $GOOGLE_IPV6_EGRESS == 1 ]]; then
    check_google_ipv6
  fi
}

check_google_ipv6() {
  if [[ -n $HE_SERVER_IPV4 ]]; then
    if systemctl is-active -q belka-he-ipv6; then
      ok "HE IPv6 tunnel (belka-he-ipv6) is active"
    else
      bad "HE IPv6 tunnel (belka-he-ipv6) is not active"
    fi
  fi
  if grep -q . <<< "$(ip -6 route show default 2>/dev/null)"; then
    ok "IPv6 default route present"
  else
    bad "no IPv6 default route: Google traffic (ForceIPv6) will fail"
    return
  fi
  local code country
  code=$(curl -6 -sS -o /dev/null -w '%{http_code}' --max-time 15 \
    https://www.google.com/generate_204 2>/dev/null || true)
  if [[ $code == 204 ]]; then
    ok "Google over IPv6 returns 204"
  else
    bad "Google over IPv6 returns ${code:-no response}"
  fi
  country=$(google_country -6)
  case "$country" in
    "") warn "could not read Google's country for the IPv6 egress" ;;
    ru) warn "Google geolocates the IPv6 egress as RU; Gemini stays blocked" ;;
    *)  ok "Google sees the IPv6 egress as ${country}" ;;
  esac
  if grep -q '"google-v6"' /usr/local/etc/xray/config.json 2>/dev/null; then
    ok "Xray routes Google via outbound google-v6"
  else
    bad "Xray config has no google-v6 outbound (rerun install-foreign.sh)"
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

  if grep -q . <<< "$(systemctl list-units --type=service --state=running 'hiddify*' --no-legend 2>/dev/null)"; then
    ok "Hiddify services are running"
  else
    bad "Hiddify services are not running"
  fi

  if grep -q ':443 ' <<< "$(ss -lntp 2>/dev/null)"; then
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
