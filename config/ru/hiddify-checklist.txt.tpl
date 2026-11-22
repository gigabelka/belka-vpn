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
   - Protocols: VLESS only (disable Hysteria2/TUIC/Shadowsocks/etc.)
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
      Domestic sites of Iran/Russia: OFF
      Rule-sets (hiddify-core): empty (Common Proxy Core = Xray)
      *** Do NOT add geoip:google here. ***

   B) Name: FOREIGN-Telegram-IP
      Host: ${FOREIGN_TUNNEL_IP}
      Port: ${SOCKS_PORT}
      Geosites/GeoIPs (xray): only geoip:telegram (see /root/belka-foreign-telegram-ip.txt)
      Sites: empty

   Order (top to bottom):
      1. FOREIGN-Domains
      2. FOREIGN-Telegram-IP
      3. Direct  (last, enabled, default)
   Disable WARP (its openai rules can intercept AI traffic).
   Block: leave without lists.

5) Actions -> Apply now

6) Verify the generated Xray config
   - sniffing enabled (http/tls/quic), routeOnly = false
   - two SOCKS outbounds on ${FOREIGN_TUNNEL_IP}:${SOCKS_PORT}
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
   - On desktop use TUN/VPN mode (Claude Code does not support SOCKS)

9) Tests
   - youtube.com, google.com, claude.ai -> through FOREIGN
   - gemini.google.com opens without "not available in your country"
     (signed out; an account with RU country stays blocked by account country)
   - Russian sites -> Direct (RU IP)
   - api.anthropic.com returns 400/401/404/405, not 403 region
   - Telegram messages work (calls may use UDP; verify separately)
