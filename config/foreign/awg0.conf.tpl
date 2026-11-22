[Interface]
Address = ${FOREIGN_TUNNEL_IP}/24
ListenPort = ${AWG_PORT}
PrivateKey = ${FOREIGN_PRIVATE_KEY}
MTU = ${AWG_MTU}
${OBF_LINES}
