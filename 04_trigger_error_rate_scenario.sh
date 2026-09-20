#!/usr/bin/env bash
# ==============================================================================
# Step 4 (Demo Scenario 1): Trigger Spanner Error Rate Alert
#   Runs continuous read/write traffic while injecting failing Spanner RPCs
#   (status != OK) for 120 seconds to trigger the High Error Rate email alert.
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.env"

DURATION="${1:-120}"

echo "=================================================================="
echo " Scenario 1: Simulating Spanner API Error Spike (${DURATION}s)"
echo " Instance  : ${INSTANCE_ID} (${PROJECT_ID})"
echo " Alerting  : ${NOTIFICATION_EMAIL_1}, ${NOTIFICATION_EMAIL_2}"
echo "=================================================================="

python3 "${SCRIPT_DIR}/app.py" \
  --project-id="${PROJECT_ID}" \
  --instance-id="${INSTANCE_ID}" \
  --database-id="${DATABASE_ID}" \
  --mode="inject-errors" \
  --duration="${DURATION}" \
  --interval=0.5

echo ""
echo "[SCENARIO 1 COMPLETE] Spanner non-OK API requests emitted."
echo "Check Cloud Monitoring Incidents & Email inbox (${NOTIFICATION_EMAIL_1}, ${NOTIFICATION_EMAIL_2})."
