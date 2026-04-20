user www-data;
worker_processes auto;
pid /run/nginx.pid;
include /etc/nginx/modules-enabled/*.conf;

events {
    worker_connections 1024;
}

stream {
    log_format stream_log '$remote_addr [$time_local] '
                         '$protocol $status $bytes_sent $bytes_received '
                         '$session_time "$upstream_addr"';
    access_log /var/log/nginx/stream_access.log stream_log;

    upstream xray_reality {
        server 127.0.0.1:10443;
    }

    server {
        listen 127.0.0.1:8443;
        proxy_pass xray_reality;
        proxy_connect_timeout 10s;
        proxy_timeout 300s;
    }
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    sendfile on;
    keepalive_timeout 65;
    access_log /var/log/nginx/access.log;
    error_log  /var/log/nginx/error.log;

    server {
        listen 80;
        listen [::]:80;
        server_name {{NODE_FQDN}};

        location /.well-known/acme-challenge/ {
            root /var/www/certbot;
        }
        location / {
            return 301 https://$host$request_uri;
        }
    }

    server {
        listen 127.0.0.1:8444 ssl;
        server_name {{NODE_FQDN}};

        ssl_certificate     /etc/letsencrypt/live/{{NODE_FQDN}}/fullchain.pem;
        ssl_certificate_key /etc/letsencrypt/live/{{NODE_FQDN}}/privkey.pem;
        ssl_protocols TLSv1.2 TLSv1.3;
        ssl_ciphers HIGH:!aNULL:!MD5;

        # Front page (NTP camo)
        location / {
            root /var/www/{{NODE_FQDN}};
            index index.html;
        }

        # 3x-ui panel
        location {{X_UI_WEB_BASE}}/ {
            proxy_pass http://127.0.0.1:{{X_UI_PANEL_PORT}}{{X_UI_WEB_BASE}}/;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
        }
        location /api/ {
            proxy_pass http://127.0.0.1:{{X_UI_PANEL_PORT}}/api/;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
        }
        location /sub/ {
            proxy_pass http://127.0.0.1:{{X_UI_PANEL_PORT}}/sub/;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
        }
        location /statics/    { proxy_pass http://127.0.0.1:{{X_UI_PANEL_PORT}}/statics/; }
        location /docs        { proxy_pass http://127.0.0.1:{{X_UI_PANEL_PORT}}/docs; }
        location /redoc       { proxy_pass http://127.0.0.1:{{X_UI_PANEL_PORT}}/redoc; }
        location /openapi.json{ proxy_pass http://127.0.0.1:{{X_UI_PANEL_PORT}}/openapi.json; }

        # Xray WebSocket inbound
        location /p4n3l2 {
            proxy_pass http://127.0.0.1:10444;
            proxy_http_version 1.1;
            proxy_set_header Upgrade $http_upgrade;
            proxy_set_header Connection "upgrade";
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_read_timeout 300s;
            proxy_send_timeout 300s;
        }

        # prxy-panel (Flask via DispatcherMiddleware on /prxy)
        location /prxy/ {
            proxy_pass http://127.0.0.1:5001/prxy/;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
            proxy_set_header X-Forwarded-Prefix /prxy;
            proxy_buffering off;
            proxy_read_timeout 300s;
        }
    }
}
