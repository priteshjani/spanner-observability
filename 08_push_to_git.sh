#!/usr/bin/env bash
# ==============================================================================
# Step 8: Upload / Push 'spanner-observability' Repository to GitHub
#   Default Remote: https://github.com/priteshjani/spanner-observability.git
#
#   Usage:
#     # Option A: Interactive push (prompts for GitHub username/PAT)
#     ./08_push_to_git.sh
#
#     # Option B: Non-interactive push using GITHUB_TOKEN environment variable
#     GITHUB_TOKEN="ghp_xxx" ./08_push_to_git.sh
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

GITHUB_USER="${GITHUB_USER:-priteshjani}"
REPO_NAME="spanner-observability"
DEFAULT_REMOTE="https://github.com/${GITHUB_USER}/${REPO_NAME}.git"
REMOTE_URL="${1:-${DEFAULT_REMOTE}}"

if [[ -n "${GITHUB_TOKEN:-}" ]]; then
  AUTH_REMOTE="https://${GITHUB_USER}:${GITHUB_TOKEN}@github.com/${GITHUB_USER}/${REPO_NAME}.git"
else
  AUTH_REMOTE="${REMOTE_URL}"
fi

echo "Configuring Git remote 'origin' -> ${REMOTE_URL}"
if git remote get-url origin >/dev/null 2>&1; then
  git remote set-url origin "${REMOTE_URL}"
else
  git remote add origin "${REMOTE_URL}"
fi

git add -A
git diff-index --quiet HEAD || git commit -m "Update spanner-observability scripts and documentation"

echo "Pushing 'main' branch to ${REMOTE_URL}..."
git push -u "${AUTH_REMOTE}" main

echo "[SUCCESS] All files pushed to https://github.com/${GITHUB_USER}/${REPO_NAME}"
