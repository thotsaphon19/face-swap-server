#!/usr/bin/env bash
# Production DigitalOcean control-plane installer for Ubuntu 22.04/24.04.
set -euo pipefail

APP_DIR="${APP_DIR:-/opt/face-swap-server}"
REPO_URL="${REPO_URL:?Set REPO_URL to your git repository}"
DOMAIN="${DOMAIN:?Set DOMAIN, e.g. api.example.com}"
SECRET_TOKEN="${SECRET_TOKEN:?Set SECRET_TOKEN}"
RUNPOD_BASE_URL="${RUNPOD_BASE_URL:?Set RUNPOD_BASE_URL to the RunPod HTTPS proxy URL}"
RUNPOD_SECRET_TOKEN="${RUNPOD_SECRET_TOKEN:?Set RUNPOD_SECRET_TOKEN}"

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y --no-install-recommends python3-pip python3-venv git curl nginx certbot python3-certbot-nginx

if [ -d "$APP_DIR/.git" ]; then
  git -C "$APP_DIR" fetch --all --prune
  git -C "$APP_DIR" reset --hard origin/main
else
  rm -rf "$APP_DIR"
  git clone "$REPO_URL" "$APP_DIR"
fi

python3 -m venv "$APP_DIR/.venv"
"$APP_DIR/.venv/bin/pip" install --upgrade pip
"$APP_DIR/.venv/bin/pip" install -r "$APP_DIR/backend/requirements-control.txt"

cat > "$APP_DIR/.env" <<ENV
APP_ROLE=control-plane
PUBLIC_BASE_URL=https://$DOMAIN
SECRET_TOKEN=$SECRET_TOKEN
RUNPOD_BASE_URL=$RUNPOD_BASE_URL
RUNPOD_SECRET_TOKEN=$RUNPOD_SECRET_TOKEN
REQUEST_TIMEOUT_SECONDS=30
SESSION_TTL_SECONDS=3600
MAX_IMAGE_BYTES=5242880
LOG_LEVEL=INFO
CORS_ORIGINS=*
ENV
chmod 600 "$APP_DIR/.env"
chown -R www-data:www-data "$APP_DIR"

cat > /etc/systemd/system/faceswap.service <<SERVICE
[Unit]
Description=FaceSwap Control Plane
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=www-data
Group=www-data
WorkingDirectory=$APP_DIR
EnvironmentFile=$APP_DIR/.env
ExecStart=$APP_DIR/.venv/bin/python -m uvicorn backend.app:app --host 127.0.0.1 --port 8000 --workers 1 --ws-ping-interval 15 --ws-ping-timeout 15
Restart=always
RestartSec=2
TimeoutStopSec=10
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
SERVICE

cat > /etc/nginx/sites-available/faceswap <<NGINX
map \$http_upgrade \$connection_upgrade {
    default upgrade;
    '' close;
}

server {
    listen 80;
    server_name $DOMAIN;
    client_max_body_size 8m;

    location /ws {
        proxy_pass http://127.0.0.1:8000/ws;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_read_timeout 75s;
        proxy_send_timeout 75s;
    }

    location / {
        proxy_pass http://127.0.0.1:8000;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_buffering off;
        proxy_read_timeout 60s;
    }
}
NGINX

ln -sf /etc/nginx/sites-available/faceswap /etc/nginx/sites-enabled/faceswap
rm -f /etc/nginx/sites-enabled/default
nginx -t
systemctl daemon-reload
systemctl enable --now faceswap
systemctl reload nginx

certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos --redirect --email "admin@$DOMAIN"

sleep 2
curl -fsS "https://$DOMAIN/health"
echo
echo "Control plane ready: https://$DOMAIN"
