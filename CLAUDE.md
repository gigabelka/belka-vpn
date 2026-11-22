# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository. All answers must be in Russian.

## What this repository is

Idempotent Bash provisioning for a two-server split-tunnel VPN. Clients connect only to
the **RU** server (Hiddify Manager, VLESS + Reality, Xray core); selected traffic is
forwarded over an AmneziaWG tunnel to the **FOREIGN** server, which resolves domains and
egresses. Everything else leaves directly from Russia.

There is no application code, build system, package manager, or CI. The unit of work is
shell scripts under `scripts/` plus `envsubst` templates under `config/`. User-facing docs
(README, `docs/`, the Hiddify checklist) are Russian; scripts, comments, and this file are
English. Roles are always named exactly `ru` and `foreign`.

## Hard invariants

- **No real identifiers in the repo.** Public IPs, keys, passwords, tokens, and the
  Hiddify admin link must never be committed. `RU_PUBLIC_IP` / `FOREIGN_PUBLIC_IP` stay
  empty in `.env.example` and `scripts/env/*.env.example`. `tests/lint.sh` fails on
  hardcoded public IPv4 outside its allowlist and on private-key material.
- Never add `set -x`, and never print private keys or the Hiddify admin link.
- `load_handoff` deliberately rejects files containing secrets; handoffs carry public
  data only: public keys, obfuscation parameters, and the shared tunnel settings (public
  IPs, `AWG_PORT`, tunnel IPs/net, `SOCKS_PORT`, `AWG_MTU`). The FOREIGN handoff is
  sourced after `ru.env` and overrides those shared values; `install-ru.sh` restores the
  RU-owned `RU_PUBLIC_IP` and `REALITY_SNI` afterwards.
- RU firewall is owned by Hiddify Manager; only the FOREIGN server uses UFW.
  `configure.sh` always writes `ENABLE_UFW=0` to `ru.env`, though `install-ru.sh` never
  reads the flag. Do not add manual `ufw`/`iptables` rules on RU (fail2ban on RU is the
  one deliberate exception: it adds its own ban chains).

## Commands

Repo checks (the only local "tests"):

```bash
bash tests/lint.sh          # full suite; exits non-zero on any FAIL
bash -n scripts/lib.sh      # single-file syntax check
```

`tests/lint.sh` runs `bash -n` on all scripts, `shellcheck -S error` when installed,
required-template checks, secret scans, `.gitignore` coverage, the public-IPv4 allowlist,
and the ban on legacy `fi*` / Finnish names and on the old setup-script filenames.

Deployment (as root, Ubuntu 22.04/24.04, repo at `/opt/belka-vpn`):

```bash
bash scripts/configure.sh --role both --output-dir ~/belka-env  # writes ru.env + foreign.env
bash scripts/configure.sh --non-interactive --role both --output-dir ~/belka-env  # values from env
bash scripts/install-foreign.sh --env-file /etc/belka-vpn/foreign.env
bash scripts/install-ru.sh --keys-only --env-file /etc/belka-vpn/ru.env
bash scripts/install-foreign.sh --handoff /root/belka-ru-handoff.env
bash scripts/install-ru.sh --handoff /root/belka-foreign-handoff.env
bash scripts/verify.sh                    # on RU
bash scripts/verify.sh --role foreign     # on FOREIGN
bash scripts/bootstrap.sh foreign --env-file /etc/belka-vpn/foreign.env  # fetch ref + run stage
```

`install-foreign.sh` and `install-ru.sh` also accept `--dry-run` and `--uninstall`; both
paths still require an env file containing both public IPs, because the `:?` checks run
before argument dispatch. `install-foreign.sh --ru-pub KEY` supplies the RU public key
directly instead of via a handoff file. `bootstrap.sh` consumes the role word, `--ref`
(default `main`), `--env-file` and `-h`; other arguments, and everything after `--`, are
forwarded to the selected installer. It requires an existing env file and immediately
runs the installer.

Keep `configure.sh` output outside the repo: `tests/lint.sh` greps the whole working tree,
gitignored files included, so generated env files with real IPs make it fail.

## Architecture

```text
Hiddify app ──VLESS+Reality/443──► RU (Hiddify Manager / Xray)
                                      ├─ matched domains/geosites ──SOCKS5──► FOREIGN (Xray)
                                      │                                         │
                                      │                                    internet egress
                                      └─ everything else ──► Direct (RU)
RU 172.16.0.2 ══════ AmneziaWG (UDP/443) ══════ 172.16.0.1 FOREIGN
```

- `AllowedIPs` are `/32` on each side and the default route is never taken. FOREIGN runs
  SOCKS5 on `172.16.0.1:1080`, reachable only over the tunnel. **SOCKS, not NAT, is
  intentional**: domains resolve on the foreign side, so YouTube/Google avoid Russian GGC
  addresses and Anthropic sees a foreign IP; no `ip_forward`/NAT is needed.
- RU has two foreign outbounds plus a default, in this order: `FOREIGN-Domains`
  (explicit domains + geosite, **never `geoip:google`**), `FOREIGN-Telegram-IP`
  (`geoip:telegram`), then `Direct`. The split avoids `domainStrategy: IPOnDemand`
  resolving a Google domain through Russian DNS first.
- Hiddify Manager's **Common Proxy Core must be Xray** — `geosite:`/`geoip:` and SNI
  rewriting (`routeOnly=false`, sniffing `http/tls/quic`) only work there.
- Handoff exchange is circular and public-only: the first run of each role emits
  `/root/belka-<role>-handoff.env`; copy the other side's handoff in on the second pass.

## Code layout

- `scripts/lib.sh` — shared core, sourced not executed: logging (`log`, `warn`, `die`,
  `belka_init`), env/handoff loading, apt helpers, AmneziaWG install and key/obfuscation
  generation, `render_template`, `write_if_changed`, UFW/fail2ban, SSH hardening.
  Interactive output is written to fd 3 so it does not receive log formatting.
- `scripts/install-{foreign,ru}.sh` — per-role installation and orchestration. `install-ru.sh` installs
  Hiddify Manager **before** bringing up `awg0` so the Hiddify installer cannot touch the
  tunnel; it then writes `/root/belka-ru-manual-checklist.txt`.
- `scripts/verify.sh` — live checks: tunnel handshake age (`<180 s`) and transfer, SOCKS
  binding (must not listen on `0.0.0.0`), egress IP vs `FOREIGN_PUBLIC_IP` (a mismatch is
  only a warning), YouTube `generate_204` returns 204, `api.anthropic.com` must not
  return 403, Hiddify services running.
- `config/` — `.tpl` files rendered with `envsubst`; only exported variables are
  substituted, and **unset variables silently become empty**. `config/rules/*` are
  written to `/root/belka-foreign-{domains,geosites,telegram-ip}.txt` on RU with comments
  and blank lines stripped (Hiddify rejects them), for the manual Hiddify setup.

## Idempotency and state

`render_template` and `write_if_changed` compare against the destination with `cmp` and
set `TEMPLATE_CHANGED`; services restart only when a config changed or the unit is
inactive. Keys and AmneziaWG obfuscation are reused on reruns; rotation is opt-in with
`ROTATE_KEYS=1` / `ROTATE_OBFUSCATION=1`.

- Env files: `/etc/belka-vpn/{ru,foreign}.env`, mode 600. Defaults live in
  `apply_defaults()` in `lib.sh`; `configure.sh` contains its own copies of the same
  defaults (environment overrides them) and writes the role-specific flags.
  `.env.example` is a reference only; no script reads `.env`.
- Server state: keys in `/etc/amnezia/amneziawg/keys`, obfuscation in
  `/etc/belka-vpn/foreign-obfuscation.env`, Xray in `/usr/local/etc/xray`, Hiddify in
  `/opt/hiddify-manager`, logs in `/var/log/belka-vpn-{ru,foreign,verify,bootstrap}.log`.
- Modes: 600 for env files, handoffs, keys, logs, the checklist, and `awg0.conf` (it
  holds the private key); 644 for other system configs; 700 for `/etc/belka-vpn` and the
  key directory. Scripts are committed executable (`100755`); `tests/lint.sh` checks it.

## Operational gotchas

- Hiddify Manager overwrites its generated Xray config on "Apply now". Change routing only
  through the panel UI; never edit its generated files.
- Newer sing-box cores pulled by the Hiddify installer abort on Hiddify's implicit default
  HTTP client for remote rule-sets (`status=1` every 5 s). `install-ru.sh` installs a
  `hiddify-core.service` drop-in with `ENABLE_DEPRECATED_IMPLICIT_DEFAULT_HTTP_CLIENT=true`;
  without it the core crash-loops. Remove the drop-in once Hiddify emits the new config form.
- `Jmax` must not exceed MTU (start at 1280; drop to 1240 on fragmentation). Obfuscation
  parameters must match on both peers, and after rotation **both** handoffs must be
  re-exchanged or the handshake stops. `AWG_ENABLE_S3S4=0` is the safe default.
- Hiddify blocks QUIC/443 server-side, so YouTube/Google fall back to TCP. Claude Code
  does not support SOCKS; desktop clients need TUN mode, and WSL2/Docker may bypass TUN.
- Hiddify Manager removal is intentionally manual and destructive; `install-ru.sh
  --uninstall` leaves it installed.
- Deeper detail: `docs/architecture.md` (rationale), `docs/runbook.md` (deployment
  order), `docs/troubleshooting.md` (diagnosis), and the Russian README quick start.
