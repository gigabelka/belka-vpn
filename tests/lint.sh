#!/usr/bin/env bash
# lint.sh — lightweight repository checks (no server access required).

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"

FAIL=0
note() { printf '%s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; FAIL=1; }

# Files the content scans look at: tracked plus untracked-but-not-ignored, so
# gitignored runtime files (generated env/, .env, handoffs) never trip the
# checks. Without git metadata (tar copy on a server) fall back to every file.
SCAN_FILES=()
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  while IFS= read -r -d '' f; do
    [[ -f $f ]] && SCAN_FILES+=("$f")
  done < <(git ls-files -z --cached --others --exclude-standard)
  note "ok   scanning ${#SCAN_FILES[@]} git-visible files (ignored files skipped)"
else
  while IFS= read -r -d '' f; do
    SCAN_FILES+=("$f")
  done < <(find . -path ./.git -prune -o -type f -print0)
  note "note no git metadata: scanning all ${#SCAN_FILES[@]} files"
fi

# grep over SCAN_FILES; extra grep options come first.
scan_grep() {
  (( ${#SCAN_FILES[@]} )) || return 1
  grep -I "$@" -- "${SCAN_FILES[@]}"
}

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

# 2b. No `cmd | grep -q` under pipefail: grep -q exits on the first match, the
# producer gets SIGPIPE and the pipeline reports failure at random. Capture the
# output first: grep -q PATTERN <<< "$(cmd)".
if grep -nE '\|[[:space:]]*grep[[:space:]]+-[A-Za-z]*q' scripts/*.sh tests/*.sh \
    | grep -v '^tests/lint\.sh:'; then
  fail "pipe into grep -q found (see lines above); use grep -q ... <<< \"\$(cmd)\""
else
  note "ok   no pipes into grep -q"
fi

# 3. Templates are present and parameterised
for tpl in \
  config/foreign/awg0.conf.tpl \
  config/foreign/awg0-peer.tpl \
  config/foreign/xray-socks.json.tpl \
  config/foreign/he-ipv6.service.tpl \
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

# The awg0 Address mask must follow TUNNEL_NET, not a hardcoded prefix.
for tpl in config/foreign/awg0.conf.tpl config/ru/awg0.conf.tpl; do
  if grep -Eq '^Address = \$\{[A-Z_]+_TUNNEL_IP\}/\$\{TUNNEL_PREFIX\}$' "$tpl"; then
    note "ok   $tpl Address uses \${TUNNEL_PREFIX}"
  else
    fail "$tpl Address must be \${..._TUNNEL_IP}/\${TUNNEL_PREFIX}"
  fi
done

# 4. No private keys or obvious secrets committed
if scan_grep -l -E 'BEGIN [A-Z ]*PRIVATE KEY' >/dev/null 2>&1; then
  fail "private key material found in the repository"
else
  note "ok   no private key material"
fi

if scan_grep -l -E '^PrivateKey[[:space:]]*=[[:space:]]*[A-Za-z0-9+/=]{40,}' >/dev/null 2>&1; then
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
for p in scripts/fi-setup.sh scripts/foreign-setup.sh scripts/ru-setup.sh scripts/env/fi.env.example config/fi; do
  [[ ! -e $p ]] || fail "legacy path exists: $p"
done
for p in scripts/install-foreign.sh scripts/install-ru.sh scripts/env/foreign.env.example config/foreign; do
  [[ -e $p ]] || fail "missing expected path: $p"
done

if [[ -x scripts/configure.sh ]]; then
  note "ok   scripts/configure.sh is executable"
else
  fail "scripts/configure.sh is not executable"
fi

if scan_grep -n --exclude='lint.sh' -E \
  'FI_PUBLIC_IP|FI_TUNNEL_IP|FI_PUBLIC_KEY|FI_PRIVATE_KEY|FI_HANDOFF_FILE|belka-fi-|FI-Domains|FI-Telegram-IP|Финлянд|финск|fi-setup\.sh|foreign-setup\.sh|ru-setup\.sh|config/fi|belka-vpn-fi\.log|--role fi|bootstrap\.sh fi|socks-fi\b'; then
  fail "legacy FI names found (see lines above)"
else
  note "ok   no legacy FI names"
fi

# 6b. No references to the hosting provider HOSTKEY (removed from the project).
if scan_grep -n -i --exclude='lint.sh' -E 'host[-_ ]?key|[хХ]ост-?кей|ХОСТ-?КЕЙ'; then
  fail "hostkey references found (see lines above)"
else
  note "ok   no hostkey references"
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
#
# Exception: config/client/hiddify-allowedips.txt is a routing list (the
# inverse of the client Direct list), not an identifier. It is excluded from
# the allowlist scan below and validated separately in 8b as CIDR-only.
CLIENT_CIDR_FILE=config/client/hiddify-allowedips.txt

allowed_ipv4() {
  case "$1" in
    0.0.0.0|255.255.255.255|1.1.1.1|8.8.8.8) return 0 ;;
    10.*|127.*|169.254.*|192.168.*) return 0 ;;
    # 100.64.0.0/10 (CGNAT): second octet 64..127
    100.6[4-9].*|100.[7-9][0-9].*|100.1[01][0-9].*|100.12[0-7].*) return 0 ;;
    172.1[6-9].*|172.2[0-9].*|172.3[01].*) return 0 ;;
    192.0.2.*|198.51.100.*|203.0.113.*) return 0 ;;
    *) return 1 ;;
  esac
}

mapfile -t ipv4 < <(
  scan_grep -hoE --exclude='hiddify-allowedips.txt' \
    '\b([0-9]{1,3}\.){3}[0-9]{1,3}\b' 2>/dev/null | sort -u
)
ipv4_bad=0
for ip in "${ipv4[@]}"; do
  if ! allowed_ipv4 "$ip"; then
    fail "hardcoded public IPv4 outside allowlist: $ip"
    ipv4_bad=1
  fi
done
if (( ${#ipv4[@]} == 0 )); then
  note "ok   no IPv4 literals found"
elif (( ! ipv4_bad )); then
  note "ok   IPv4 literals checked (${#ipv4[@]} unique)"
fi

# 8b. The one exempted client list must be a pure IPv4 CIDR list.
octet='(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])'
cidr_re="^${octet}\.${octet}\.${octet}\.${octet}/(3[0-2]|[12][0-9]|[0-9])$"
if [[ ! -r $CLIENT_CIDR_FILE ]]; then
  fail "missing $CLIENT_CIDR_FILE"
else
  cidr_count=$(grep -cE "$cidr_re" "$CLIENT_CIDR_FILE" || true)
  bad=$(grep -vE '^[[:space:]]*(#|$)' "$CLIENT_CIDR_FILE" | grep -vE "$cidr_re" || true)
  if [[ -n $bad ]]; then
    fail "$CLIENT_CIDR_FILE has lines that are not IPv4 CIDRs:"
    printf '%s\n' "$bad"
  elif (( cidr_count == 0 )); then
    fail "$CLIENT_CIDR_FILE contains no IPv4 CIDRs"
  else
    note "ok   $CLIENT_CIDR_FILE is a pure IPv4 CIDR list ($cidr_count entries)"
  fi
fi

if (( FAIL > 0 )); then
  exit 1
fi
note "all checks passed"
