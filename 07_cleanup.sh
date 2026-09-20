#!/usr/bin/env bash
# ==============================================================================
# Step 7: Cleanup Demo Resources (Multi-Region Spanner & Alert Policies)
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.env"

read -r -p "Are you sure you want to delete Spanner instance '${INSTANCE_ID}' and its alert policies in '${PROJECT_ID}'? [y/N] " response
if [[ ! "${response}" =~ ^([yY][eE][sS]|[yY])$ ]]; then
  echo "Aborted."
  exit 0
fi

echo "Deleting Spanner Observability Alert Policies..."
for policy in $(gcloud monitoring policies list --project="${PROJECT_ID}" --filter="displayName ~ 'Spanner Observability'" --format="value(name)"); do
  gcloud monitoring policies delete "${policy}" --project="${PROJECT_ID}" --quiet || true
done

echo "Deleting Log-Based Metric 'spanner_leader_change_events'..."
gcloud logging metrics delete spanner_leader_change_events --project="${PROJECT_ID}" --quiet || true

echo "Deleting Multi-Region Spanner Instance '${INSTANCE_ID}'..."
gcloud spanner instances delete "${INSTANCE_ID}" --project="${PROJECT_ID}" --quiet

echo "[CLEANUP COMPLETE]"
