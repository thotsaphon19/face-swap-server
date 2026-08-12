#!/usr/bin/env bash
set -euo pipefail

export PYTHONPATH="/app/backend:${PYTHONPATH:-}"

if [[ "${ENABLE_NGINX:-true}" == "true" ]]; then
  uvicorn app:app --app-dir /app/backend --host 127.0.0.1 --port "${WORKER_PORT:-8000}" --workers "${UVICORN_WORKERS:-1}" &
  exec nginx -g "daemon off;"
fi

exec uvicorn app:app --app-dir /app/backend --host 0.0.0.0 --port "${WORKER_PORT:-8000}" --workers "${UVICORN_WORKERS:-1}"
