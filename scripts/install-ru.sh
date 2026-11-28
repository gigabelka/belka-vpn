#!/usr/bin/env bash
# install-ru.sh — Russia server: AmneziaWG client + Hiddify Manager install.
#
# Typical sequence (after the first FOREIGN run created its handoff):
#   1) bash scripts/install-ru.sh --keys-only --env-file /etc/belka-vpn/ru.env
#   2) on FOREIGN: bash scripts/install-foreign.sh --handoff /root/belka-ru-handoff.env
#   3) bash scripts/install-ru.sh --handoff /root/belka-foreign-handoff.env
#
# Hiddify Manager UI steps (Reality, Outbounds, sniffing) remain manual and are
# printed from /root/belka-ru-manual-checklist.txt.

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

ENV_FILE=${ENV_FILE:-/etc/belka-vpn/ru.env}
HANDOFF_IN=""
KEYS_ONLY=0
UNINSTALL=0
DRY_RUN=0
HIDDIFY_CORE_COMPAT_CHANGED=0

usage() {
  cat <<'EOF'
Usage: install-ru.sh [options]

Options:
  --env-file FILE   Server env file (default: /etc/belka-vpn/ru.env)
  --keys-only       Install AmneziaWG, generate RU keys, write RU handoff
  --handoff FILE    FOREIGN handoff with FOREIGN_PUBLIC_KEY and obfuscation parameters
  --uninstall       Stop and remove RU tunnel components (Hiddify is kept)
  --dry-run         Validate inputs and print the plan
  -h, --help        Show this help
EOF
}

parse_args() {
  while (( $# )); do
    case "$1" in
      --env-file) ENV_FILE=$2; shift 2 ;;
      --keys-only) KEYS_ONLY=1; shift ;;
      --handoff) HANDOFF_IN=$2; shift 2 ;;
      --uninstall) UNINSTALL=1; shift ;;
      --dry-run) DRY_RUN=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) echo "unknown argument: $1" >&2; usage >&2; exit 1 ;;
    esac
  done
}

preflight_ru() {
  check_tunnel_conflict
  # RU is the AmneziaWG client (no ListenPort): AWG_PORT is only the remote
  # endpoint, so a local UDP/$AWG_PORT listener is not a conflict.
  if [[ ${INSTALL_HIDDIFY:-1} == 1 && ! -d /opt/hiddify-manager ]]; then
    if grep -qE ':(80|443) ' <<< "$(ss -lntp 2>/dev/null)"; then
      die "ports 80/443 are in use; Hiddify Manager needs them (stop the service or set INSTALL_HIDDIFY=0)"
    fi
  fi
}

hiddify_core_compat_dropin() {
  local dst=/etc/systemd/system/hiddify-core.service.d/belka-compat.conf
  install -d -m 755 "$(dirname "$dst")"
  write_if_changed "$dst" 644 <<'EOF'
# belka-vpn: Hiddify Manager's generated config uses remote rule-sets with an
# implicit default HTTP client; newer sing-box cores abort on it unless this
# deprecated behaviour is allowed. Revisit when Hiddify emits the new form.
[Service]
Environment=ENABLE_DEPRECATED_IMPLICIT_DEFAULT_HTTP_CLIENT=true
EOF
  if (( TEMPLATE_CHANGED )); then
    HIDDIFY_CORE_COMPAT_CHANGED=1
  fi
}

# Hiddify Manager re-enables IP forwarding on every install (its installer runs
# at each boot): /etc/sysctl.d/hiddify.conf and, after its WireGuard was ever
# enabled, wg.conf. The split tunnel uses SOCKS, so RU never forwards packets.
# sysctl.d applies files in lexical order and the last value wins, so the
# override must sort after hiddify.conf and wg.conf.
configure_ip_forwarding() {
  local conf=/etc/sysctl.d/zz-belka-no-forward.conf
  if [[ ${RU_IP_FORWARD:-0} == 1 ]]; then
    if [[ -e $conf ]]; then
      rm -f "$conf"
      sysctl --system >>"$LOG" 2>&1 || warn "sysctl --system reported errors"
      log INFO "IP forwarding override removed (RU_IP_FORWARD=1)"
    fi
    return 0
  fi
  write_if_changed "$conf" 644 <<'EOF'
# belka-vpn: RU needs no IP forwarding (FOREIGN is reached over SOCKS).
# Hiddify's WireGuard and WARP do need it: set RU_IP_FORWARD=1 in ru.env and
# rerun install-ru.sh, or delete this file and run `sysctl --system`.
net.ipv4.ip_forward = 0
net.ipv6.conf.all.forwarding = 0
# Turning forwarding off makes the kernel re-enable ICMP redirects (it sets
# accept_redirects to the inverse of forwarding), and RU has no UFW to turn
# them off again. These lines must stay after the forwarding ones. Globs, not
# just all/default: with forwarding off IPv4 accepts a redirect when either
# all or the interface allows it, and IPv6 ignores all for existing
# interfaces. default covers interfaces created later (awg0 at boot).
net.ipv4.conf.*.accept_redirects = 0
net.ipv4.conf.*.secure_redirects = 0
net.ipv6.conf.*.accept_redirects = 0
EOF
  if (( TEMPLATE_CHANGED )) || [[ $(sysctl -n net.ipv4.ip_forward) != 0 ]]; then
    sysctl --system >>"$LOG" 2>&1 || warn "sysctl --system reported errors"
  fi
  if [[ $(sysctl -n net.ipv4.ip_forward) != 0 ]]; then
    warn "IP forwarding is still on; another sysctl file sorts after $conf"
  else
    log INFO "IP forwarding disabled"
  fi
  local f redirects_on=()
  for f in /proc/sys/net/ipv4/conf/*/accept_redirects /proc/sys/net/ipv6/conf/*/accept_redirects; do
    [[ -r $f && $(<"$f") != 0 ]] && redirects_on+=("${f#/proc/sys/net/}")
  done
  if (( ${#redirects_on[@]} )); then
    warn "ICMP redirects still accepted: ${redirects_on[*]}"
  fi
}

activate_hiddify_core_compat() {
  [[ -d /opt/hiddify-manager ]] || return 0
  systemctl daemon-reload >>"$LOG" 2>&1 || true
  if (( HIDDIFY_CORE_COMPAT_CHANGED )) || ! systemctl is-active -q hiddify-core; then
    systemctl restart hiddify-core >>"$LOG" 2>&1 \
      || warn "hiddify-core restart failed; see journalctl -u hiddify-core and /opt/hiddify-manager/data/log/hiddify-core.err.log"
    log INFO "hiddify-core restarted"
  else
    log INFO "hiddify-core compatibility drop-in unchanged and service active"
  fi
}

install_hiddify() {
  if [[ ${INSTALL_HIDDIFY:-1} != 1 ]]; then
    log INFO "Hiddify Manager install disabled by env"
    return 0
  fi
  # Write the drop-in before the installer so its health check sees a working
  # hiddify-core: newer sing-box cores abort on Hiddify's deprecated implicit
  # default HTTP client for remote rule-sets.
  hiddify_core_compat_dropin
  if [[ -d /opt/hiddify-manager ]]; then
    log INFO "Hiddify Manager already installed"
    activate_hiddify_core_compat
    return 0
  fi

  log INFO "installing Hiddify Manager (may take 5-10 minutes)"
  local installer=/root/.cache/belka/hiddify-install.sh
  local out=/root/belka-hiddify-install.out
  download_file "$HIDDIFY_INSTALL_URL" "$installer"
  ( umask 077; : > "$out" )

  # Installer output may contain the admin link, which is a secret.
  # Keep it out of the main log and the chat output.
  # The Hiddify installer expects the default 022 umask: under lib.sh's 077
  # it creates /opt/hiddify-manager as 0700 root and the service users cannot
  # traverse it. Run it in a subshell with a normal umask and a TERM.
  local rc=0
  ( umask 022; TERM=xterm DEBIAN_FRONTEND=noninteractive \
      bash "$installer" </dev/null >"$out" 2>&1 ) || rc=$?
  if (( rc != 0 )); then
    # The installer can exit non-zero for non-fatal reasons: WARP (usque)
    # registration is often unreachable from Russia, and the sing-box core it
    # pulls aborts on Hiddify's implicit default HTTP client for remote
    # rule-sets until the drop-in above is loaded. Treat it as success only
    # when the panel really is installed; WARP stays off in this deployment.
    if [[ -f /opt/hiddify-manager/data/hiddify-panel/app.cfg ]] \
      && systemctl is-enabled -q hiddify-panel 2>/dev/null; then
      warn "Hiddify installer exited $rc but the panel is installed (likely WARP registration); continuing"
    else
      log ERROR "Hiddify installer failed; see $out"
      tail -n 20 "$out" | sed -E 's/[A-Za-z0-9_-]{24,}/<redacted>/g' >&3 || true
      die "Hiddify install failed"
    fi
  fi
  [[ -d /opt/hiddify-manager ]] || die "Hiddify install finished but /opt/hiddify-manager is missing"
  # Re-assert in case the installer replaced the unit directory, then load the
  # compatibility environment.
  hiddify_core_compat_dropin
  activate_hiddify_core_compat
  log INFO "Hiddify Manager installed; admin link: run 'hiddify admin' on the server"
  log INFO "installer output saved to $out (0600, contains the admin link)"
}

# Hiddify 14.2 generates the REALITY-termination inbounds without "sniffing"
# (xray/server/presets/reality_termination.j2), so a connection whose destination
# arrives as a bare IP cannot match FOREIGN-Domains and leaves via Direct. The
# panel exposes a built-in-proxy server-config override; store the sniffing block
# there (it survives catalog sync and Hiddify upgrades) and regenerate configs.
apply_hiddify_reality_sniffing() {
  [[ -d /opt/hiddify-manager ]] || return 0
  [[ ${INSTALL_HIDDIFY:-1} == 1 ]] || { log INFO "Hiddify sniffing override skipped (Hiddify install disabled)"; return 0; }
  local py out
  py=$(compgen -G '/opt/hiddify-manager/.venv*/bin/python' | head -n1 || true)
  if [[ -z $py || ! -x $py ]]; then
    warn "hiddifypanel venv not found; cannot apply the REALITY-termination sniffing override"
    return 0
  fi
  out=$( cd /opt/hiddify-manager && "$py" - <<'PY' 2>&1
import os
import sys

os.chdir('/opt/hiddify-manager')
from hiddifypanel.base import create_app

app = create_app()
with app.app_context():
    from hiddifypanel.models.custom_proxy import CustomProxy
    from hiddifypanel.proxy_v3.api.custom_proxy_api import _prepare_create_data

    rows = CustomProxy.query.filter_by(slug='xray-reality-termination').all()
    if not rows:
        print('BELKA_SNIFF_MISSING')
        sys.exit(0)
    for row in rows:
        data = row.to_dict()
        cfg = dict(data.get('server_config') or {})
        tmpl = cfg.get('inbound_template') or ''
        if '"sniffing"' in tmpl:
            print('BELKA_SNIFF_PRESENT', row.id, row.child_id)
            continue
        needle = '"protocol": "vless",'
        if tmpl.count(needle) != 1:
            print('BELKA_SNIFF_UNEXPECTED', row.id, tmpl.count(needle))
            continue
        sniff = ('"sniffing": {\n'
                 '                "enabled": true,\n'
                 '                "destOverride": ["http", "tls", "quic"],\n'
                 '                "routeOnly": false\n'
                 '            },')
        cfg['inbound_template'] = tmpl.replace(needle, needle + '\n            ' + sniff, 1)
        data['server_config'] = cfg
        data['server_override'] = True
        data['id'] = row.id
        data = _prepare_create_data(data)
        CustomProxy.add_or_update(**data)
        print('BELKA_SNIFF_APPLIED', row.id, row.child_id)
PY
  ) || true
  case $out in
    *BELKA_SNIFF_APPLIED*) log INFO "Hiddify REALITY-termination sniffing override applied" ;;
    *BELKA_SNIFF_PRESENT*) log INFO "Hiddify REALITY-termination sniffing override already present" ;;
    *BELKA_SNIFF_UNEXPECTED*) warn "Hiddify REALITY-termination template shape changed; apply the sniffing override from the panel" ;;
    *BELKA_SNIFF_MISSING*) warn "Hiddify REALITY-termination proxy not found; apply the sniffing override from the panel" ;;
    *) warn "could not apply the Hiddify REALITY-termination sniffing override: $(printf '%s\n' "$out" | tail -n 3)" ;;
  esac

  local cfg=/opt/hiddify-manager/generated/xray.json
  local needs_regen=0
  local sniff_jq='
    def sniff_ok:
      ((.sniffing.enabled // false) == true)
      and ((.sniffing.routeOnly // false) == false)
      and (([(.sniffing.destOverride // [])[]
             | select(. == "http" or . == "tls" or . == "quic")]
            | unique | length) == 3);
    [.inbounds[]? | select((.tag // "") | test("reality terminator"))] as $ib
    | ($ib | length) > 0 and ([$ib[] | select(sniff_ok | not)] | length == 0)'
  if [[ -f $cfg ]] && jq -e "$sniff_jq" "$cfg" >/dev/null 2>&1; then
    log INFO "generated Xray config already sniffs http/tls/quic on the REALITY terminator"
  else
    needs_regen=1
    log INFO "regenerating Hiddify configs to apply the REALITY sniffing override"
    /opt/hiddify-manager/scripts/hiddify sync-configs >>"$LOG" 2>&1 \
      || warn "hiddify sync-configs failed; check Hiddify logs and rerun"
    if [[ ! -f $cfg ]] || ! jq -e "$sniff_jq" "$cfg" >/dev/null 2>&1; then
      warn "generated config still lacks full sniffing on the REALITY terminator; apply the override in the panel"
    fi
  fi
  # sync-configs rewrites generated/xray.json but does not restart Xray, so the
  # running process would keep the old inbound definitions.
  if (( needs_regen )) || ! systemctl is-active -q hiddify-xray; then
    systemctl restart hiddify-xray >>"$LOG" 2>&1 \
      || warn "hiddify-xray restart failed; check systemctl status hiddify-xray"
    log INFO "hiddify-xray restarted to load the REALITY sniffing override"
  fi
}

write_ru_handoff() {
  local f=/root/belka-ru-handoff.env
  write_if_changed "$f" 600 <<EOF
# belka-vpn RU handoff — PUBLIC DATA ONLY
BELKA_ROLE=ru
RU_PUBLIC_IP=${RU_PUBLIC_IP}
RU_TUNNEL_IP=${RU_TUNNEL_IP}
RU_PUBLIC_KEY=$(cat "$KEY_DIR/public.key")
EOF
  log INFO "RU handoff written: $f (0600)"
}

render_ru_awg() {
  validate_tunnel_net
  export RU_TUNNEL_IP RU_PRIVATE_KEY AWG_MTU OBF_LINES
  export FOREIGN_PUBLIC_KEY FOREIGN_PUBLIC_IP AWG_PORT FOREIGN_TUNNEL_IP
  RU_PRIVATE_KEY=$(cat "$KEY_DIR/private.key")
  OBF_LINES=$(emit_obf)
  render_template "$SCRIPT_DIR/../config/ru/awg0.conf.tpl" "$AWG_DIR/awg0.conf" 600
  chmod 600 "$AWG_DIR/awg0.conf"
  log INFO "rendered $AWG_DIR/awg0.conf (FOREIGN peer ${FOREIGN_PUBLIC_IP}:${AWG_PORT})"
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

# Hiddify rejects '#' comments and blank lines in Sites/Geosites lists. The repo
# files stay documented; /root gets paste-ready versions.
write_rule_list() {
  local src=$1 dst=$2 tmp
  [[ -r $src ]] || die "rule list not found: $src"
  tmp=$(mktemp)
  grep -vE '^[[:space:]]*(#|$)' "$src" > "$tmp" || true
  install -m 600 "$tmp" "$dst"
  rm -f "$tmp"
}

write_checklist() {
  export FOREIGN_TUNNEL_IP SOCKS_PORT REALITY_SNI RU_PUBLIC_IP
  render_template "$SCRIPT_DIR/../config/ru/hiddify-checklist.txt.tpl" \
    /root/belka-ru-manual-checklist.txt 600
  write_rule_list "$SCRIPT_DIR/../config/rules/foreign-domains.txt" /root/belka-foreign-domains.txt
  write_rule_list "$SCRIPT_DIR/../config/rules/foreign-geosites.txt" /root/belka-foreign-geosites.txt
  write_rule_list "$SCRIPT_DIR/../config/rules/foreign-google-ip.txt" /root/belka-foreign-google-ip.txt
  write_rule_list "$SCRIPT_DIR/../config/rules/foreign-telegram-ip.txt" /root/belka-foreign-telegram-ip.txt
  log INFO "manual checklist: /root/belka-ru-manual-checklist.txt"
  cat /root/belka-ru-manual-checklist.txt >&3
}

summary_ru() {
  log INFO "RU setup complete"
  local handshake=absent
  if grep -qE '^[1-9]' <<< "$(awg show awg0 latest-handshakes 2>/dev/null | awk 'NR==1{print $2}')"; then
    handshake=present
  fi
  cat >&3 <<EOF
RU readiness
  awg0:       ${RU_TUNNEL_IP}/${TUNNEL_PREFIX} -> ${FOREIGN_PUBLIC_IP}:${AWG_PORT}
  handshake:  ${handshake}
  handoff:    /root/belka-ru-handoff.env
  checklist:  /root/belka-ru-manual-checklist.txt

Next steps
  1) If the handshake is absent, copy /root/belka-ru-handoff.env to FOREIGN and run:
     bash scripts/install-foreign.sh --handoff /root/belka-ru-handoff.env
  2) Run: hiddify admin   (the link is a secret)
  3) Follow /root/belka-ru-manual-checklist.txt in the panel.
  4) On RU run: bash scripts/verify.sh
EOF
}

uninstall_ru() {
  log INFO "uninstalling RU tunnel components (Hiddify Manager is kept)"
  systemctl disable --now awg-quick@awg0 2>/dev/null || true
  rm -f "$AWG_DIR/awg0.conf"
  # Hand IP forwarding back to Hiddify's own sysctl files.
  if [[ -e /etc/sysctl.d/zz-belka-no-forward.conf ]]; then
    rm -f /etc/sysctl.d/zz-belka-no-forward.conf
    sysctl --system >>"$LOG" 2>&1 || true
  fi
  if [[ -x /opt/hiddify-manager/uninstall.sh ]]; then
    warn "to remove Hiddify Manager manually: bash /opt/hiddify-manager/uninstall.sh"
  fi
  log INFO "RU tunnel components stopped/removed"
}

main() {
  parse_args "$@"
  if (( UNINSTALL && DRY_RUN )); then
    printf 'error: --uninstall and --dry-run are mutually exclusive\n' >&2
    exit 2
  fi
  if (( KEYS_ONLY && UNINSTALL )); then
    printf 'error: --keys-only and --uninstall are mutually exclusive\n' >&2
    exit 2
  fi
  if (( KEYS_ONLY && DRY_RUN )); then
    printf 'error: --keys-only and --dry-run are mutually exclusive; run --keys-only for real or --dry-run for the full plan\n' >&2
    exit 2
  fi
  belka_init ru
  need_root
  check_os
  load_env_file "$ENV_FILE" || warn "env file not found: $ENV_FILE"
  apply_defaults

  : "${RU_PUBLIC_IP:?RU_PUBLIC_IP is required (set it in $ENV_FILE)}"
  : "${FOREIGN_PUBLIC_IP:?FOREIGN_PUBLIC_IP is required (set it in $ENV_FILE)}"

  if (( UNINSTALL )); then
    uninstall_ru
    exit 0
  fi

  if (( KEYS_ONLY )); then
    install_base_packages
    check_tunnel_conflict
    install_amneziawg
    gen_keypair
    write_ru_handoff
    cat >&3 <<EOF
RU_PUBLIC_KEY=$(cat "$KEY_DIR/public.key")
Handoff: /root/belka-ru-handoff.env
EOF
    exit 0
  fi

  # RU-owned values from the local env must survive loading the FOREIGN
  # handoff (older handoffs also carry REALITY_SNI).
  local local_ru_public_ip=${RU_PUBLIC_IP:-} local_reality_sni=${REALITY_SNI:-}
  local stored_handoff=$BELKA_CONFIG_DIR/foreign-handoff.env
  if [[ -z $HANDOFF_IN ]]; then
    HANDOFF_IN=${FOREIGN_HANDOFF_FILE:-$stored_handoff}
  fi
  load_handoff "$HANDOFF_IN" foreign
  if [[ -n $local_ru_public_ip ]]; then
    RU_PUBLIC_IP=$local_ru_public_ip
  fi
  if [[ -n $local_reality_sni ]]; then
    REALITY_SNI=$local_reality_sni
  fi

  validate_tunnel_net
  (( 10#$AWG_JMAX <= 10#$AWG_MTU )) || die "AWG_JMAX exceeds AWG_MTU in FOREIGN handoff"

  if (( DRY_RUN )); then
    log INFO "dry-run: would install AmneziaWG + Hiddify Manager, write the hiddify-core compatibility drop-in,"
    log INFO "dry-run: apply the REALITY-termination sniffing override (built-in proxy server_config) and regenerate Hiddify configs,"
    log INFO "dry-run: write $AWG_DIR/awg0.conf, start awg0 to $FOREIGN_PUBLIC_IP:$AWG_PORT, set IP forwarding (RU_IP_FORWARD=$RU_IP_FORWARD)"
    log INFO "dry-run: and print the manual checklist"
    exit 0
  fi

  install_base_packages
  preflight_ru
  install_hiddify
  apply_hiddify_reality_sniffing
  install_amneziawg
  gen_keypair
  write_ru_handoff
  render_ru_awg
  start_awg
  if [[ ! $HANDOFF_IN -ef $stored_handoff ]]; then
    install -d -m 700 "$BELKA_CONFIG_DIR"
    write_if_changed "$stored_handoff" 600 < "$HANDOFF_IN"
  fi
  configure_ip_forwarding
  # Hiddify Manager owns the RU firewall: ban via blackhole routes, not iptables.
  setup_fail2ban route
  write_checklist
  harden_ssh
  summary_ru
}

main "$@"
