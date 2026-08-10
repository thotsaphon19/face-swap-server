#!/usr/bin/env bash
set -euo pipefail

# Start uvicorn in background (backend)
cd /app/backend
# create venv and install if not present (container builds install packages already)
if [ ! -d .venv ]; then
  python3 -m venv .venv
  . .venv/bin/activate
  pip install --upgrade pip setuptools wheel
  pip install -r requirements.txt || true
else
  . .venv/bin/activate
fi

# start uvicorn as background process
nohup ./.venv/bin/uvicorn app:app --host 127.0.0.1 --port 8000 --workers 1 > /app/uvicorn.log 2>&1 &

# Start nginx in foreground (so container keeps running)
nginx -g "daemon off;"