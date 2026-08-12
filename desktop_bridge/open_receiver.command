#!/usr/bin/env bash
set -euo pipefail
SERVER="${1:-}"
SESSION_ID="${2:-}"
TOKEN="${3:-}"
if [[ -z "$SERVER" || -z "$SESSION_ID" || -z "$TOKEN" ]]; then
  echo "Usage: ./open_receiver.command https://api.example.com SESSION_ID TOKEN"
  exit 2
fi
BASE="${SERVER%/}"
python3 - "$BASE" "$SESSION_ID" "$TOKEN" <<'PY'
import sys, urllib.parse, subprocess
base,sid,token=sys.argv[1:]
url=f"{base}/viewer?"+urllib.parse.urlencode({'session_id':sid,'token':token})
subprocess.run(['open',url],check=True)
PY
