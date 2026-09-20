#!/usr/bin/env bash
# ==============================================================================
# Step 2: Create Spanner Database, Multi-Region Leader Config & Seed Data
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.env"

echo "=================================================================="
echo "1. Verifying Spanner Instance '${INSTANCE_ID}' Exists"
echo "=================================================================="
if ! gcloud spanner instances describe "${INSTANCE_ID}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
  echo "[WARN] Instance '${INSTANCE_ID}' not found. Running 01_setup_spanner.sh first..."
  "${SCRIPT_DIR}/01_setup_spanner.sh"
fi

echo ""
echo "=================================================================="
echo "2. Creating Spanner Database '${DATABASE_ID}' on '${INSTANCE_ID}'"
echo "   Default Leader Region: ${PRIMARY_LEADER_REGION}"
echo "=================================================================="

TMP_DDL="$(mktemp /tmp/spanner_schema_XXXXXX.sql)"
sed -e "s/finops-obs-db/${DATABASE_ID}/g" \
    -e "s/us-east4/${PRIMARY_LEADER_REGION}/g" \
    "${SCRIPT_DIR}/schema.sql" > "${TMP_DDL}"

if gcloud spanner databases describe "${DATABASE_ID}" \
    --instance="${INSTANCE_ID}" \
    --project="${PROJECT_ID}" >/dev/null 2>&1; then
  echo "[OK] Database '${DATABASE_ID}' already exists on instance '${INSTANCE_ID}'."
else
  gcloud spanner databases create "${DATABASE_ID}" \
    --instance="${INSTANCE_ID}" \
    --project="${PROJECT_ID}" \
    --ddl-file="${TMP_DDL}"
  echo "[SUCCESS] Created database '${DATABASE_ID}' with default_leader='${PRIMARY_LEADER_REGION}'."
fi

rm -f "${TMP_DDL}"

echo ""
echo "=================================================================="
echo "3. Verifying Configured Multi-Region Default Leader"
echo "=================================================================="
gcloud spanner databases execute-sql "${DATABASE_ID}" \
  --instance="${INSTANCE_ID}" \
  --project="${PROJECT_ID}" \
  --sql="SELECT OPTION_NAME, OPTION_VALUE FROM INFORMATION_SCHEMA.DATABASE_OPTIONS WHERE OPTION_NAME = 'default_leader'"

echo ""
echo "=================================================================="
echo "4. Seeding Initial Sample Accounts for Read/Write Workload"
echo "=================================================================="
for i in 1 2 3 4 5; do
  ACCT_ID="acct-000${i}"
  gcloud spanner databases execute-sql "${DATABASE_ID}" \
    --instance="${INSTANCE_ID}" \
    --project="${PROJECT_ID}" \
    --sql="INSERT OR IGNORE INTO Accounts (account_id, account_name, region, balance, status, updated_at) VALUES ('${ACCT_ID}', 'Enterprise-Customer-${i}', '${PRIMARY_LEADER_REGION}', NUMERIC '100000.00', 'ACTIVE', PENDING_COMMIT_TIMESTAMP())"
done

echo "[SUCCESS] Seeded 5 enterprise accounts into '${DATABASE_ID}'."
