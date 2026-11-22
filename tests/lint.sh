#!/usr/bin/env bash
# lint.sh — lightweight repository checks (no server access required).

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"

FAIL=0
note() { printf '%s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; FAIL=1; }

# 1. Bash syntax
for f in scripts/*.sh tests/*.sh; do
  if bash -n "$f"; then
    note "ok   syntax $f"
  else
    fail "syntax $f"
  fi
done

# 2. shellcheck (errors only)
if command -v shellcheck >/dev/null 2>&1; then
  if shellcheck -S error scripts/*.sh tests/*.sh; then
    note "ok   shellcheck (errors)"
  else
    fail "shellcheck reported errors"
  fi
else
  note "skip shellcheck (not installed)"
fi

# 3. Templates are present and parameterised
for tpl in \
  config/foreign/awg0.conf.tpl \
  config/foreign/awg0-peer.tpl \
  config/foreign/xray-socks.json.tpl \
  config/ru/awg0.conf.tpl \
  config/ru/hiddify-checklist.txt.tpl; do
  if [[ -r $tpl ]]; then
    note "ok   template $tpl"
  else
    fail "missing template $tpl"
  fi
done

if ! grep -q '\${FOREIGN_TUNNEL_IP}' config/foreign/awg0.conf.tpl; then
  fail "config/foreign/awg0.conf.tpl does not reference \${FOREIGN_TUNNEL_IP}"
fi

# 4. No private keys or obvious secrets committed
if grep -RIl --exclude-dir=.git -E 'BEGIN [A-Z ]*PRIVATE KEY' . >/dev/null 2>&1; then
  fail "private key material found in the repository"
else
  note "ok   no private key material"
fi

if grep -RIl --exclude-dir=.git -E '^PrivateKey[[:space:]]*=[[:space:]]*[A-Za-z0-9+/=]{40,}' . >/dev/null 2>&1; then
  fail "rendered WireGuard/AmneziaWG private key found in the repository"
else
  note "ok   no rendered AmneziaWG private keys"
fi

# 5. .gitignore covers runtime secrets
for pattern in '.env' '*.key' '*handoff*.env'; do
  if grep -Fq -- "$pattern" .gitignore; then
    note "ok   .gitignore contains $pattern"
  else
    fail ".gitignore does not contain $pattern"
  fi
done

# 6. Generic naming: no FI-specific paths or terms
for p in scripts/fi-setup.sh scripts/env/fi.env.example config/fi; do
  [[ ! -e $p ]] || fail "legacy path exists: $p"
done
for p in scripts/foreign-setup.sh scripts/env/foreign.env.example config/foreign; do
  [[ -e $p ]] || fail "missing expected path: $p"
done

if [[ -x scripts/configure.sh ]]; then
  note "ok   scripts/configure.sh is executable"
else
  fail "scripts/configure.sh is not executable"
fi

if grep -RIn --exclude-dir=.git --exclude='lint.sh' -E \
  'FI_PUBLIC_IP|FI_TUNNEL_IP|FI_PUBLIC_KEY|FI_PRIVATE_KEY|FI_HANDOFF_FILE|belka-fi-|FI-Domains|FI-Telegram-IP|Финлянд|финск|fi-setup\.sh|config/fi|belka-vpn-fi\.log|--role fi|bootstrap\.sh fi' .; then
  fail "legacy FI names found (see lines above)"
else
  note "ok   no legacy FI names"
fi

# 7. Required IPs in examples must be empty (user supplies them)
for f in .env.example scripts/env/ru.env.example scripts/env/foreign.env.example; do
  if [[ ! -r $f ]]; then
    fail "missing env example: $f"
    continue
  fi
  if grep -qE '^(RU_PUBLIC_IP|FOREIGN_PUBLIC_IP)=.+$' "$f"; then
    fail "$f contains a non-empty public IP"
  else
    note "ok   $f has empty public IP fields"
  fi
done

# 8. No hardcoded public IPv4 outside the allowlist.
# This catches real server addresses without naming them in this file.
allowed_ipv4() {
  case "$1" in
    0.0.0.0|255.255.255.255|1.1.1.1|8.8.8.8) return 0 ;;
    10.*|127.*|169.254.*|192.168.*|100.64.*) return 0 ;;
    172.1[6-9].*|172.2[0-9].*|172.3[01].*) return 0 ;;
    192.0.2.*|198.51.100.*|203.0.113.*) return 0 ;;
    *) return 1 ;;
  esac
}

mapfile -t ipv4 < <(
  grep -RhoE --exclude-dir=.git '\b([0-9]{1,3}\.){3}[0-9]{1,3}\b' . 2>/dev/null | sort -u
)
for ip in "${ipv4[@]}"; do
  if ! allowed_ipv4 "$ip"; then
    fail "hardcoded public IPv4 outside allowlist: $ip"
  fi
done
if (( ${#ipv4[@]} == 0 )); then
  note "ok   no IPv4 literals found"
else
  note "ok   IPv4 literals checked (${#ipv4[@]} unique)"
fi

if (( FAIL > 0 )); then
  exit 1
fi
note "all checks passed"
