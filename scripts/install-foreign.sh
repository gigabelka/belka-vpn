#!/usr/bin/env bash
# install-foreign.sh — foreign server: AmneziaWG peer + Xray SOCKS egress + firewall.
#
# Run from a checkout of the belka-vpn repository:
#   bash scripts/install-foreign.sh --env-file /etc/belka-vpn/foreign.env
#   bash scripts/install-foreign.sh --handoff /root/belka-ru-handoff.env
#
# First run creates keys, obfuscation parameters and the FOREIGN handoff file.
# The RU peer is added on a later run, after the RU public key is known.

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

ENV_FILE=${ENV_FILE:-/etc/belka-vpn/foreign.env}
HANDOFF_IN=""
RU_PUB_KEY_ARG=""
UNINSTALL=0
DRY_RUN=0
XRAY_CONFIG=/usr/local/etc/xray/config.json

usage() {
  cat <<'EOF'
Usage: install-foreign.sh [options]

Options:
  --env-file FILE   Server env file (default: /etc/belka-vpn/foreign.env)
  --handoff FILE    RU handoff with RU_PUBLIC_KEY (adds/updates the peer)
  --ru-pub KEY      RU public key (alternative to --handoff)
  --uninstall       Stop and remove FOREIGN components (keeps package and keys)
  --dry-run         Validate inputs and print the plan
  -h, --help        Show this help
EOF
}

parse_args() {
  while (( $# )); do
    case "$1" in
      --env-file) ENV_FILE=$2; shift 2 ;;
      --handoff) HANDOFF_IN=$2; shift 2 ;;
      --ru-pub) RU_PUB_KEY_ARG=$2; shift 2 ;;
      --uninstall) UNINSTALL=1; shift ;;
      --dry-run) DRY_RUN=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) echo "unknown argument: $1" >&2; usage >&2; exit 1 ;;
    esac
  done
}

preflight_foreign() {
  check_tunnel_conflict
  if [[ ! -f $AWG_DIR/awg0.conf ]] && port_udp_busy "$AWG_PORT"; then
    die "UDP/$AWG_PORT is already in use"
  fi
  if grep -q ":${SOCKS_PORT} " <<< "$(ss -lntp 2>/dev/null)"; then
    warn "TCP/$SOCKS_PORT is already listening (check for conflicts)"
  fi
}

write_foreign_handoff() {
  local f=/root/belka-foreign-handoff.env
  write_if_changed "$f" 600 <<EOF
# belka-vpn FOREIGN handoff — PUBLIC DATA ONLY
BELKA_ROLE=foreign
FOREIGN_PUBLIC_IP=${FOREIGN_PUBLIC_IP}
RU_PUBLIC_IP=${RU_PUBLIC_IP}
AWG_PORT=${AWG_PORT}
TUNNEL_NET=${TUNNEL_NET}
FOREIGN_TUNNEL_IP=${FOREIGN_TUNNEL_IP}
RU_TUNNEL_IP=${RU_TUNNEL_IP}
SOCKS_PORT=${SOCKS_PORT}
AWG_MTU=${AWG_MTU}
FOREIGN_PUBLIC_KEY=$(cat "$KEY_DIR/public.key")
AWG_JC=${AWG_JC}
AWG_JMIN=${AWG_JMIN}
AWG_JMAX=${AWG_JMAX}
AWG_S1=${AWG_S1}
AWG_S2=${AWG_S2}
AWG_S3=${AWG_S3:-0}
AWG_S4=${AWG_S4:-0}
AWG_H1=${AWG_H1}
AWG_H2=${AWG_H2}
AWG_H3=${AWG_H3}
AWG_H4=${AWG_H4}
EOF
  log INFO "FOREIGN handoff written: $f (0600)"
}

render_foreign_awg() {
  validate_tunnel_net
  export FOREIGN_TUNNEL_IP AWG_PORT AWG_MTU RU_TUNNEL_IP RU_PUBLIC_KEY
  export FOREIGN_PRIVATE_KEY OBF_LINES
  FOREIGN_PRIVATE_KEY=$(cat "$KEY_DIR/private.key")
  OBF_LINES=$(emit_obf)

  local tmp
  tmp=$(mktemp)
  envsubst < "$SCRIPT_DIR/../config/foreign/awg0.conf.tpl" > "$tmp"
  if [[ -n $RU_PUBLIC_KEY ]]; then
    envsubst < "$SCRIPT_DIR/../config/foreign/awg0-peer.tpl" >> "$tmp"
  fi
  write_if_changed "$AWG_DIR/awg0.conf" 600 < "$tmp"
  rm -f "$tmp"
  chmod 600 "$AWG_DIR/awg0.conf"
  if [[ -n $RU_PUBLIC_KEY ]]; then
    log INFO "rendered $AWG_DIR/awg0.conf (RU peer present)"
  else
    log INFO "rendered $AWG_DIR/awg0.conf (RU peer not set yet)"
  fi
}

start_awg() {
  systemctl enable awg-quick@awg0 >>"$LOG" 2>&1 || true
  if (( TEMPLATE_CHANGED )) || ! systemctl is-active -q awg-quick@awg0; then
    systemctl restart awg-quick@awg0 >>"$LOG" 2>&1 \
      || die "awg-quick@awg0 failed; check: journalctl -u awg-quick@awg0 -n 100"
    log INFO "awg-quick@awg0 restarted"
  else
    log INFO "awg-quick@awg0 unchanged and active"
  fi
  awg show >>"$LOG" 2>&1 || true
}

# ------------------------------------------------- IPv6 egress for Google ---
# Google's own geo database can place the FOREIGN IPv4 in Russia even when every
# third-party database says otherwise; Gemini then refuses signed-in users.
# GOOGLE_IPV6_EGRESS=1 sends Google domains out over IPv6 instead: the server's
# native IPv6, or a Hurricane Electric 6in4 tunnel when HE_SERVER_IPV4 and
# HE_CLIENT_IPV6 are set.

HE_UNIT=/etc/systemd/system/belka-he-ipv6.service

validate_google_ipv6() {
  [[ $GOOGLE_IPV6_EGRESS == 0 || $GOOGLE_IPV6_EGRESS == 1 ]] \
    || die "GOOGLE_IPV6_EGRESS must be 0 or 1"
  if [[ -n $HE_SERVER_IPV4 || -n $HE_CLIENT_IPV6 ]]; then
    handoff_valid_ipv4 "$HE_SERVER_IPV4" \
      || die "HE_SERVER_IPV4 must be the tunnel server IPv4 (tunnelbroker.net: Server IPv4 Address)"
    [[ $HE_CLIENT_IPV6 =~ ^[0-9A-Fa-f:]+/[0-9]{1,3}$ ]] \
      || die "HE_CLIENT_IPV6 must be an IPv6 address with prefix (tunnelbroker.net: Client IPv6 Address)"
  fi
}

foreign_egress_ipv4_is_local() {
  local local_ips
  local_ips=$(ip -4 -o addr show scope global 2>/dev/null \
    | awk '{print $4}' | cut -d/ -f1 || true)
  grep -Fxq "$FOREIGN_EGRESS_IPV4" <<< "$local_ips"
}

# Optional source address for the direct outbound. It must be a valid IPv4
# assigned to a local interface, otherwise Xray fails at bind time. A dry run
# only warns: the address may not be attached yet.
validate_foreign_egress_ipv4() {
  [[ -n ${FOREIGN_EGRESS_IPV4:-} ]] || return 0
  ipv4_to_int "$FOREIGN_EGRESS_IPV4" >/dev/null \
    || die "FOREIGN_EGRESS_IPV4 is not a valid IPv4 address: $FOREIGN_EGRESS_IPV4"
  [[ $FOREIGN_EGRESS_IPV4 != 0.0.0.0 ]] || die "FOREIGN_EGRESS_IPV4 must not be 0.0.0.0"
  case "$FOREIGN_EGRESS_IPV4" in
    "$FOREIGN_TUNNEL_IP"|"$RU_TUNNEL_IP")
      die "FOREIGN_EGRESS_IPV4 must not be a tunnel IP: $FOREIGN_EGRESS_IPV4" ;;
  esac
  if (( DRY_RUN )); then
    foreign_egress_ipv4_is_local \
      || warn "dry-run: FOREIGN_EGRESS_IPV4=$FOREIGN_EGRESS_IPV4 is not assigned to a local interface yet"
    return 0
  fi
  foreign_egress_ipv4_is_local \
    || die "FOREIGN_EGRESS_IPV4=$FOREIGN_EGRESS_IPV4 is not assigned to a local interface (ip -4 -o addr show)"
}

he_tunnel_wanted() { [[ $GOOGLE_IPV6_EGRESS == 1 && -n $HE_SERVER_IPV4 ]]; }

remove_he_tunnel() {
  [[ -e $HE_UNIT ]] || return 0
  systemctl disable --now belka-he-ipv6 >>"$LOG" 2>&1 || true
  rm -f "$HE_UNIT"
  systemctl daemon-reload
  log INFO "HE IPv6 tunnel removed"
}

setup_google_ipv6() {
  if [[ $GOOGLE_IPV6_EGRESS != 1 ]]; then
    remove_he_tunnel
    return 0
  fi

  if he_tunnel_wanted; then
    export FOREIGN_PUBLIC_IP HE_SERVER_IPV4 HE_CLIENT_IPV6
    render_template "$SCRIPT_DIR/../config/foreign/he-ipv6.service.tpl" "$HE_UNIT" 644
    systemctl daemon-reload
    systemctl enable belka-he-ipv6 >>"$LOG" 2>&1 || true
    if (( TEMPLATE_CHANGED )) || ! systemctl is-active -q belka-he-ipv6; then
      systemctl restart belka-he-ipv6 >>"$LOG" 2>&1 \
        || die "belka-he-ipv6 failed; check: journalctl -u belka-he-ipv6 -n 50"
      log INFO "HE IPv6 tunnel (re)started"
    else
      log INFO "HE IPv6 tunnel unchanged and active"
    fi
  else
    remove_he_tunnel
  fi

  if ! grep -q . <<< "$(ip -6 route show default 2>/dev/null)"; then
    die "GOOGLE_IPV6_EGRESS=1 but there is no IPv6 default route (set HE_SERVER_IPV4/HE_CLIENT_IPV6 or get native IPv6 from the provider)"
  fi

  # Xray will force IPv6 for Google, so refuse to switch it over a dead path.
  local code="" i
  for i in 1 2 3; do
    code=$(curl -6 -sS -o /dev/null -w '%{http_code}' --max-time 15 \
      https://www.google.com/generate_204 2>/dev/null || true)
    [[ $code == 204 ]] && break
    sleep 3
  done
  [[ $code == 204 ]] \
    || die "IPv6 egress to Google failed (generate_204 returned ${code:-no response}); Xray config left unchanged"

  local country
  country=$(google_country -6)
  case "$country" in
    ru) warn "Google still geolocates the IPv6 egress as RU; Gemini will stay blocked" ;;
    "") warn "IPv6 egress works, but Google's country could not be read" ;;
    *) log INFO "IPv6 egress to Google works; Google sees country: $country" ;;
  esac
}

# Fragments spliced into xray-socks.json.tpl; empty unless GOOGLE_IPV6_EGRESS=1,
# so the default render is byte-identical to the plain template.
xray_google_v6_fragments() {
  XRAY_EXTRA_OUTBOUNDS=""
  XRAY_EXTRA_RULES=""
  [[ $GOOGLE_IPV6_EGRESS == 1 ]] || return 0
  XRAY_EXTRA_OUTBOUNDS=$(cat <<'EOF'
,
    {
      "tag": "google-v6",
      "protocol": "freedom",
      "settings": {
        "domainStrategy": "ForceIPv6"
      }
    }
EOF
)
  # YouTube stays on IPv4: video would saturate a tunnel, and the region block
  # this works around is enforced by Gemini, not YouTube.
  # Google AI hosts in .google/.goog/.studio (and Google's ad/analytics hosts)
  # are named explicitly: google.com does not cover them, and stale geosite data
  # would otherwise leave them on IPv4 while the rest of Google uses IPv6.
  # Keep in sync with the Google AI block in config/rules/foreign-domains.txt.
  XRAY_EXTRA_RULES=$(cat <<'EOF'
,
      {
        "type": "field",
        "domain": ["geosite:youtube"],
        "outboundTag": "direct"
      },
      {
        "type": "field",
        "domain": [
          "geosite:google",
          "geosite:google-gemini",
          "google.dev",
          "ai.studio",
          "generativeai.google",
          "gemini.google",
          "notebook.google",
          "notebooklm.google",
          "jules.google",
          "flow.google",
          "opal.google",
          "antigravity.google",
          "antigravity-unleash.goog",
          "withgoogle.com",
          "googletagmanager.com",
          "google-analytics.com",
          "doubleclick.net"
        ],
        "outboundTag": "google-v6"
      }
EOF
)
}

install_xray() {
  if [[ ! -x /usr/local/bin/xray ]]; then
    local installer=/root/.cache/belka/xray-install.sh
    download_file https://github.com/XTLS/Xray-install/raw/main/install-release.sh "$installer"
    bash "$installer" install >>"$LOG" 2>&1 || die "Xray install failed"
  fi
  [[ -x /usr/local/bin/xray ]] || die "xray binary not found"
  systemctl cat xray >/dev/null 2>&1 || die "xray.service not found after install"
  install -d -m 755 /usr/local/etc/xray /etc/systemd/system/xray.service.d
}

xray_config_backup() {
  printf '%s\n' "$BELKA_CONFIG_DIR/xray-config.prev"
}

# Preserve the working config before changes to either awg0 or Xray.
backup_xray_config() {
  [[ -r $XRAY_CONFIG ]] && systemctl is-active -q xray || return 0
  local endpoint host port
  endpoint=$(xray_socks_endpoint "$XRAY_CONFIG") || return 0
  read -r host port <<< "$endpoint"
  xray_socks_ready "$host" "$port" || return 0
  install -d -m 700 "$BELKA_CONFIG_DIR"
  write_if_changed "$(xray_config_backup)" 600 < "$XRAY_CONFIG"
}

xray_socks_endpoint() {
  jq -er '.inbounds[]? | select(.tag == "socks-foreign" and .protocol == "socks")
    | select((.listen | type) == "string" and (.port | type) == "number")
    | [.listen, .port] | @tsv' "$1" 2>/dev/null
}

# Test the no-auth SOCKS5 handshake locally so a third-party outage cannot
# trigger a rollback of a working Xray listener.
xray_socks_ready() {
  timeout 2 bash -c '
    exec 3<>"/dev/tcp/$1/$2" || exit 1
    printf "\x05\x01\x00" >&3
    [[ $(od -An -tx1 -N2 <&3) == " 05 00" ]]
  ' bash "$1" "$2" 2>/dev/null
}

restart_xray_ready() {
  local host=$1 port=$2 attempt
  systemctl restart xray >>"$LOG" 2>&1 || return 1
  for attempt in 1 2 3 4 5; do
    if systemctl is-active -q xray && xray_socks_ready "$host" "$port"; then
      return 0
    fi
    [[ $attempt == 5 ]] || sleep 1
  done
  return 1
}

render_xray() {
  xray_google_v6_fragments
  XRAY_DIRECT_SEND_THROUGH=""
  if [[ -n ${FOREIGN_EGRESS_IPV4:-} ]]; then
    printf -v XRAY_DIRECT_SEND_THROUGH '\n      "sendThrough": "%s",' "$FOREIGN_EGRESS_IPV4"
  fi
  export FOREIGN_TUNNEL_IP SOCKS_PORT XRAY_EXTRA_OUTBOUNDS XRAY_EXTRA_RULES \
    XRAY_DIRECT_SEND_THROUGH
  write_if_changed /etc/systemd/system/xray.service.d/10-awg.conf 644 <<'EOF'
[Unit]
After=awg-quick@awg0.service
Requires=awg-quick@awg0.service
EOF
  local unit_changed=$TEMPLATE_CHANGED
  systemctl daemon-reload

  render_template_validated "$SCRIPT_DIR/../config/foreign/xray-socks.json.tpl" \
    "$XRAY_CONFIG" 644 /usr/local/bin/xray run -test -config
  TEMPLATE_CHANGED=$(( TEMPLATE_CHANGED || unit_changed ))
  log INFO "rendered $XRAY_CONFIG"
}

start_xray() {
  local backup endpoint host port
  if (( ! TEMPLATE_CHANGED )) && systemctl is-active -q xray \
      && xray_socks_ready "$FOREIGN_TUNNEL_IP" "$SOCKS_PORT"; then
    log INFO "xray unchanged and SOCKS is ready"
  elif restart_xray_ready "$FOREIGN_TUNNEL_IP" "$SOCKS_PORT"; then
    log INFO "xray restarted and SOCKS is ready"
  else
    backup=$(xray_config_backup)
    if [[ -r $backup ]] && ! cmp -s "$backup" "$XRAY_CONFIG" \
        && endpoint=$(xray_socks_endpoint "$backup"); then
      read -r host port <<< "$endpoint"
      warn "xray SOCKS did not become ready; restoring $backup"
      write_if_changed "$XRAY_CONFIG" 644 < "$backup"
      if restart_xray_ready "$host" "$port"; then
        die "xray SOCKS failed with the new config; previous config restored and SOCKS is ready"
      fi
      die "previous Xray config restored but SOCKS is still unavailable; check: journalctl -u xray -n 100"
    fi
    die "xray SOCKS did not become ready; check: journalctl -u xray -n 100"
  fi
  systemctl enable xray >>"$LOG" 2>&1 || die "could not enable xray at boot"
}

setup_firewall_foreign() {
  if [[ ${ENABLE_UFW:-1} != 1 ]]; then
    log INFO "UFW disabled by env"
    return 0
  fi
  local added rule status action
  local -a args
  added=$(LC_ALL=C ufw show added) || die "could not read configured UFW rules"
  while IFS= read -r rule; do
    ufw_rule_present "$added" "$rule" && continue
    read -r -a args <<< "$rule"
    for action in allow deny reject limit; do
      [[ $action == "${args[0]}" ]] && continue
      if ufw_rule_present "$added" "$action ${rule#* }"; then
        die "existing UFW rule conflicts with $rule; review ufw show added"
      fi
    done
    if [[ ${args[0]} == allow ]]; then
      args+=(comment "$UFW_TUNNEL_COMMENT")
    fi
    ufw_rule "${args[@]}"
  done < <(foreign_ufw_rules)
  status=$(LC_ALL=C ufw status verbose) || die "could not read UFW status"
  if ! grep -Fq 'Default: deny (incoming)' <<< "$status"; then
    ufw --force default deny incoming >>"$LOG" 2>&1
  fi
  if ! grep -Fq 'allow (outgoing)' <<< "$status"; then
    ufw --force default allow outgoing >>"$LOG" 2>&1
  fi
  if ! grep -Fxq 'Status: active' <<< "$status"; then
    ufw --force enable >>"$LOG" 2>&1
  fi
  ufw status verbose >>"$LOG" 2>&1 || true
  log INFO "UFW enabled: SSH, UDP/$AWG_PORT from $RU_PUBLIC_IP, SOCKS only on awg0"
}

# Only delete commands marked as Belka-owned. Existing unmarked rules may
# belong to the administrator. SSH rules are deliberately outside this cleanup.
prune_foreign_ufw_rules() {
  [[ $ENABLE_UFW == 1 ]] || return 0
  local desired=$1 added rule
  local -a args
  added=$(LC_ALL=C ufw show added) || die "could not read configured UFW rules"
  while IFS= read -r rule; do
    grep -Fxq "$rule" <<< "$desired" && continue
    read -r -a args <<< "$rule"
    ufw --force delete "${args[@]}" >>"$LOG" 2>&1 \
      || die "could not remove obsolete Belka UFW rule: $rule"
    log INFO "ufw: removed obsolete Belka rule: $rule"
  done < <(foreign_ufw_managed_rules <<< "$added")
}

summary_foreign() {
  log INFO "FOREIGN setup complete"
  local ru_peer=absent
  [[ -n $RU_PUBLIC_KEY ]] && ru_peer=present
  cat >&3 <<EOF
FOREIGN readiness
  awg0:        ${FOREIGN_TUNNEL_IP}/${TUNNEL_PREFIX}, UDP/${AWG_PORT} (RU peer: ${ru_peer})
  xray socks:  ${FOREIGN_TUNNEL_IP}:${SOCKS_PORT} (tunnel only)
  google ipv6: $( [[ $GOOGLE_IPV6_EGRESS == 1 ]] && echo "on${HE_SERVER_IPV4:+ (HE tunnel)}" || echo off )
  xray egress: ${FOREIGN_EGRESS_IPV4:-system default}
  handoff:     /root/belka-foreign-handoff.env

EOF
  if [[ -z $RU_PUBLIC_KEY ]]; then
    cat >&3 <<EOF
Next steps
  1) On RU: bash scripts/install-ru.sh --keys-only --env-file /etc/belka-vpn/ru.env
  2) Copy /root/belka-ru-handoff.env from RU to FOREIGN and run:
     bash scripts/install-foreign.sh --handoff /root/belka-ru-handoff.env
  3) Copy this FOREIGN handoff to RU (public data only) and run there:
     bash scripts/install-ru.sh --handoff /root/belka-foreign-handoff.env
EOF
  else
    cat >&3 <<EOF
Next steps
  1) Copy this FOREIGN handoff to RU (public data only):
     scp -i <key> root@${FOREIGN_PUBLIC_IP}:/root/belka-foreign-handoff.env /tmp/belka-foreign-handoff.env
     scp -i <key> /tmp/belka-foreign-handoff.env root@${RU_PUBLIC_IP}:/root/belka-foreign-handoff.env
  2) On RU: bash scripts/install-ru.sh --handoff /root/belka-foreign-handoff.env
EOF
  fi
}

uninstall_foreign() {
  log INFO "uninstalling FOREIGN components (packages and keys are kept)"
  systemctl disable --now xray 2>/dev/null || true
  rm -f /etc/systemd/system/xray.service.d/10-awg.conf
  remove_he_tunnel
  systemctl daemon-reload || true
  systemctl disable --now awg-quick@awg0 2>/dev/null || true
  rm -f "$AWG_DIR/awg0.conf"
  prune_foreign_ufw_rules ""
  log INFO "FOREIGN components stopped/removed"
}

main() {
  parse_args "$@"
  if (( UNINSTALL && DRY_RUN )); then
    printf 'error: --uninstall and --dry-run are mutually exclusive\n' >&2
    exit 2
  fi
  belka_init foreign
  need_root
  check_os
  load_env_file "$ENV_FILE" || warn "env file not found: $ENV_FILE"
  apply_defaults

  : "${FOREIGN_PUBLIC_IP:?FOREIGN_PUBLIC_IP is required (set it in $ENV_FILE)}"
  : "${RU_PUBLIC_IP:?RU_PUBLIC_IP is required (set it in $ENV_FILE)}"

  if (( UNINSTALL )); then
    uninstall_foreign
    exit 0
  fi

  local stored_handoff=$BELKA_CONFIG_DIR/ru-handoff.env
  # RU public key: explicit argument > handoff file > stored handoff.
  if [[ -n $HANDOFF_IN ]]; then
    load_handoff "$HANDOFF_IN" ru
  elif [[ -r $stored_handoff ]]; then
    load_handoff "$stored_handoff" ru
  fi
  if [[ -n $RU_PUB_KEY_ARG ]]; then
    handoff_valid_wg_key "$RU_PUB_KEY_ARG" \
      || die "--ru-pub is not a valid WireGuard public key"
    RU_PUBLIC_KEY=$RU_PUB_KEY_ARG
  fi
  export RU_PUBLIC_KEY="${RU_PUBLIC_KEY:-}"
  validate_tunnel_net
  handoff_valid_ipv4 "$FOREIGN_PUBLIC_IP" || die "invalid FOREIGN_PUBLIC_IP"
  handoff_valid_ipv4 "$RU_PUBLIC_IP" || die "invalid RU_PUBLIC_IP"
  local port_var
  for port_var in AWG_PORT SOCKS_PORT SSH_PORT; do
    handoff_valid_port "${!port_var}" || die "invalid $port_var"
  done
  handoff_valid_mtu "$AWG_MTU" || die "invalid AWG_MTU"
  validate_google_ipv6
  validate_foreign_egress_ipv4

  if (( DRY_RUN )); then
    log INFO "dry-run: would install AmneziaWG + Xray, write $AWG_DIR/awg0.conf,"
    if [[ $ENABLE_UFW == 1 ]]; then
      log INFO "dry-run: configure UFW for UDP/$AWG_PORT from $RU_PUBLIC_IP and TCP+UDP/$SOCKS_PORT on awg0"
    fi
    if he_tunnel_wanted; then
      log INFO "dry-run: would bring up HE 6in4 tunnel to $HE_SERVER_IPV4 ($HE_CLIENT_IPV6)"
    fi
    if [[ $GOOGLE_IPV6_EGRESS == 1 ]]; then
      log INFO "dry-run: would route geosite:google over IPv6 (outbound google-v6, ForceIPv6)"
    fi
    if [[ -n ${FOREIGN_EGRESS_IPV4:-} ]]; then
      log INFO "dry-run: would set sendThrough ${FOREIGN_EGRESS_IPV4} on the direct outbound"
    fi
    exit 0
  fi

  install_base_packages
  preflight_foreign
  install_amneziawg
  gen_keypair
  load_or_gen_obfuscation

  backup_xray_config
  setup_firewall_foreign
  render_foreign_awg
  start_awg
  setup_google_ipv6
  install_xray
  render_xray
  start_xray
  prune_foreign_ufw_rules "$(foreign_ufw_rules)"
  if [[ -n $HANDOFF_IN && ! $HANDOFF_IN -ef $stored_handoff ]]; then
    install -d -m 700 "$BELKA_CONFIG_DIR"
    write_if_changed "$stored_handoff" 600 < "$HANDOFF_IN"
  fi
  write_foreign_handoff
  setup_fail2ban
  harden_ssh
  summary_foreign
}

main "$@"
