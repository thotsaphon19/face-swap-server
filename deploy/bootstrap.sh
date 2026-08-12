#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ROOT_DIR}/.env"

if [[ ! -f "${ENV_FILE}" ]]; then
  cp "${ROOT_DIR}/.env.example" "${ENV_FILE}"
  echo "Created ${ENV_FILE}. Update secrets before exposing the stack publicly."
fi

mkdir -p "${ROOT_DIR}/model/checkpoints"

if [[ "${1:-}" == "local-gpu" ]]; then
  shift
  exec docker compose --profile local-gpu --env-file "${ENV_FILE}" up -d --build "$@"
fi

exec docker compose --env-file "${ENV_FILE}" up -d --build "$@"
