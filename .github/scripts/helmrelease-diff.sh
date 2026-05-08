#!/usr/bin/env bash
set -euo pipefail

HELMRELEASE_PATH="$1"
PR_NUMBER="${PR_NUMBER:-}"
if [[ -z "$PR_NUMBER" ]]; then
  echo "PR_NUMBER not set" >&2
  exit 1
fi

BASE_REF="${GITHUB_BASE_REF:-master}"

# 1. Extract chart metadata
CHART_NAME=$(yq '.spec.chart.spec.chart' "$HELMRELEASE_PATH")
OLD_VERSION=$(git show "origin/${BASE_REF}:$HELMRELEASE_PATH" | yq '.spec.chart.spec.version')
NEW_VERSION=$(yq '.spec.chart.spec.version' "$HELMRELEASE_PATH")
REPO_NAME=$(yq '.spec.chart.spec.sourceRef.name' "$HELMRELEASE_PATH")
VALUES_JSON=$(yq -o json '.spec.values' "$HELMRELEASE_PATH")

# 2. Determine repo URL (adjust this path to your HelmRepository file location)
REPO_URL=$(yq ".spec.url" "infrastructure/flux-system/${REPO_NAME}.yaml")

# 3. Add repo and fetch charts
helm repo add "$REPO_NAME" "$REPO_URL" --force-update
helm pull "$REPO_NAME/$CHART_NAME" --version "$OLD_VERSION" --untar --untardir /tmp/old
helm pull "$REPO_NAME/$CHART_NAME" --version "$NEW_VERSION" --untar --untardir /tmp/new

# 4. Render and diff
echo "$VALUES_JSON" > /tmp/values.json
OLD_MANIFEST=$(helm template old "/tmp/old/$CHART_NAME" -f /tmp/values.json --namespace dummy)
NEW_MANIFEST=$(helm template new "/tmp/new/$CHART_NAME" -f /tmp/values.json --namespace dummy)

diff_output=$(dyff between --omit-header --set-exit-code <(echo "$OLD_MANIFEST") <(echo "$NEW_MANIFEST")) || true

# 5. Post PR comment
if [[ -n "$diff_output" ]]; then
  {
    echo "## :eyes: HelmRelease Diff for \`$HELMRELEASE_PATH\`"
    echo '```diff'
    echo "$diff_output"
    echo '```'
  } | gh pr comment "$PR_NUMBER" --body-file -
else
  echo "No changes detected." | gh pr comment "$PR_NUMBER" --body-file -
fi