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
  hardcoded public IPv4 outside its allowlist and on private-key material. The sole
  exception is `config/client/hiddify-allowedips.txt`: it is a client routing list (the
  inverse of the Direct/bypass list), not a server identifier. `tests/lint.sh` excludes
  exactly that path from the IPv4 check and validates separately that it is CIDR-only.
- Never add `set -x`, and never print private keys or the Hiddify admin link.
- `load_handoff` rejects files containing secrets and parses handoffs as `KEY=VALUE`
  lines against a per-role allowlist; it never sources them. Handoffs carry public
  data only: public keys, obfuscation parameters, and the shared tunnel settings (public
  IPs, `AWG_PORT`, tunnel IPs/net, `SOCKS_PORT`, `AWG_MTU`). The FOREIGN handoff is
  parsed after `ru.env` and overrides those shared values; `install-ru.sh` restores the
  RU-owned `RU_PUBLIC_IP` and `REALITY_SNI` afterwards.
- RU firewall is owned by Hiddify Manager; only the FOREIGN server uses UFW.
  `configure.sh` always writes `ENABLE_UFW=0` to `ru.env`, though `install-ru.sh` never
  reads the flag. Do not add manual `ufw`/`iptables` rules on RU; removing a stale rule
  Hiddify's generator no longer emits is allowed (procedure in `docs/troubleshooting.md`:
  its script only appends and re-saves `/etc/iptables/rules.v4`). fail2ban on RU uses
  `banaction = route` (bans are `ip route add unreachable <ip>`), so it never touches the
  firewall; FOREIGN keeps the default iptables ban action.

## Commands

Repo checks (the only local "tests"):

```bash
bash tests/lint.sh          # full suite; exits non-zero on any FAIL
bash -n scripts/lib.sh      # single-file syntax check
```

`tests/lint.sh` runs `bash -n` on all scripts, `shellcheck -S error` when installed,
required-template checks, secret scans, `.gitignore` coverage, the public-IPv4 allowlist,
and the ban on legacy `fi*` / Finnish names, on the old setup-script filenames, and on any
reference to the removed hosting provider (pattern in check 6b of `tests/lint.sh`). The
IPv4 allowlist scan exempts only `config/client/hiddify-allowedips.txt` (a routing list);
that file is checked separately to contain nothing but CIDR lines.
Content scans cover only git-visible files (tracked plus untracked-not-ignored), so
gitignored runtime files such as `env/` or `.env` are skipped. In a copy without `.git`
(the tar copy on the servers) they scan every file.

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

`install-foreign.sh` and `install-ru.sh` also accept `--dry-run` and `--uninstall`
(mutually exclusive; `install-ru.sh` also rejects `--keys-only` with either); both
paths still require an env file containing both public IPs, because the `:?` checks run
before argument dispatch. `install-foreign.sh --ru-pub KEY` supplies the RU public key
directly instead of via a handoff file. `bootstrap.sh` consumes the role word, `--ref`
(default `main`), `--env-file` and `-h`; other arguments, and everything after `--`, are
forwarded to the selected installer. It requires an existing env file and immediately
runs the installer; with `--dry-run` it skips apt-get and git fetch/checkout, requires
an existing checkout, and forwards the flag.
Both installers validate the effective handoff and tunnel settings during a dry run.
FOREIGN still accepts a first pass without a handoff. Installers save a supplied
handoff after activating the tunnel (and, on FOREIGN, after SOCKS readiness).

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
  addresses and Anthropic/OpenAI see a foreign IP; no `ip_forward`/NAT is needed.
- `FOREIGN_EGRESS_IPV4` (FOREIGN only, default empty) pins Xray's `direct` freedom
  outbound to a source address with `sendThrough`; empty leaves the system default. A
  non-empty value must be an IPv4 assigned to a local interface (the real run dies
  otherwise; a dry run only warns) and is applied to all direct egress. It is
  FOREIGN-local and not part of the handoff. `verify.sh` checks the rendered value and
  the SOCKS egress; `--google-only [--expect-country CC]` probes Google's `x-country`,
  and `--expect-egress IP` requires the given public IPv4 on either role. RU uses
  `FOREIGN_PUBLIC_IP` as a warning-only default. With `GOOGLE_IPV6_EGRESS=1`, Google hosts use `google-v6` and
  ignore `sendThrough`; YouTube still uses `direct`.
- RU has three foreign outbounds plus a default, in this order: `FOREIGN-Domains`
  (explicit domains + geosite, **never `geoip:google`**), `FOREIGN-Google-IP` (only
  `geoip:google`), `FOREIGN-Telegram-IP` (`geoip:telegram`), then `Direct`. The split
  avoids `domainStrategy: IPOnDemand` resolving a Google domain through Russian DNS
  first: domains match before any IP rule, and with `routeOnly=false` FOREIGN still
  receives the domain. `FOREIGN-Google-IP` catches Google connections with no
  sniffable domain so a signed-in session never mixes a RU exit IP in. `verify.sh`
  fails if `geoip:google` is missing, shares a rule with domains, or sits above the
  domain rule.
- `google.com`/`googleapis.com` cover subdomains, but Google AI hosts in the
  `.google`, `.goog` and `.studio` zones (`gemini.google`, `ai.studio`,
  `generativeai.google`, `antigravity.google`, …) are listed explicitly in
  `config/rules/foreign-domains.txt`; `geosite:google` does not cover them.
  `verify.sh` checks that coverage. Signed-in Gemini is gated by Google's
  exit-IP country and the account country, not by routing.
- Services blocked in Russia are listed explicitly in
  `config/rules/foreign-domains.txt` because no geosite tag is assumed for them:
  `rutracker.org`/`rutracker.net` with static host `rutracker.cc` (CSS/JS/images;
  without it the forum hangs unstyled) and announce host `t-ru.org`, `rutor.info` with
  mirrors and `dler.cc` (serves `.torrent`), and `instagram.com` with its CDN
  (`cdninstagram.com`, `fbcdn.net`). `verify.sh` checks the three main hosts.
- OpenAI/ChatGPT/Codex hosts are listed explicitly in
  `config/rules/foreign-domains.txt`: `openai.com` (API, `api.openai.com`,
  `auth.openai.com`), `chatgpt.com` (web and `backend-api`), `oaistatic.com` /
  `oaiusercontent.com` (assets/files), `chatgpt.livekit.cloud` (voice) and
  `sora.com`; `geosite:openai` is a fallback because geo files can lag.
  `verify.sh` checks `openai.com` and `chatgpt.com` separately: it warns when
  coverage is geosite-only and fails when the explicit list is partial and no
  geosite fallback exists.
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
- `scripts/verify.sh` — live checks: tunnel handshake age (`<180 s`) and transfer,
  FOREIGN SOCKS binding, egress and expected UFW rules, RU `hiddify-xray` and TCP/443
  listener, YouTube `generate_204` returns 204, `api.anthropic.com` and
  `api.openai.com` must not return 403. The VLESS client path needs a client check.
- `config/` — `.tpl` files rendered with `envsubst`; only exported variables are
  substituted, and **unset variables silently become empty**. `config/rules/*` are
  written to `/root/belka-foreign-{domains,geosites,telegram-ip}.txt` on RU with comments
  and blank lines stripped (Hiddify rejects them), for the manual Hiddify setup.
- `config/client/` — Hiddify app routing data, documentation-only (no script reads it):
  `hiddify-bypass.txt.example` is the Direct/bypass template, and
  `hiddify-allowedips.txt` is its canonical inverse (199 CIDRs). Per
  `docs/hiddify-client.md`, the Hiddify app gets two IP-CIDR rules from that file: the
  12 header ranges with outbound Direct on top, the 199 body with outbound Proxy below;
  clients that take `AllowedIPs` literally get the 199 CIDRs in that field instead. The
  Hiddify app is configured through its GUI; `route_rule.proto` (binary protobuf) and
  `configs/*.json` (keys) are never committed. The only manual edit of `route_rule.proto`
  is the documented, backup-first patch in `docs/hiddify-client.md` §8, done with the
  Hiddify UI closed.

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
  key directory. Scripts are committed executable (`100755`); `tests/lint.sh` checks only
  `scripts/configure.sh`, so keep the others executable by hand.

## Operational gotchas

- Hiddify Manager overwrites its generated Xray config on "Apply now". Change routing only
  through the panel UI; never edit its generated files.
- Hiddify 14.2 generates the REALITY-termination inbounds (`reality terminator …`) with no
  `sniffing` block (`xray/server/presets/reality_termination.j2`). A client that sends
  destination IPs (Hiddify app TUN with Balance/round-robin over the subscription's
  configs) then loses domain matching on those connections: domain-listed sites
  (rutracker, rutor, instagram) go Direct, while `geoip`-based Google/Telegram still work.
  `install-ru.sh` (`apply_hiddify_reality_sniffing`) stores a built-in-proxy
  `server_config` override with `sniffing (http/tls/quic), routeOnly=false`; `verify.sh`
  requires enabled `http/tls/quic` sniffing with `routeOnly=false` on every VLESS
  inbound and fails when there are none. Never add sniffing by editing
  `generated/xray.json` or site-packages: Hiddify regenerates/overwrites both.
  `hiddify sync-configs` only rewrites `generated/xray.json`; restart `hiddify-xray`
  afterwards to load it.
- RU's Hiddify subscription is deliberately Xray-only. All custom proxies with
  `server_core=hiddify_core` (the `HC` configs) are disabled, and
  `vmess/grpc/httpupgrade/xhttp/quic/h2` are off; only `vless`, `reality`, `tcp` remain.
  hiddify-core routing has no `geoip:telegram`, so an HC config sends bare-IP Telegram
  Direct from RU, where TCP to Telegram is blocked. Verify the subscription has no `HC`
  and that `generated/xray.json` still routes `geoip:telegram` to a SOCKS outbound. The
  client app refreshes its profile on its own interval; never change client settings.
- Newer sing-box cores pulled by the Hiddify installer abort on Hiddify's implicit default
  HTTP client for remote rule-sets (`status=1` every 5 s). `install-ru.sh` installs a
  `hiddify-core.service` drop-in with `ENABLE_DEPRECATED_IMPLICIT_DEFAULT_HTTP_CLIENT=true`;
  without it the core crash-loops. Remove the drop-in once Hiddify emits the new config form.
- `Jmax` must not exceed MTU. The live RU↔FOREIGN tunnel runs at `AWG_MTU=1240`
  (lowered from 1280 after large-packet loss and jitter; 1200-byte payloads are clean,
  exact-MTU 1212 can spike). Obfuscation parameters must match on both peers, and after
  rotation **both** handoffs must be re-exchanged or the handshake stops.
  `AWG_ENABLE_S3S4=0` is the safe default.
- Google's own geo database can place the FOREIGN IPv4 in Russia while ipinfo/RIPE say
  otherwise; signed-in Gemini is then blocked. Check `x-country` via the SOCKS
  (`google_country` in `lib.sh`, also in `verify.sh`). `GOOGLE_IPV6_EGRESS=1` on FOREIGN
  sends `geosite:google` out over IPv6 (`ForceIPv6`; native, or an HE 6in4 tunnel via
  `HE_SERVER_IPV4`/`HE_CLIENT_IPV6`); YouTube stays on IPv4. Off by default, and the
  rendered Xray config is then unchanged.
- Hiddify blocks QUIC/443 server-side, so YouTube/Google fall back to TCP. Claude Code
  and Codex CLI do not support SOCKS; desktop clients need TUN mode, and WSL2/Docker may
  bypass TUN.
- Hiddify app **Strict Route** blocks DNS (port 53) to resolvers outside the tunnel,
  including a corporate NRPT server reached over ZeroTier. The site stays reachable by IP
  (`curl --resolve` works) while names stop resolving; check
  `Test-NetConnection <corp-DNS> -Port 80` (True) vs `-Port 53` (False). Keep Strict
  Route off when a corporate NRPT zone is needed; that zone's DNS then goes direct.
- Hiddify Manager removal is intentionally manual and destructive; `install-ru.sh
  --uninstall` leaves it installed.
- Hiddify reruns its installer on every RU boot and auto-updates nightly; the installer
  recreates `/etc/sysctl.d/hiddify.conf` with `ip_forward = 1`. `install-ru.sh`
  (`configure_ip_forwarding`) overrides it with `zz-belka-no-forward.conf`, which must sort
  after `hiddify.conf` and `wg.conf` (last value wins). The kernel sets
  `accept_redirects` to the inverse of forwarding, so the same file zeroes redirects via
  `conf.*` globs (all/default alone miss existing interfaces). `RU_IP_FORWARD=1` removes
  the override for Hiddify's WireGuard/WARP.
- `harden_ssh` writes `sshd_config.d/01-belka-hardening.conf`: sshd keeps the first value
  per keyword, so the file must sort before `50-cloud-init.conf`.
- In Hiddify, `http_proxy_enable` ("Allow HTTP Connection") gates every non-TLS config
  (port 80 and raw VLESS/VMess on random ports), not an HTTP proxy. Configs tagged `HC` are
  served by hiddify-core (sing-box), whose routing gets only the domain list: no
  `geosite`/`geoip`, which is why `config/rules/foreign-domains.txt` lists Google/YouTube
  domains explicitly. After disabling a protocol, clients on the old subscription show
  `not trojan protocol` rejects until they update it.
- SSH to FOREIGN from a PC on the VPN egresses via the RU IP and trips `ufw limit 22/tcp`
  ("Connection closed"), not fail2ban. Batch commands per session, or jump through RU
  over the tunnel: `ssh -J root@<RU_PUBLIC_IP> root@172.16.0.1`.
- Deploying from Windows: `.gitattributes` sets LF for text files. Build an archive from
  the commit and check it for CR bytes using the Python command in the runbook.
- Deeper detail: `docs/architecture.md` (rationale), `docs/runbook.md` (deployment
  order), `docs/hiddify-client.md` (Hiddify app setup, Direct and Proxy rules, AllowedIPs,
  strict route), `docs/troubleshooting.md` (diagnosis), and the Russian README quick
  start.
