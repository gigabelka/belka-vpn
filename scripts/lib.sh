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
UFW_TUNNEL_COMMENT=belka-vpn-tunnel

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
  : "${AWG_MTU:=1240}"
  : "${SSH_PORT:=22}"
  : "${REALITY_SNI:=www.microsoft.com}"
  : "${ENABLE_UFW:=1}"
  : "${ENABLE_FAIL2BAN:=1}"
  : "${AWG_ENABLE_S3S4:=0}"
  : "${INSTALL_HIDDIFY:=1}"
  : "${HIDDIFY_INSTALL_URL:=https://i.hiddify.com/release}"
  : "${HARDEN_SSH:=0}"
  : "${RU_IP_FORWARD:=0}"
  : "${GOOGLE_IPV6_EGRESS:=0}"
  : "${HE_SERVER_IPV4:=}"
  : "${HE_CLIENT_IPV6:=}"
  : "${FOREIGN_EGRESS_IPV4:=}"
  export AWG_PORT TUNNEL_NET FOREIGN_TUNNEL_IP RU_TUNNEL_IP SOCKS_PORT AWG_MTU \
    SSH_PORT REALITY_SNI ENABLE_UFW ENABLE_FAIL2BAN AWG_ENABLE_S3S4 \
    INSTALL_HIDDIFY HIDDIFY_INSTALL_URL HARDEN_SSH RU_IP_FORWARD \
    GOOGLE_IPV6_EGRESS HE_SERVER_IPV4 HE_CLIENT_IPV6 FOREIGN_EGRESS_IPV4
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

# Handoff files carry public data only. Parse them as KEY=VALUE lines against a
# per-role allowlist instead of sourcing them: a handoff must not be able to run
# commands or overwrite unrelated variables.
handoff_field_allowed() {
  local role=$1 key=$2
  case "$role:$key" in
    ru:BELKA_ROLE|ru:RU_PUBLIC_IP|ru:RU_TUNNEL_IP|ru:RU_PUBLIC_KEY)
      return 0 ;;
    foreign:BELKA_ROLE|foreign:FOREIGN_PUBLIC_IP|foreign:RU_PUBLIC_IP|\
    foreign:AWG_PORT|foreign:TUNNEL_NET|foreign:FOREIGN_TUNNEL_IP|\
    foreign:RU_TUNNEL_IP|foreign:SOCKS_PORT|foreign:AWG_MTU|\
    foreign:FOREIGN_PUBLIC_KEY|foreign:AWG_JC|foreign:AWG_JMIN|\
    foreign:AWG_JMAX|foreign:AWG_S1|foreign:AWG_S2|foreign:AWG_S3|\
    foreign:AWG_S4|foreign:AWG_H1|foreign:AWG_H2|foreign:AWG_H3|\
    foreign:AWG_H4|foreign:REALITY_SNI)
      return 0 ;;
    *) return 1 ;;
  esac
}

handoff_valid_ipv4() { ipv4_to_int "$1" >/dev/null 2>&1; }

handoff_valid_cidr() {
  local value=$1 prefix
  [[ $value =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]{1,2})$ ]] || return 1
  handoff_valid_ipv4 "${value%/*}" || return 1
  prefix=${value##*/}
  (( 10#$prefix <= 32 ))
}

handoff_valid_port() {
  [[ $1 =~ ^[1-9][0-9]{0,4}$ ]] && (( 10#$1 <= 65535 ))
}

handoff_valid_uint() {
  [[ $1 =~ ^[0-9]{1,10}$ ]] && (( 10#$1 <= 2147483647 ))
}

handoff_valid_mtu() {
  [[ $1 =~ ^[0-9]{3,5}$ ]] && (( 10#$1 >= 576 && 10#$1 <= 9000 ))
}

handoff_valid_wg_key() {
  [[ $1 =~ ^[A-Za-z0-9+/]{43}=$ ]]
}

handoff_valid_hostname() {
  local value=$1
  (( ${#value} >= 1 && ${#value} <= 253 )) || return 1
  [[ $value =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)*[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]]
}

handoff_validate_value() {
  local key=$1 value=$2
  case $key in
    *_PUBLIC_IP|*_TUNNEL_IP) handoff_valid_ipv4 "$value" ;;
    TUNNEL_NET) handoff_valid_cidr "$value" ;;
    AWG_PORT|SOCKS_PORT) handoff_valid_port "$value" ;;
    AWG_MTU) handoff_valid_mtu "$value" ;;
    AWG_JC|AWG_JMIN|AWG_JMAX|AWG_S[1-4]|AWG_H[1-4]) handoff_valid_uint "$value" ;;
    *_PUBLIC_KEY) handoff_valid_wg_key "$value" ;;
    REALITY_SNI) handoff_valid_hostname "$value" ;;
    *) return 1 ;;
  esac
}

# load_handoff FILE PRODUCER_ROLE
# PRODUCER_ROLE is the role that wrote the file: RU loads "ru", FOREIGN and
# verify load "foreign". Required fields must be present in the file itself.
load_handoff() {
  local f=$1 expected_role=${2:?handoff producer role required (ru|foreign)}
  [[ -r $f ]] || die "handoff not found: $f"
  case $expected_role in
    ru|foreign) ;;
    *) die "handoff role must be ru or foreign: $expected_role" ;;
  esac

  if grep -Eiq '^(FOREIGN|RU)_PRIVATE_KEY[[:space:]]*=|BEGIN [A-Z ]*PRIVATE KEY|PASSWORD[[:space:]]*=|SECRET[[:space:]]*=' "$f"; then
    die "refusing handoff containing secrets: $f"
  fi
  local mode
  mode=$(stat -c %a "$f" 2>/dev/null || echo unknown)
  [[ $mode == 600 ]] || warn "handoff $f has mode $mode (expected 600)"

  local -A seen=()
  local line key value lineno=0
  while IFS= read -r line || [[ -n $line ]]; do
    lineno=$((lineno + 1))
    line=${line%$'\r'}
    if (( lineno == 1 )); then
      line=${line#$'\xEF\xBB\xBF'}
    fi
    if [[ $line =~ ^[[:space:]]*$ ]] || [[ $line =~ ^[[:space:]]*# ]]; then
      continue
    fi
    if [[ ! $line =~ ^([A-Z][A-Z0-9_]*)=(.*)$ ]]; then
      die "handoff $f:$lineno: malformed line (expected KEY=VALUE)"
    fi
    key=${BASH_REMATCH[1]}
    value=${BASH_REMATCH[2]}
    [[ -n $value ]] || die "handoff $f:$lineno: empty value for $key"
    [[ $value =~ ^[A-Za-z0-9._:/+=-]+$ ]] \
      || die "handoff $f:$lineno: invalid characters in $key"
    [[ -z ${seen[$key]:-} ]] || die "handoff $f:$lineno: duplicate field $key"
    handoff_field_allowed "$expected_role" "$key" \
      || die "handoff $f:$lineno: unexpected field $key for role $expected_role"
    seen[$key]=1
    if [[ $key == BELKA_ROLE ]]; then
      [[ $value == "$expected_role" ]] \
        || die "handoff $f: BELKA_ROLE=$value, expected producer role $expected_role"
    else
      handoff_validate_value "$key" "$value" \
        || die "handoff $f:$lineno: invalid value for $key"
    fi
    printf -v "$key" '%s' "$value"
    export "$key"
  done < "$f"

  local -a required=()
  local k
  case $expected_role in
    ru) required=(BELKA_ROLE RU_PUBLIC_IP RU_TUNNEL_IP RU_PUBLIC_KEY) ;;
    foreign)
      required=(BELKA_ROLE FOREIGN_PUBLIC_IP RU_PUBLIC_IP AWG_PORT TUNNEL_NET
        FOREIGN_TUNNEL_IP RU_TUNNEL_IP SOCKS_PORT AWG_MTU FOREIGN_PUBLIC_KEY
        AWG_JC AWG_JMIN AWG_JMAX AWG_S1 AWG_S2 AWG_H1 AWG_H2 AWG_H3 AWG_H4)
      ;;
  esac
  for k in "${required[@]}"; do
    [[ -n ${seen[$k]:-} ]] || die "handoff $f: missing required field $k"
  done
  log INFO "loaded handoff: $f (role $expected_role)"
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
# Socket buffer ceilings match what Hiddify sets at runtime on RU; the kernel
# defaults (208 KiB) cap explicit SO_RCVBUF/SO_SNDBUF requests on FOREIGN.
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.ipv4.tcp_rmem = 4096 131072 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
# Recover from PMTU black holes inside the 1280-byte AmneziaWG tunnel.
net.ipv4.tcp_mtu_probing = 1
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
  write_if_changed "$out" "$mode" < "$tmp"
  rm -f "$tmp"
}

# render_template_validated TEMPLATE DEST MODE VALIDATOR [ARGS...]
# Like render_template, but runs VALIDATOR <tmpfile> before installing anything.
# The destination is left untouched when validation fails. Sets TEMPLATE_CHANGED.
# Call only after belka_init: validator output goes to $LOG.
render_template_validated() {
  (( $# >= 4 )) || die "render_template_validated: TEMPLATE DEST MODE VALIDATOR required"
  local tpl=$1 out=$2 mode=$3
  shift 3
  [[ -r $tpl ]] || die "template not found: $tpl"
  local tmp
  # Validators such as Xray use the filename suffix to select the parser.
  tmp=$(mktemp --suffix=".$(basename -- "$out")")
  envsubst < "$tpl" > "$tmp" || { rm -f "$tmp"; die "envsubst failed: $tpl"; }
  if ! "$@" "$tmp" >>"$LOG" 2>&1; then
    rm -f "$tmp"
    die "rendered $out failed validation ($1); existing file kept (details in $LOG)"
  fi
  write_if_changed "$out" "$mode" < "$tmp"
  rm -f "$tmp"
}

# Atomically writes stdin if the content changed. Sets TEMPLATE_CHANGED.
write_if_changed() {
  local dst=$1 mode=${2:-600} dir tmp
  dir=$(dirname -- "$dst")
  mkdir -p -- "$dir"
  tmp=$(mktemp "$dir/.belka.XXXXXXXX")
  cat > "$tmp" || { rm -f -- "$tmp"; die "could not stage $dst"; }
  if [[ -f $dst ]] && cmp -s "$tmp" "$dst"; then
    rm -f "$tmp"
    TEMPLATE_CHANGED=0
  else
    if ! chmod "$mode" "$tmp" || ! mv -fT -- "$tmp" "$dst"; then
      rm -f -- "$tmp"
      die "could not replace $dst"
    fi
    TEMPLATE_CHANGED=1
  fi
}

# google_country [CURL_ARGS...]
# Prints the lowercase country Google's own geo database assigns to the egress
# address (the x-country header), or nothing. Third-party databases such as
# ipinfo.io can disagree with Google, and Google's view is what Gemini enforces.
google_country() {
  curl -sS -o /dev/null -D - --max-time 15 "$@" \
    'https://clientservices.googleapis.com/chrome-variations/seed?osname=win&channel=stable&milestone=140' \
    2>/dev/null | tr -d '\r' \
    | sed -nE 's/^x-country:[[:space:]]*([A-Za-z]+).*/\1/Ip' \
    | tr '[:upper:]' '[:lower:]' || true
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

# Generate the normalized commands reported by "ufw show added".
foreign_ufw_rules() {
  printf '%s\n' "limit $SSH_PORT/tcp" \
    "allow from $RU_PUBLIC_IP to any port $AWG_PORT proto udp" \
    "allow in on awg0 from $RU_TUNNEL_IP to $FOREIGN_TUNNEL_IP port $SOCKS_PORT proto tcp" \
    "allow in on awg0 from $RU_TUNNEL_IP to $FOREIGN_TUNNEL_IP port $SOCKS_PORT proto udp"
  if [[ $GOOGLE_IPV6_EGRESS == 1 && -n $HE_SERVER_IPV4 ]]; then
    printf '%s\n' "allow from $HE_SERVER_IPV4 proto ipv6"
  fi
}

ufw_rule_present() {
  local added=$1 expected=$2 line
  while IFS= read -r line; do
    if [[ $line == "ufw $expected" || $line == "ufw $expected comment "* ]]; then
      return 0
    fi
  done <<< "$added"
  return 1
}

foreign_ufw_managed_rules() {
  sed -nE "s/^ufw (allow .*) comment '$UFW_TUNNEL_COMMENT'$/\1/p"
}

socks_egress_ipv4() {
  local egress
  egress=$(curl -4 -fsS --noproxy '' --max-time 15 \
    --socks5-hostname "${FOREIGN_TUNNEL_IP}:${SOCKS_PORT}" \
    https://api.ipify.org 2>/dev/null) || return 1
  ipv4_to_int "$egress" >/dev/null || return 1
  printf '%s\n' "$egress"
}

# setup_fail2ban [BANACTION]
# Without an argument fail2ban keeps its default (iptables-multiport), which is
# fine on FOREIGN where belka owns the firewall. RU passes "route": bans become
# `ip route add unreachable <ip>` and never touch the firewall that Hiddify
# Manager owns.
setup_fail2ban() {
  local banaction=${1:-}
  if [[ ${ENABLE_FAIL2BAN:-1} != 1 ]]; then
    log INFO "fail2ban disabled by env"
    return 0
  fi
  install -d -m 755 /etc/fail2ban/jail.d
  # Process substitution, not a pipe: write_if_changed must run in this shell
  # so TEMPLATE_CHANGED reaches the restart check below.
  write_if_changed /etc/fail2ban/jail.d/belka-sshd.local 644 < <(
    printf '[sshd]\nenabled = true\nport = %s\nmaxretry = 5\nfindtime = 10m\nbantime = 1h\n' "$SSH_PORT"
    [[ -z $banaction ]] || printf 'banaction = %s\n' "$banaction"
  )
  local changed=$TEMPLATE_CHANGED
  systemctl enable fail2ban >>"$LOG" 2>&1 || true
  if (( changed )) || ! systemctl is-active -q fail2ban; then
    systemctl restart fail2ban >>"$LOG" 2>&1 || { warn "fail2ban failed to start"; return 0; }
    log INFO "fail2ban restarted${banaction:+ (banaction=$banaction)}"
  else
    log INFO "fail2ban unchanged and active"
  fi
}

harden_ssh() {
  if [[ ${HARDEN_SSH:-0} != 1 ]]; then
    return 0
  fi
  # sshd keeps the FIRST value it reads for each keyword and includes
  # sshd_config.d/*.conf in lexical order, so the file must sort before
  # cloud-init's 50-cloud-init.conf (which sets PasswordAuthentication yes).
  local conf=/etc/ssh/sshd_config.d/01-belka-hardening.conf
  if [[ ! -s /root/.ssh/authorized_keys ]]; then
    warn "SSH hardening skipped: /root/.ssh/authorized_keys is empty"
    return 0
  fi
  warn "SSH hardening requested; make sure key-based login works in a second session"
  rm -f /etc/ssh/sshd_config.d/99-belka-hardening.conf
  write_if_changed "$conf" 644 <<'EOF'
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
X11Forwarding no
EOF
  if ! sshd -t >>"$LOG" 2>&1; then
    rm -f "$conf"
    die "sshd config test failed; hardening file removed"
  fi
  # Capture first: grep -q closing the pipe early would fail under pipefail.
  local effective
  effective=$(sshd -T 2>/dev/null || true)
  if ! grep -qx 'passwordauthentication no' <<<"$effective"; then
    warn "SSH hardening file written but sshd still allows passwords; check sshd_config"
  fi
  systemctl reload ssh >>"$LOG" 2>&1 || warn "could not reload ssh"
  log INFO "SSH hardening enabled"
}

# -------------------------------------------------------------- utilities ---

ipv4_to_int() {
  local ip=$1 a b c d
  [[ $ip =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  a=$((10#${BASH_REMATCH[1]})) b=$((10#${BASH_REMATCH[2]}))
  c=$((10#${BASH_REMATCH[3]})) d=$((10#${BASH_REMATCH[4]}))
  (( a <= 255 && b <= 255 && c <= 255 && d <= 255 )) || return 1
  printf '%s\n' $(( (a << 24) | (b << 16) | (c << 8) | d ))
}

# Parse TUNNEL_NET (CIDR) and export TUNNEL_PREFIX for the awg0 templates.
# Both tunnel IPs must be usable host addresses inside the network. Call it
# after every source that may set TUNNEL_NET (env file, handoff).
validate_tunnel_net() {
  local net=${TUNNEL_NET%/*} prefix=${TUNNEL_NET##*/}
  [[ $TUNNEL_NET == */* && $prefix =~ ^[0-9]{1,2}$ ]] \
    || die "TUNNEL_NET must be CIDR like 172.16.0.0/24: $TUNNEL_NET"
  prefix=$((10#$prefix))
  (( prefix >= 8 && prefix <= 30 )) || die "TUNNEL_NET prefix must be /8../30: $TUNNEL_NET"
  local net_i mask ip v
  net_i=$(ipv4_to_int "$net") || die "TUNNEL_NET has an invalid address: $TUNNEL_NET"
  mask=$(( (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF ))
  (( (net_i & mask) == net_i )) \
    || die "TUNNEL_NET has host bits set: $TUNNEL_NET"
  for v in FOREIGN_TUNNEL_IP RU_TUNNEL_IP; do
    ip=$(ipv4_to_int "${!v}") || die "$v is not a valid IPv4 address: ${!v}"
    (( (ip & mask) == net_i )) || die "$v=${!v} is outside TUNNEL_NET=$TUNNEL_NET"
    (( ip != net_i && ip != (net_i | (~mask & 0xFFFFFFFF)) )) \
      || die "$v=${!v} is the network or broadcast address of $TUNNEL_NET"
  done
  [[ $FOREIGN_TUNNEL_IP != "$RU_TUNNEL_IP" ]] || die "tunnel IPs must differ"
  TUNNEL_PREFIX=$prefix
  export TUNNEL_PREFIX
}

check_tunnel_conflict() {
  if grep -Fq "$TUNNEL_NET" <<< "$(ip -4 route show)" && ! ip link show awg0 >/dev/null 2>&1; then
    warn "route for $TUNNEL_NET already exists; check Docker/libvirt/LAN conflicts"
  fi
}

port_udp_busy() {
  grep -qE "[:.]$1$" <<< "$(ss -lunp 2>/dev/null | awk '{print $4}')"
}

tunnel_peer_present() {
  [[ -n ${RU_PUBLIC_KEY:-} || -n ${FOREIGN_PUBLIC_KEY:-} ]]
}
