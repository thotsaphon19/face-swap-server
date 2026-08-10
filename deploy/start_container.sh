#!/usr/bin/env bash
set -euo pipefail

cd /app/backend

if [ ! -d .venv ]; then
  python3 -m venv .venv
  . .venv/bin/activate
  pip install --upgrade pip setuptools wheel
  pip install -r requirements.txt || true
else
  . .venv/bin/activate
fi

nohup ./.venv/bin/uvicorn app:app --host 127.0.0.1 --port 8000 --workers 1 > /app/uvicorn.log 2>&1 &

nginx -g "daemon off;"
