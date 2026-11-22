#!/usr/bin/env bash
# bootstrap.sh — fetch/update the belka-vpn repository on a server and run a stage.
#
# The repository is public, so no GitHub token is needed.
#
#   curl -fsSL https://raw.githubusercontent.com/gigabelka/belka-vpn/main/scripts/bootstrap.sh \
#     -o /root/bootstrap.sh
#   bash /root/bootstrap.sh foreign --env-file /etc/belka-vpn/foreign.env
#
# If GitHub is unreachable from the server, copy a checkout with tar/scp and run
# scripts/install-<role>.sh directly.

set -euo pipefail

REPO_URL=${BELKA_REPO_URL:-https://github.com/gigabelka/belka-vpn.git}
DEST=${BELKA_DEST:-/opt/belka-vpn}
ROLE=""
REF=main
ENV_FILE=""
PASSTHROUGH=()

usage() {
  cat <<'EOF'
Usage: bootstrap.sh <foreign|ru> [options] [-- installer-options]

Options:
  --ref REF         Branch, tag or commit to deploy (default: main)
  --env-file FILE   Env file (default: /etc/belka-vpn/<role>.env)
  -h, --help        Show this help

Examples:
  bootstrap.sh foreign --env-file /etc/belka-vpn/foreign.env
  bootstrap.sh ru --env-file /etc/belka-vpn/ru.env --handoff /root/belka-foreign-handoff.env
  bootstrap.sh foreign --ref <commit> --dry-run
EOF
}

while (( $# )); do
  case "$1" in
    foreign|ru) ROLE=$1; shift ;;
    --ref) REF=$2; shift 2 ;;
    --env-file) ENV_FILE=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    --) shift; PASSTHROUGH+=("$@"); break ;;
    *) PASSTHROUGH+=("$1"); shift ;;
  esac
done

if [[ -z $ROLE ]]; then
  usage >&2
  exit 1
fi

ENV_FILE=${ENV_FILE:-/etc/belka-vpn/${ROLE}.env}
LOG=/var/log/belka-vpn-bootstrap.log
install -d -m 755 /var/log
[[ -e $LOG ]] || install -m 600 /dev/null "$LOG"
chmod 600 "$LOG" 2>/dev/null || true
exec > >(tee -a "$LOG") 2>&1

if (( EUID != 0 )); then
  echo "run as root" >&2
  exit 1
fi

if [[ ! -r $ENV_FILE ]]; then
  echo "env file not found: $ENV_FILE" >&2
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends git curl ca-certificates >/dev/null

if [[ -e $DEST && ! -d $DEST/.git ]]; then
  echo "$DEST exists but is not a git repository; remove it or use tar/scp" >&2
  exit 1
fi

if [[ -d $DEST/.git ]]; then
  echo "updating $DEST to $REF"
  git -C "$DEST" fetch --depth 1 origin "$REF"
  git -C "$DEST" checkout -q FETCH_HEAD
else
  echo "cloning $REPO_URL -> $DEST"
  install -d -m 755 "$(dirname "$DEST")"
  git clone --depth 1 "$REPO_URL" "$DEST"
  git -C "$DEST" fetch --depth 1 origin "$REF"
  git -C "$DEST" checkout -q FETCH_HEAD
fi

INSTALLER="$DEST/scripts/install-${ROLE}.sh"
if [[ ! -r $INSTALLER ]]; then
  echo "installer not found: $INSTALLER" >&2
  echo "The deployed ref must contain scripts/install-${ROLE}.sh." >&2
  echo "If GitHub is unreachable, copy a checkout to $DEST with tar/scp and run:" >&2
  echo "  bash $DEST/scripts/install-${ROLE}.sh --env-file $ENV_FILE ${PASSTHROUGH[*]:-}" >&2
  exit 1
fi

echo "running $INSTALLER"
exec env ENV_FILE="$ENV_FILE" bash "$INSTALLER" "${PASSTHROUGH[@]}"
