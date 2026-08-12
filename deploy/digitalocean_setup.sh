#!/usr/bin/env bash
# =============================================================================
# DigitalOcean Droplet Setup Script
# Tested on Ubuntu 22.04 (CPU droplet, 2–4 GB RAM minimum)
#
# Usage (as root on fresh droplet):
#   chmod +x deploy/digitalocean_setup.sh
#   SECRET_TOKEN=your_token bash deploy/digitalocean_setup.sh
# =============================================================================
set -euo pipefail

APP_DIR="/opt/face-swap-server"
DOMAIN="${DOMAIN:-}"   # optional: set to your domain for HTTPS via certbot

echo "[DO] Updating packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y --no-install-recommends \
    python3-pip python3-venv git curl nginx certbot python3-certbot-nginx

# ── Clone or pull repo ───────────────────────────────────────────────────────
if [ -d "$APP_DIR/.git" ]; then
    echo "[DO] Pulling latest code..."
    git -C "$APP_DIR" pull --ff-only
else
    echo "[DO] Cloning repo..."
    git clone https://github.com/thotsaphon19/face-swap-server.git "$APP_DIR"
fi

# ── Python environment ───────────────────────────────────────────────────────
echo "[DO] Setting up Python venv..."
python3 -m venv "$APP_DIR/.venv"
source "$APP_DIR/.venv/bin/activate"
pip install --upgrade pip
pip install -r "$APP_DIR/backend/requirements.txt"
pip install "uvicorn[standard]>=0.22"

# ── Environment file ─────────────────────────────────────────────────────────
cat > "$APP_DIR/.env" <<EOF
SECRET_TOKEN=${SECRET_TOKEN:-changeme_do}
WORKER_PORT=8000
MODEL_DIR=/opt/model/checkpoints
LOG_LEVEL=INFO
CORS_ORIGINS=*
EOF
chmod 600 "$APP_DIR/.env"
echo "[DO] Written $APP_DIR/.env"

# ── Systemd service ───────────────────────────────────────────────────────────
cat > /etc/systemd/system/faceswap.service <<EOF
[Unit]
Description=FaceSwap FastAPI backend
After=network.target

[Service]
User=www-data
Group=www-data
WorkingDirectory=$APP_DIR
EnvironmentFile=$APP_DIR/.env
ExecStart=$APP_DIR/.venv/bin/uvicorn backend.app:app \
    --host 127.0.0.1 --port 8000 --workers 1 --log-level info
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable faceswap
systemctl restart faceswap
echo "[DO] systemd service faceswap started"

# ── Nginx ─────────────────────────────────────────────────────────────────────
cat > /etc/nginx/sites-available/faceswap <<'NGINX'
server {
    listen 80;
    server_name _;

    # Serve PWA static files
    root /opt/face-swap-server/frontend;
    index index.html;

    location / {
        try_files $uri $uri/ /index.html;
    }

    # Proxy API + WebSocket to uvicorn
    location ~ ^/(v1|ws|health|docs|openapi) {
        proxy_pass http://127.0.0.1:8000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
        client_max_body_size 10M;
    }
}
NGINX

ln -sf /etc/nginx/sites-available/faceswap /etc/nginx/sites-enabled/faceswap
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl reload nginx
echo "[DO] Nginx configured"

# ── Optional HTTPS ────────────────────────────────────────────────────────────
if [ -n "$DOMAIN" ]; then
    echo "[DO] Requesting Let's Encrypt cert for $DOMAIN ..."
    certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos \
        --email "admin@$DOMAIN" --redirect
    echo "[DO] HTTPS enabled"
fi

echo ""
echo "=== DigitalOcean setup complete ==="
echo "Health check:  curl http://$(curl -s ifconfig.me)/health"
echo ""
echo "Flutter app WebSocket:  ws://<DROPLET_IP>/ws?token=<TOKEN>"
echo "(use wss:// if you set up HTTPS)"
