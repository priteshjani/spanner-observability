#!/usr/bin/env bash
# ==============================================================================
# Step 8: Upload / Push 'spanner-observability' Repository to Git Remote
#   Usage:
#     ./08_push_to_git.sh <GIT_REMOTE_URL>
#   Example (GitHub):
#     ./08_push_to_git.sh https://github.com/priteshjani/spanner-observability.git
#   Example (Cloud Source Repositories - default if no URL provided):
#     ./08_push_to_git.sh
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.env"

REMOTE_URL="${1:-}"

cd "${SCRIPT_DIR}"

if [[ -z "${REMOTE_URL}" ]]; then
  echo "[INFO] No GitHub URL passed as argument."
  echo "       Checking/creating Google Cloud Source Repository 'spanner-observability' in '${PROJECT_ID}'..."
  gcloud services enable sourcerepo.googleapis.com --project="${PROJECT_ID}" || true
  if ! gcloud source repos describe spanner-observability --project="${PROJECT_ID}" >/dev/null 2>&1; then
    gcloud source repos create spanner-observability --project="${PROJECT_ID}"
  fi
  REMOTE_URL="https://source.developers.google.com/p/${PROJECT_ID}/r/spanner-observability"
  git config credential.https://source.developers.google.com.helper gcloud.sh
fi

echo "Configuring Git remote 'origin' -> ${REMOTE_URL}"
if git remote get-url origin >/dev/null 2>&1; then
  git remote set-url origin "${REMOTE_URL}"
else
  git remote add origin "${REMOTE_URL}"
fi

git add -A
git diff-index --quiet HEAD || git commit -m "Update spanner-observability scripts and alert policies"

echo "Pushing 'main' branch to ${REMOTE_URL}..."
git push -u origin main

echo "[SUCCESS] Repository 'spanner-observability' pushed to ${REMOTE_URL}"
