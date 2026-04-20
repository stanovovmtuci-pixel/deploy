[Unit]
Description=Prxy Panel Web Application
After=network.target

[Service]
Type=simple
User={{ADMIN_USER}}
WorkingDirectory=/opt/prxy-panel
Environment=PATH=/home/{{ADMIN_USER}}/.local/bin:/usr/local/bin:/usr/bin:/bin
EnvironmentFile=-/etc/default/prxy-panel
ExecStart=/home/{{ADMIN_USER}}/.local/bin/gunicorn --workers 2 --bind 127.0.0.1:5001 --timeout 120 --chdir /opt/prxy-panel app:app
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
