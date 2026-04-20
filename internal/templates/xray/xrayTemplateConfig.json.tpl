{
  "log": {
    "access": "/tmp/xray_access.log",
    "error": "/tmp/xray_error.log",
    "loglevel": "info",
    "dnsLog": false,
    "maskAddress": ""
  },
  "api": {
    "tag": "api",
    "services": [
      "HandlerService",
      "LoggerService",
      "StatsService"
    ]
  },
  "dns": {
    "servers": [
      "77.88.8.8",
      "8.8.8.8"
    ]
  },
  "inbounds": [
    {
      "tag": "api",
      "listen": "127.0.0.1",
      "port": 62789,
      "protocol": "tunnel",
      "settings": {
        "address": "127.0.0.1"
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
      "tag": "external-proxy",
      "protocol": "vless",
      "settings": {
        "vnext": [
          {
            "address": "{{AWG_TUN_IPV6_EXTERNAL}}",
            "port": {{EXTERNAL_PROXY_PORT}},
            "users": [
              {
                "id": "{{EXTERNAL_PROXY_UUID}}",
                "encryption": "none",
                "level": 0
              }
            ]
          }
        ]
      },
      "streamSettings": {
        "network": "tcp"
      }
    },
    {
      "tag": "blocked",
      "protocol": "blackhole",
      "settings": {}
    },
    {
      "tag": "smart-proxy-out",
      "protocol": "socks",
      "settings": {
        "servers": [
          {
            "address": "127.0.0.1",
            "port": 7070
          }
        ]
      }
    }
  ],
  "policy": {
    "levels": {
      "0": {
        "statsUserDownlink": true,
        "statsUserUplink": true
      }
    },
    "system": {
      "statsInboundDownlink": true,
      "statsInboundUplink": true,
      "statsOutboundDownlink": false,
      "statsOutboundUplink": false
    }
  },
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "type": "field",
        "inboundTag": [
          "api"
        ],
        "outboundTag": "api"
      },
      {
        "type": "field",
        "inboundTag": [
          "smart-proxy-in"
        ],
        "outboundTag": "external-proxy"
      },
      {
        "type": "field",
        "outboundTag": "blocked",
        "ip": [
          "geoip:private"
        ]
      },
      {
        "type": "field",
        "outboundTag": "blocked",
        "protocol": [
          "bittorrent"
        ]
      },
      {
        "type": "field",
        "network": "tcp,udp",
        "port": "53",
        "outboundTag": "direct"
      },
      {
        "type": "field",
        "user": [
          "{{FILTERED_USERS_JSON_ARRAY}}"
        ],
        "network": "tcp,udp",
        "outboundTag": "smart-proxy-out"
      },
      {
        "type": "field",
        "inboundTag": [
          "vless-reality-filtered",
          "vless-ws-filtered"
        ],
        "network": "tcp,udp",
        "outboundTag": "smart-proxy-out"
      },
      {
        "type": "field",
        "inboundTag": [
          "vless-reality",
          "vless-ws"
        ],
        "outboundTag": "external-proxy"
      },
      {
        "type": "field",
        "network": "tcp,udp",
        "outboundTag": "external-proxy"
      }
    ]
  },
  "stats": {},
  "metrics": {
    "tag": "metrics_out",
    "listen": "127.0.0.1:11111"
  }
}
