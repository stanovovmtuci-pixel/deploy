[Unit]
Description=Smart routing proxy daemon
After=network.target x-ui.service
Requires=x-ui.service

[Service]
Type=simple
ExecStart=/usr/bin/python3 /usr/local/bin/smart-proxy/daemon.py
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
