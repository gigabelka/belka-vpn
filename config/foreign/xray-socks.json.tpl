{
  "log": {
    "loglevel": "warning",
    "access": "none"
  },
  "dns": {
    "servers": ["1.1.1.1", "8.8.8.8"]
  },
  "inbounds": [
    {
      "tag": "socks-foreign",
      "listen": "${FOREIGN_TUNNEL_IP}",
      "port": ${SOCKS_PORT},
      "protocol": "socks",
      "settings": {
        "auth": "noauth",
        "udp": true
      },
      "sniffing": {
        "enabled": false
      }
    }
  ],
  "outbounds": [
    {
      "tag": "direct",
      "protocol": "freedom",
      "settings": {
        "domainStrategy": "UseIPv4"
      }
    },
    {
      "tag": "block",
      "protocol": "blackhole",
      "settings": {}
    }
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      {
        "type": "field",
        "ip": [
          "127.0.0.0/8",
          "10.0.0.0/8",
          "172.16.0.0/12",
          "192.168.0.0/16",
          "169.254.0.0/16",
          "100.64.0.0/10"
        ],
        "outboundTag": "block"
      }
    ]
  }
}
