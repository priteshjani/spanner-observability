#!/usr/bin/env bash
# ==============================================================================
# Step 1: Setup Multi-Region Cloud Spanner Instance & Verify VPC
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.env"

echo "=================================================================="
echo "1. Configuring GCP Project & Enabling Required APIs"
echo "   Project ID   : ${PROJECT_ID}"
echo "   Project Name : ${PROJECT_NAME}"
echo "   VPC Network  : ${VPC_NETWORK}"
echo "=================================================================="

gcloud config set project "${PROJECT_ID}"

gcloud services enable \
  spanner.googleapis.com \
  monitoring.googleapis.com \
  logging.googleapis.com \
  compute.googleapis.com \
  --project="${PROJECT_ID}"

echo ""
echo "=================================================================="
echo "2. Verifying VPC Network (${VPC_NETWORK})"
echo "=================================================================="
if gcloud compute networks describe "${VPC_NETWORK}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
  echo "[OK] VPC '${VPC_NETWORK}' found in project '${PROJECT_ID}'."
else
  echo "[INFO] VPC '${VPC_NETWORK}' is a Shared VPC or hosted externally. Verifying Shared VPC subnets..."
  gcloud compute networks subnets list-usable --project="${PROJECT_ID}" --filter="network ~ ${VPC_NETWORK}" || true
fi

echo ""
echo "=================================================================="
echo "3. Creating Multi-Region Spanner Instance (${INSTANCE_ID})"
echo "   Config       : ${INSTANCE_CONFIG} (Multi-Region: us-east4 / us-east1 / us-central1)"
echo "   Edition      : ${EDITION}"
echo "   Capacity     : ${PROCESSING_UNITS} Processing Units"
echo "=================================================================="

if gcloud spanner instances describe "${INSTANCE_ID}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
  echo "[OK] Spanner instance '${INSTANCE_ID}' already exists."
else
  gcloud spanner instances create "${INSTANCE_ID}" \
    --project="${PROJECT_ID}" \
    --config="${INSTANCE_CONFIG}" \
    --description="${INSTANCE_DISPLAY_NAME}" \
    --processing-units="${PROCESSING_UNITS}" \
    --edition="${EDITION}" \
    --labels="env=demo,purpose=observability,vpc=${VPC_NETWORK}"
  echo "[SUCCESS] Created multi-region Spanner instance '${INSTANCE_ID}'."
fi

echo ""
echo "Current Spanner Instance Details:"
gcloud spanner instances describe "${INSTANCE_ID}" --project="${PROJECT_ID}"
