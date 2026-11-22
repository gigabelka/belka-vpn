#!/usr/bin/env bash
# lib.sh — shared helpers for belka-vpn setup scripts.
# Source this file; do not execute it directly.
#
# Design rules:
#   * never print private keys or installer secrets;
#   * no `set -x`;
#   * idempotent file writes (render_template sets TEMPLATE_CHANGED);
#   * Ubuntu 22.04/24.04 only.

set -euo pipefail
umask 077

BELKA_REPO_URL=${BELKA_REPO_URL:-https://github.com/gigabelka/belka-vpn.git}
BELKA_CONFIG_DIR=${BELKA_CONFIG_DIR:-/etc/belka-vpn}
AWG_DIR=${AWG_DIR:-/etc/amnezia/amneziawg}
KEY_DIR=${KEY_DIR:-$AWG_DIR/keys}

ROLE=${ROLE:-}
LOG=${LOG:-}
TEMPLATE_CHANGED=0

# ---------------------------------------------------------------- logging ---

log() {
  local lvl=$1
  shift
  printf '%s [%-5s] %s\n' "$(date -Is)" "$lvl" "$*" | tee -a "$LOG" >&3
}

warn() { log WARN "$*"; }
die() { log ERROR "$*"; exit "${2:-1}"; }

belka_init() {
  ROLE=${1:?role required}
  LOG=${LOG:-/var/log/belka-vpn-${ROLE}.log}
  install -d -m 755 /var/log
  [[ -e $LOG ]] || install -m 600 /dev/null "$LOG"
  chmod 600 "$LOG" 2>/dev/null || true
  exec 3>&1
  trap 'rc=$?; if (( rc != 0 )); then printf "%s [ERROR] failed at %s:%s rc=%s\n" \
    "$(date -Is)" "${BASH_SOURCE[0]}" "${LINENO}" "$rc" | tee -a "$LOG" >&3; fi' ERR
  log INFO "=== belka-vpn ${ROLE} start ==="
}

# ----------------------------------------------------------------- checks ---

need_root() {
  (( EUID == 0 )) || die "run as root"
}

check_os() {
  [[ -r /etc/os-release ]] || die "/etc/os-release not found"
  # shellcheck disable=SC1091
  . /etc/os-release
  case "${ID:-}:${VERSION_ID:-}" in
    ubuntu:22.04|ubuntu:24.04) ;;
    *) die "Ubuntu 22.04 or 24.04 required; found ${PRETTY_NAME:-unknown}" ;;
  esac
  [[ -d /run/systemd/system ]] || die "systemd not detected"
  case "$(dpkg --print-architecture)" in
    amd64|arm64) ;;
    *) die "unsupported architecture: $(dpkg --print-architecture)" ;;
  esac
}

apply_defaults() {
  : "${AWG_PORT:=443}"
  : "${TUNNEL_NET:=172.16.0.0/24}"
  : "${FOREIGN_TUNNEL_IP:=172.16.0.1}"
  : "${RU_TUNNEL_IP:=172.16.0.2}"
  : "${SOCKS_PORT:=1080}"
  : "${AWG_MTU:=1280}"
  : "${SSH_PORT:=22}"
  : "${REALITY_SNI:=www.microsoft.com}"
  : "${ENABLE_UFW:=1}"
  : "${ENABLE_FAIL2BAN:=1}"
  : "${AWG_ENABLE_S3S4:=0}"
  : "${INSTALL_HIDDIFY:=1}"
  : "${HIDDIFY_INSTALL_URL:=https://i.hiddify.com/release}"
  : "${HARDEN_SSH:=0}"
  export AWG_PORT TUNNEL_NET FOREIGN_TUNNEL_IP RU_TUNNEL_IP SOCKS_PORT AWG_MTU \
    SSH_PORT REALITY_SNI ENABLE_UFW ENABLE_FAIL2BAN AWG_ENABLE_S3S4 \
    INSTALL_HIDDIFY HIDDIFY_INSTALL_URL HARDEN_SSH
}

# --------------------------------------------------------------- env files ---

load_env_file() {
  local f=$1
  [[ -r $f ]] || return 1
  local mode
  mode=$(stat -c %a "$f" 2>/dev/null || echo unknown)
  [[ $mode == 600 ]] || warn "env file $f has mode $mode (expected 600)"
  # shellcheck disable=SC1090
  set -a
  . "$f"
  set +a
  log INFO "loaded env file: $f"
  return 0
}

load_handoff() {
  local f=$1
  [[ -r $f ]] || die "handoff not found: $f"
  if grep -Eiq '^(FOREIGN|RU)_PRIVATE_KEY[[:space:]]*=|BEGIN [A-Z ]*PRIVATE KEY|PASSWORD[[:space:]]*=|SECRET[[:space:]]*=' "$f"; then
    die "refusing handoff containing secrets: $f"
  fi
  local mode
  mode=$(stat -c %a "$f" 2>/dev/null || echo unknown)
  [[ $mode == 600 ]] || warn "handoff $f has mode $mode (expected 600)"
  # shellcheck disable=SC1090
  set -a
  . "$f"
  set +a
  log INFO "loaded handoff: $f"
}

# ------------------------------------------------------------------- apt ---

apt_update() {
  DEBIAN_FRONTEND=noninteractive apt-get update >>"$LOG" 2>&1 \
    || die "apt-get update failed"
}

apt_install() {
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@" \
    >>"$LOG" 2>&1 || die "apt-get install failed: $*"
}

install_base_packages() {
  apt_update
  apt_install curl ca-certificates gnupg jq gettext-base ufw fail2ban iproute2
  modprobe tcp_bbr >>"$LOG" 2>&1 || true
  write_sysctl
  setup_logrotate
  timedatectl set-ntp true >>"$LOG" 2>&1 || warn "could not enable NTP"
}

write_sysctl() {
  write_if_changed /etc/sysctl.d/99-belka-vpn.conf 644 <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2
EOF
  sysctl --system >>"$LOG" 2>&1 || warn "sysctl --system reported errors"
}

setup_logrotate() {
  write_if_changed /etc/logrotate.d/belka-vpn 644 <<'EOF'
/var/log/belka-vpn-*.log {
    weekly
    rotate 8
    compress
    missingok
    notifempty
    create 0600 root root
}
EOF
}

# -------------------------------------------------------------- amneziawg ---

install_amneziawg() {
  apt_update
  apt_install software-properties-common python3-launchpadlib gnupg2 \
    "linux-headers-$(uname -r)" dkms build-essential

  if ! grep -Rqs 'ppa.launchpadcontent.net/amnezia/ppa' /etc/apt/sources.list.d/ 2>/dev/null; then
    add-apt-repository -y ppa:amnezia/ppa >>"$LOG" 2>&1 \
      || die "failed to add ppa:amnezia/ppa"
    apt_update
  fi

  if ! dpkg -s amneziawg >/dev/null 2>&1; then
    if apt-cache show amneziawg >/dev/null 2>&1; then
      apt_install amneziawg
    elif apt-cache show amneziawg-linux-kmod >/dev/null 2>&1; then
      apt_install amneziawg-linux-kmod amneziawg-tools
    else
      apt_install amneziawg-dkms amneziawg-tools
    fi
  fi
  command -v awg >/dev/null 2>&1 || apt_install amneziawg-tools

  modprobe amneziawg >>"$LOG" 2>&1 \
    || die "amneziawg kernel module failed; check linux-headers, dkms status, Secure Boot"
  command -v awg >/dev/null 2>&1 || die "awg binary not found after install"
  log INFO "AmneziaWG: $(awg --version 2>/dev/null | head -n1)"
}

gen_keypair() {
  install -d -m 700 "$KEY_DIR"
  if [[ -s $KEY_DIR/private.key && ${ROTATE_KEYS:-0} != 1 ]]; then
    log INFO "reusing AmneziaWG key ($(key_fp))"
    return 0
  fi
  ( umask 077; awg genkey > "$KEY_DIR/private.key.tmp" )
  chmod 600 "$KEY_DIR/private.key.tmp"
  mv -f "$KEY_DIR/private.key.tmp" "$KEY_DIR/private.key"
  awg pubkey < "$KEY_DIR/private.key" > "$KEY_DIR/public.key.tmp"
  chmod 600 "$KEY_DIR/public.key.tmp"
  mv -f "$KEY_DIR/public.key.tmp" "$KEY_DIR/public.key"
  log INFO "generated AmneziaWG key ($(key_fp))"
}

key_fp() {
  awg pubkey < "$KEY_DIR/private.key" | sha256sum | cut -c1-16
}

rand32() { od -An -N4 -tu4 /dev/urandom | tr -d ' \n'; }

rand_range() {
  local lo=$1 hi=$2
  echo $(( lo + $(rand32) % (hi - lo + 1) ))
}

# Generates S/H values that must be identical on both peers. S3/S4 are
# version-dependent (AWG 2.x+); they are emitted only when AWG_ENABLE_S3S4=1.
load_or_gen_obfuscation() {
  local f=$BELKA_CONFIG_DIR/foreign-obfuscation.env
  install -d -m 700 "$BELKA_CONFIG_DIR"
  if [[ -s $f && ${ROTATE_OBFUSCATION:-0} != 1 ]]; then
    # shellcheck disable=SC1090
    set -a; . "$f"; set +a
    log INFO "reusing obfuscation parameters from $f"
    return 0
  fi

  local Jc Jmin Jmax S1 S2 S3 S4 H1 H2 H3 H4
  Jc=$(rand_range 4 10)
  Jmin=$(rand_range 40 100)
  Jmax=$(rand_range $((Jmin + 1)) 300)
  S1=$(rand_range 15 150)
  S2=$(rand_range 15 150)
  while (( S2 == S1 + 56 )); do S2=$(rand_range 15 150); done
  S3=0
  S4=0
  if [[ ${AWG_ENABLE_S3S4:-0} == 1 ]]; then
    S3=$(rand_range 12 100)
    S4=$(rand_range 12 100)
  fi

  local -a H=()
  local v
  while (( ${#H[@]} < 4 )); do
    v=$(rand_range 5 2147483647)
    [[ " ${H[*]:-} " == *" $v "* ]] || H+=("$v")
  done
  H1=${H[0]} H2=${H[1]} H3=${H[2]} H4=${H[3]}

  ( umask 077; cat > "$f" <<EOF
AWG_JC=$Jc
AWG_JMIN=$Jmin
AWG_JMAX=$Jmax
AWG_S1=$S1
AWG_S2=$S2
AWG_S3=$S3
AWG_S4=$S4
AWG_H1=$H1
AWG_H2=$H2
AWG_H3=$H3
AWG_H4=$H4
EOF
  )
  # shellcheck disable=SC1090
  set -a; . "$f"; set +a
  log INFO "generated obfuscation parameters"
}

emit_obf() {
  cat <<EOF
Jc = ${AWG_JC}
Jmin = ${AWG_JMIN}
Jmax = ${AWG_JMAX}
S1 = ${AWG_S1}
S2 = ${AWG_S2}
H1 = ${AWG_H1}
H2 = ${AWG_H2}
H3 = ${AWG_H3}
H4 = ${AWG_H4}
EOF
  if (( ${AWG_S3:-0} > 0 )); then echo "S3 = ${AWG_S3}"; fi
  if (( ${AWG_S4:-0} > 0 )); then echo "S4 = ${AWG_S4}"; fi
}

# ----------------------------------------------------------------- files ---

# Replaces $VAR / ${VAR} in a template using env. Sets TEMPLATE_CHANGED.
# The output is installed atomically with the requested mode.
render_template() {
  local tpl=$1 out=$2 mode=${3:-600}
  [[ -r $tpl ]] || die "template not found: $tpl"
  local tmp
  tmp=$(mktemp)
  envsubst < "$tpl" > "$tmp" || { rm -f "$tmp"; die "envsubst failed: $tpl"; }
  if [[ -f $out ]] && cmp -s "$tmp" "$out"; then
    rm -f "$tmp"
    TEMPLATE_CHANGED=0
  else
    install -D -m "$mode" "$tmp" "$out"
    rm -f "$tmp"
    TEMPLATE_CHANGED=1
  fi
}

# Writes stdin to a file if the content changed. Sets TEMPLATE_CHANGED.
write_if_changed() {
  local dst=$1 mode=${2:-600}
  local tmp
  tmp=$(mktemp)
  cat > "$tmp"
  if [[ -f $dst ]] && cmp -s "$tmp" "$dst"; then
    rm -f "$tmp"
    TEMPLATE_CHANGED=0
  else
    install -D -m "$mode" "$tmp" "$dst"
    rm -f "$tmp"
    TEMPLATE_CHANGED=1
  fi
}

download_file() {
  local url=$1 dst=$2
  install -d -m 750 "$(dirname "$dst")"
  curl -fsSL --retry 3 --connect-timeout 15 -o "$dst" "$url" \
    || die "download failed: $url"
  chmod 600 "$dst"
}

# ------------------------------------------------------------------- ufw ---

ufw_rule() {
  local verb=$1
  shift
  local out
  out=$(ufw "$verb" "$@" 2>&1) || die "ufw $verb failed: $*"
  printf '%s\n' "$out" >>"$LOG"
  log INFO "ufw: $verb $*"
}

ufw_allow() { ufw_rule allow "$@"; }
ufw_limit() { ufw_rule limit "$@"; }

setup_fail2ban() {
  if [[ ${ENABLE_FAIL2BAN:-1} != 1 ]]; then
    log INFO "fail2ban disabled by env"
    return 0
  fi
  install -d -m 755 /etc/fail2ban/jail.d
  write_if_changed /etc/fail2ban/jail.d/belka-sshd.local 644 <<EOF
[sshd]
enabled = true
port = ${SSH_PORT}
maxretry = 5
findtime = 10m
bantime = 1h
EOF
  systemctl enable --now fail2ban >>"$LOG" 2>&1 || warn "fail2ban failed to start"
}

harden_ssh() {
  if [[ ${HARDEN_SSH:-0} != 1 ]]; then
    return 0
  fi
  warn "SSH hardening requested; make sure key-based login works in a second session"
  write_if_changed /etc/ssh/sshd_config.d/99-belka-hardening.conf 644 <<'EOF'
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
EOF
  if ! sshd -t >>"$LOG" 2>&1; then
    rm -f /etc/ssh/sshd_config.d/99-belka-hardening.conf
    die "sshd config test failed; hardening file removed"
  fi
  systemctl reload ssh >>"$LOG" 2>&1 || warn "could not reload ssh"
  log INFO "SSH hardening enabled"
}

# -------------------------------------------------------------- utilities ---

check_tunnel_conflict() {
  if ip -4 route show | grep -Fq "$TUNNEL_NET" && ! ip link show awg0 >/dev/null 2>&1; then
    warn "route for $TUNNEL_NET already exists; check Docker/libvirt/LAN conflicts"
  fi
}

port_udp_busy() {
  ss -lunp 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$1$"
}

tunnel_peer_present() {
  [[ -n ${RU_PUBLIC_KEY:-} || -n ${FOREIGN_PUBLIC_KEY:-} ]]
}
