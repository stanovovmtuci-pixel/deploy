{
  "log": {
    "loglevel": "info",
    "access": "{{XRAY_LOG_DIR}}/access.log",
    "error": "{{XRAY_LOG_DIR}}/error.log"
  },
  "inbounds": [
    {
      "tag": "{{XRAY_INBOUND_TAG}}",
      "listen": "{{XRAY_INBOUND_LISTEN}}",
      "port": {{XRAY_INBOUND_PORT}},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "{{XRAY_CLIENT_UUID}}",
            "level": {{XRAY_CLIENT_LEVEL}}
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "{{XRAY_INBOUND_TRANSPORT}}"
      }
    }
  ],
  "outbounds": [
    {
      "tag": "{{XRAY_OUTBOUND_TAG}}",
      "protocol": "socks",
      "settings": {
        "servers": [
          {
            "address": "{{XRAY_OUTBOUND_ADDRESS}}",
            "port": {{XRAY_OUTBOUND_PORT}}
          }
        ]
      }
    }
  ],
  "routing": {
    "rules": [
      {
        "type": "field",
        "inboundTag": ["{{XRAY_INBOUND_TAG}}"],
        "outboundTag": "{{XRAY_OUTBOUND_TAG}}"
      }
    ]
  }
}