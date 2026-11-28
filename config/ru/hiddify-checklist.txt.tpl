Hiddify Manager — manual checklist (belka-vpn)
==============================================
Server: RU ${RU_PUBLIC_IP}
FOREIGN SOCKS via AmneziaWG: ${FOREIGN_TUNNEL_IP}:${SOCKS_PORT}
Reality SNI candidate: ${REALITY_SNI}

0) Admin link
   Run on the server:  hiddify admin
   The link is a secret; do not paste it into chat or git.

1) Quick setup
   - Country: Russia
   - Protocols: VLESS only, TLS/Reality on 443 (disable Hysteria2/TUIC/
     Shadowsocks/SSH/WireGuard/Mieru/Snell/AnyTLS/Naive/etc.; each opens its
     own public port)
   - Allow HTTP Connection: OFF. Despite the name it is not an HTTP proxy: it
     enables every config without TLS (port 80 and raw VLESS/VMess on random
     ports). Port 80 itself stays open for certificates.
   - Disabling a protocol after clients connected: they must update the
     subscription; until then Xray logs "not trojan protocol" rejects.
   - Domains: no domain -> use the server IP (self-signed)
   NOTE: hiddify-core runs with a compatibility environment. Until you finish
   this checklist and press Apply, its default non-VLESS inbounds may be
   listening. Configure and Apply promptly.

2) Settings -> Settings -> Advanced
   - Common Proxy Core = Xray          <-- REQUIRED for geosite/geoip and SNI rewrite
   - Only IPv4 = ON
   - DNS Server = 1.1.1.1 (Cloudflare)
   - Firewall: Hiddify Manager owns the RU firewall. Keep its switch OFF until
     AmneziaWG and verify.sh pass, then enable it here if wanted.
     Do not add manual ufw/iptables rules.

3) Reality
   - Enable VLESS + Reality on TCP/443
   - Pick a destination/SNI with TLS1.3 + HTTP/2 reachable from Russia (Scanner)
   - Do not use Google/YouTube as the SNI
   - Do not change Reality keys/short IDs after users connect

4) Outbounds -> Add -> Socks
   A) Name: FOREIGN-Domains
      Host: ${FOREIGN_TUNNEL_IP}
      Port: ${SOCKS_PORT}
      Username/Password: empty
      Sites: copy /root/belka-foreign-domains.txt
      Geosites/GeoIPs (xray): copy /root/belka-foreign-geosites.txt
      (both /root lists are paste-ready: no comments, no blank lines)
      google.com (domain match) covers gemini.google.com and aistudio.google.com;
      an exact full:google.com does not (verify.sh warns about it)
      google.com and geosite:google do NOT cover .google-TLD hosts
      (gemini.google, ai.studio, generativeai.google, jules.google, flow.google,
      opal.google, notebook.google, antigravity.google), antigravity-unleash.goog
      or withgoogle.com. Keep the explicit lines from the /root list, or add
      geosite:google-gemini (requires fresh geo files).
      Signed-in Gemini needs one exit IP for all Google hosts: a host left on
      Direct makes Google see mixed IPs and can show "not supported in your
      country" even when incognito works.
      OpenAI/ChatGPT/Codex: openai.com (API/platform), chatgpt.com (web and
      backend-api), oaistatic.com/oaiusercontent.com (assets/files),
      chatgpt.livekit.cloud (ChatGPT voice) and sora.com are in the /root list;
      geosite:openai is a fallback only (geo files can lag). Codex CLI does
      not support SOCKS: use TUN on desktop.
      Domestic sites of Iran/Russia: OFF
      Rule-sets (hiddify-core): empty (Common Proxy Core = Xray)
      *** Do NOT add geoip:google here (it has its own outbound B). ***

   B) Name: FOREIGN-Google-IP
      Host: ${FOREIGN_TUNNEL_IP}
      Port: ${SOCKS_PORT}
      Geosites/GeoIPs (xray): only geoip:google (see /root/belka-foreign-google-ip.txt)
      Sites: empty
      Catches Google connections without a sniffable domain, so a signed-in
      session never mixes a RU exit IP with the FOREIGN one. Must stay BELOW
      FOREIGN-Domains: Google domains have to match by domain first.

   C) Name: FOREIGN-Telegram-IP
      Host: ${FOREIGN_TUNNEL_IP}
      Port: ${SOCKS_PORT}
      Geosites/GeoIPs (xray): only geoip:telegram (see /root/belka-foreign-telegram-ip.txt)
      Sites: empty

   Order (top to bottom):
      1. FOREIGN-Domains
      2. FOREIGN-Google-IP
      3. FOREIGN-Telegram-IP
      4. Direct  (last, enabled, default)
   Disable WARP (its openai rules can intercept AI traffic).
   Block: leave without lists, and Domestic sites of Iran/Russia OFF
   (otherwise geoip:ru and domain:ru go to blackhole and Russian sites break).

5) Actions -> Apply now

6) Verify the generated Xray config
   - sniffing enabled (http/tls/quic), routeOnly = false on ALL VLESS inbounds,
     including "reality terminator" (install-ru.sh applies the built-in-proxy override)
   - three SOCKS outbounds on ${FOREIGN_TUNNEL_IP}:${SOCKS_PORT}
   - geoip:google only in its own rule, below the domain rule
   - Direct is last/default
   - no unknown geosite tags (xray -test must pass)
   If an unknown tag breaks Xray, remove it from the list and keep the
   explicit domains from /root/belka-foreign-domains.txt.

7) Users -> Add user -> copy the subscription or vless:// link

8) Hiddify app on the client
   - Default outbound: Proxy
   - Bypass LAN: ON
   - Region: Other (do not use Russia; splitting is server-side)
   - IPv6: Disabled
   - DNS: remote 1.1.1.1 via proxy
   - Resolve Destination: OFF
   - Browser: ECH and DoH disabled (otherwise Xray cannot see SNI)
   - On desktop use TUN/VPN mode (Claude Code and Codex CLI do not support SOCKS)

9) Tests
   - youtube.com, google.com, claude.ai, chatgpt.com -> through FOREIGN
   - rutracker.org (with styles), rutor.info, instagram.com -> through FOREIGN (media loads;
     torrent announces reach the tracker)
   - rutracker.org must open 10/10 times; "every other request" means a VLESS inbound
     without sniffing - run scripts/verify.sh
   - gemini.google.com opens without "not available in your country"
     (signed out; an account with RU country stays blocked by account country)
     Signed-in "not supported in your country" while incognito works is not a
     routing bug first: check Google's country for the exit IP and the account
     country before touching the rules (docs/troubleshooting.md).
       curl -4 -sS -o /dev/null -D - --socks5-hostname ${FOREIGN_TUNNEL_IP}:${SOCKS_PORT} \
         'https://clientservices.googleapis.com/chrome-variations/seed?osname=win&channel=stable&milestone=140' \
         | grep -i '^x-country'
       Account country: footer of https://policies.google.com/u/0/terms
   - Russian sites -> Direct (RU IP)
   - api.anthropic.com returns 400/401/404/405, not 403 region
   - api.openai.com/v1/models returns 401 without a key, not 403 region
   - Telegram messages work (calls may use UDP; verify separately)
