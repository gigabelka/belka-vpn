[Interface]
Address = ${FOREIGN_TUNNEL_IP}/${TUNNEL_PREFIX}
ListenPort = ${AWG_PORT}
PrivateKey = ${FOREIGN_PRIVATE_KEY}
MTU = ${AWG_MTU}
${OBF_LINES}
