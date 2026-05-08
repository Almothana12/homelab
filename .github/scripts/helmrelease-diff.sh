#!/usr/bin/env bash
set -euo pipefail

HELMRELEASE_PATH="$1"
PR_NUMBER="${{ github.event.pull_request.number }}"

# 1. Extract chart metadata from the Flux HelmRelease
CHART_NAME=$(yq '.spec.chart.spec.chart' "$HELMRELEASE_PATH")
OLD_VERSION=$(git show "origin/${{ github.base_ref }}:$HELMRELEASE_PATH" | yq '.spec.chart.spec.version')
NEW_VERSION=$(yq '.spec.chart.spec.version' "$HELMRELEASE_PATH")
REPO_NAME=$(yq '.spec.chart.spec.sourceRef.name' "$HELMRELEASE_PATH")
VALUES_JSON=$(yq -o json '.spec.values' "$HELMRELEASE_PATH")

# 2. Determine the Helm repository URL
REPO_URL=$(yq ".spec.url" "infrastructure/flux-system/${REPO_NAME}.yaml")  # adjust path

# 3. Add repo and fetch charts
helm repo add "$REPO_NAME" "$REPO_URL" --force-update
helm pull "$REPO_NAME/$CHART_NAME" --version "$OLD_VERSION" --untar --untardir /tmp/old
helm pull "$REPO_NAME/$CHART_NAME" --version "$NEW_VERSION" --untar --untardir /tmp/new

# 4. Render manifests and diff with dyff
echo "$VALUES_JSON" > /tmp/values.json
OLD_MANIFEST=$(helm template old "/tmp/old/$CHART_NAME" -f /tmp/values.json --namespace dummy)
NEW_MANIFEST=$(helm template new "/tmp/new/$CHART_NAME" -f /tmp/values.json --namespace dummy)

diff_output=$(dyff between --omit-header --set-exit-code <(echo "$OLD_MANIFEST") <(echo "$NEW_MANIFEST")) || true

# 5. Post comment on PR (using github-comment or GitHub CLI)
if [[ -n "$diff_output" ]]; then
  echo "## :eyes: HelmRelease Diff for \`$HELMRELEASE_PATH\`" > /tmp/comment.md
  echo "\`\`\`diff" >> /tmp/comment.md
  echo "$diff_output" >> /tmp/comment.md
  echo "\`\`\`" >> /tmp/comment.md

  # Use github-comment to post and auto-hide previous comments
  github-comment exec \
    -k "helmrelease-diff-${HELMRELEASE_PATH//\//-}" \
    -pr "$PR_NUMBER" \
    --config .github/.github-comment.yaml \
    -- dyff --omit-header --set-exit-code bw \
    <(echo "$OLD_MANIFEST") <(echo "$NEW_MANIFEST")
else
  echo "No changes detected." | gh pr comment "$PR_NUMBER" --body-file -
fi