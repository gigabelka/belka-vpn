#!/usr/bin/env bash
# install-ru.sh — Russia server: AmneziaWG client + Hiddify Manager install.
#
# Typical sequence:
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

usage() {
  cat <<'EOF'
Usage: install-ru.sh [options]

Options:
  --env-file FILE   Server env file (default: /etc/belka-vpn/ru.env)
  --keys-only       Install AmneziaWG, generate RU keys, write RU handoff
  --handoff FILE    FOREIGN handoff with FOREIGN_PUBLIC_KEY and obfuscation parameters
  --uninstall       Stop and remove RU tunnel components (Hiddify is kept)
  --dry-run         Print the plan and exit
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
  if [[ ! -f $AWG_DIR/awg0.conf ]] && port_udp_busy "$AWG_PORT"; then
    warn "UDP/$AWG_PORT is already in use (check for conflicts)"
  fi
  if [[ ${INSTALL_HIDDIFY:-1} == 1 && ! -d /opt/hiddify-manager ]]; then
    if ss -lntp 2>/dev/null | grep -qE ':(80|443) '; then
      die "ports 80/443 are in use; Hiddify Manager needs them (stop the service or set INSTALL_HIDDIFY=0)"
    fi
  fi
}

install_hiddify() {
  if [[ ${INSTALL_HIDDIFY:-1} != 1 ]]; then
    log INFO "Hiddify Manager install disabled by env"
    return 0
  fi
  if [[ -d /opt/hiddify-manager ]]; then
    log INFO "Hiddify Manager already installed"
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
    # WARP (usque) registration is often unreachable from Russia and returns
    # non-zero even though the panel finished. Treat that as success only when
    # the panel really is installed; we keep WARP off in this deployment.
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
  log INFO "Hiddify Manager installed; admin link: run 'hiddify admin' on the server"
  log INFO "installer output saved to $out (0600, contains the admin link)"
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

write_checklist() {
  export FOREIGN_TUNNEL_IP SOCKS_PORT REALITY_SNI RU_PUBLIC_IP
  render_template "$SCRIPT_DIR/../config/ru/hiddify-checklist.txt.tpl" \
    /root/belka-ru-manual-checklist.txt 600
  install -m 600 "$SCRIPT_DIR/../config/rules/foreign-domains.txt" /root/belka-foreign-domains.txt
  install -m 600 "$SCRIPT_DIR/../config/rules/foreign-geosites.txt" /root/belka-foreign-geosites.txt
  install -m 600 "$SCRIPT_DIR/../config/rules/foreign-telegram-ip.txt" /root/belka-foreign-telegram-ip.txt
  log INFO "manual checklist: /root/belka-ru-manual-checklist.txt"
  cat /root/belka-ru-manual-checklist.txt >&3
}

summary_ru() {
  log INFO "RU setup complete"
  local handshake=absent
  if awg show awg0 latest-handshakes 2>/dev/null | awk 'NR==1{print $2}' | grep -qE '^[1-9]'; then
    handshake=present
  fi
  cat >&3 <<EOF
RU readiness
  awg0:       ${RU_TUNNEL_IP}/24 -> ${FOREIGN_PUBLIC_IP}:${AWG_PORT}
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
  if [[ -x /opt/hiddify-manager/uninstall.sh ]]; then
    warn "to remove Hiddify Manager manually: bash /opt/hiddify-manager/uninstall.sh"
  fi
  log INFO "RU tunnel components stopped/removed"
}

main() {
  parse_args "$@"
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

  if (( DRY_RUN )); then
    log INFO "dry-run: would install AmneziaWG + Hiddify Manager, write $AWG_DIR/awg0.conf,"
    log INFO "dry-run: start awg0 to $FOREIGN_PUBLIC_IP:$AWG_PORT and print the manual checklist"
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

  local local_ru_public_ip=${RU_PUBLIC_IP:-}
  if [[ -z $HANDOFF_IN ]]; then
    HANDOFF_IN=${FOREIGN_HANDOFF_FILE:-/etc/belka-vpn/foreign-handoff.env}
  fi
  load_handoff "$HANDOFF_IN"
  install -D -m 600 "$HANDOFF_IN" "$BELKA_CONFIG_DIR/foreign-handoff.env"
  # Keep the RU server's own public IP from the local env.
  if [[ -n $local_ru_public_ip ]]; then
    RU_PUBLIC_IP=$local_ru_public_ip
  fi

  : "${FOREIGN_PUBLIC_KEY:?FOREIGN handoff missing FOREIGN_PUBLIC_KEY}"
  local v
  for v in AWG_JC AWG_JMIN AWG_JMAX AWG_S1 AWG_S2 AWG_H1 AWG_H2 AWG_H3 AWG_H4; do
    [[ -n ${!v:-} ]] || die "FOREIGN handoff missing $v"
  done

  install_base_packages
  preflight_ru
  install_hiddify
  install_amneziawg
  gen_keypair
  write_ru_handoff
  render_ru_awg
  start_awg
  setup_fail2ban
  write_checklist
  harden_ssh
  summary_ru
}

main "$@"
