#!/usr/bin/env bash
# ==============================================================================
# Step 5 (Demo Scenario 2): Trigger Multi-Region Spanner Leader Flip / Change
#   Flips the database default_leader between us-east4 and us-east1 on the
#   nam3 multi-region instance. This triggers:
#     1. Spanner Leader Config Flip Audit Log Alert Policy
#     2. Spanner Leader Percentage Shift Metric Alert Policy
#     3. Application live leader flip detection log
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.env"

echo "=================================================================="
echo " Scenario 2: Multi-Region Spanner Leader Flip"
echo " Instance  : ${INSTANCE_ID} (Config: ${INSTANCE_CONFIG})"
echo " Database  : ${DATABASE_ID}"
echo "=================================================================="

CURRENT_LEADER=$(gcloud spanner databases execute-sql "${DATABASE_ID}" \
  --instance="${INSTANCE_ID}" \
  --project="${PROJECT_ID}" \
  --sql="SELECT OPTION_VALUE FROM INFORMATION_SCHEMA.DATABASE_OPTIONS WHERE OPTION_NAME = 'default_leader'" \
  --format=json | python3 -c "import sys, json; data=json.load(sys.stdin); print(data['rows'][0][0] if data.get('rows') else '${PRIMARY_LEADER_REGION}')")

echo "Current Default Leader Region : ${CURRENT_LEADER}"

if [[ "${CURRENT_LEADER}" == "${PRIMARY_LEADER_REGION}" ]]; then
  NEW_LEADER="${ALTERNATE_LEADER_REGION}"
else
  NEW_LEADER="${PRIMARY_LEADER_REGION}"
fi

echo "Target New Leader Region      : ${NEW_LEADER}"
echo ""
echo "Executing DDL to flip multi-region leader from '${CURRENT_LEADER}' ---> '${NEW_LEADER}'..."

gcloud spanner databases ddl update "${DATABASE_ID}" \
  --instance="${INSTANCE_ID}" \
  --project="${PROJECT_ID}" \
  --ddl="ALTER DATABASE \`${DATABASE_ID}\` SET OPTIONS (default_leader = '${NEW_LEADER}')"

echo ""
echo "Verifying updated leader in INFORMATION_SCHEMA.DATABASE_OPTIONS:"
gcloud spanner databases execute-sql "${DATABASE_ID}" \
  --instance="${INSTANCE_ID}" \
  --project="${PROJECT_ID}" \
  --sql="SELECT OPTION_NAME, OPTION_VALUE FROM INFORMATION_SCHEMA.DATABASE_OPTIONS WHERE OPTION_NAME = 'default_leader'"

echo ""
echo "[SCENARIO 2 COMPLETE] Multi-region leader flipped to '${NEW_LEADER}'."
echo "Alert notifications will be sent to: ${NOTIFICATION_EMAIL_1}, ${NOTIFICATION_EMAIL_2}."
