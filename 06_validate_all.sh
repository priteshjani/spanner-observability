#!/usr/bin/env bash
# ==============================================================================
# Step 6: End-to-End Validation Script (Spanner, Database, App Read/Write, Alerts)
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.env"

echo "=================================================================="
echo " Spanner Availability & Observability - End-to-End Validation"
echo "=================================================================="

echo ""
echo "[1/5] Checking Multi-Region Spanner Instance '${INSTANCE_ID}'..."
gcloud spanner instances describe "${INSTANCE_ID}" \
  --project="${PROJECT_ID}" \
  --format="table(name,config,state,edition,processingUnits)"

echo ""
echo "[2/5] Checking Database '${DATABASE_ID}' & Default Leader Configuration..."
gcloud spanner databases execute-sql "${DATABASE_ID}" \
  --instance="${INSTANCE_ID}" \
  --project="${PROJECT_ID}" \
  --sql="SELECT OPTION_NAME, OPTION_VALUE FROM INFORMATION_SCHEMA.DATABASE_OPTIONS WHERE OPTION_NAME = 'default_leader'"

echo ""
echo "[3/5] Checking Notification Channels (${NOTIFICATION_EMAILS})..."
ACCESS_TOKEN="$(gcloud auth print-access-token)"
curl -s -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  "https://monitoring.googleapis.com/v3/projects/${PROJECT_ID}/notificationChannels" \
  | python3 -c "
import sys, json
data = json.load(sys.stdin)
print(f'{\"NAME\":<65} {\"DISPLAY_NAME\":<28} {\"EMAIL\"}')
for ch in data.get('notificationChannels', []):
    if ch.get('type') == 'email':
        print(f\"{ch.get('name',''):<65} {ch.get('displayName',''):<28} {ch.get('labels',{}).get('email_address','')}\")
"

echo ""
echo "[4/5] Checking Active Cloud Monitoring Alert Policies..."
gcloud monitoring policies list \
  --project="${PROJECT_ID}" \
  --filter="displayName ~ 'Spanner Observability'" \
  --format="table(name,displayName,enabled)"

echo ""
echo "[5/5] Validating Application Read/Write & Heartbeat Probe against Spanner..."
if [[ ! -d "${SCRIPT_DIR}/.venv" ]]; then
  python3 -m venv "${SCRIPT_DIR}/.venv"
  "${SCRIPT_DIR}/.venv/bin/pip" install -q -r "${SCRIPT_DIR}/requirements.txt"
fi

"${SCRIPT_DIR}/.venv/bin/python" "${SCRIPT_DIR}/app.py" \
  --project-id="${PROJECT_ID}" \
  --instance-id="${INSTANCE_ID}" \
  --database-id="${DATABASE_ID}" \
  --mode="verify"

echo ""
echo "Recent Transactions & Heartbeat Probes in Spanner:"
gcloud spanner databases execute-sql "${DATABASE_ID}" \
  --instance="${INSTANCE_ID}" \
  --project="${PROJECT_ID}" \
  --sql="SELECT probe_id, probe_timestamp, configured_leader, ROUND(read_latency_ms, 2) AS read_ms, ROUND(write_latency_ms, 2) AS write_ms, status FROM HeartbeatLog ORDER BY probe_timestamp DESC LIMIT 5"

echo ""
echo "=================================================================="
echo " ALL VALIDATION CHECKS PASSED SUCCESSFULLY"
echo "=================================================================="
