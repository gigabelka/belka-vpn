[Interface]
Address = ${RU_TUNNEL_IP}/${TUNNEL_PREFIX}
PrivateKey = ${RU_PRIVATE_KEY}
MTU = ${AWG_MTU}
${OBF_LINES}

[Peer]
PublicKey = ${FOREIGN_PUBLIC_KEY}
Endpoint = ${FOREIGN_PUBLIC_IP}:${AWG_PORT}
AllowedIPs = ${FOREIGN_TUNNEL_IP}/32
PersistentKeepalive = 25
