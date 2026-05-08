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

# 2. Find the HelmRepository definition file and extract the URL
#    Search all YAML files under infrastructure/ (adjust the base path if needed)
HELMREPO_URL=$(find infrastructure/ apps/ -name "*.yaml" -print0 \
  | xargs -0 yq e 'select(.kind == "HelmRepository" and .metadata.name == "'"$REPO_NAME"'") | .spec.url' \
  | head -1)

if [[ -z "$HELMREPO_URL" ]]; then
  echo "ERROR: Could not find HelmRepository '$REPO_NAME' in any YAML file under infrastructure/" >&2
  exit 1
fi

REPO_URL="$HELMREPO_URL"

# 3. Add repo and fetch charts
helm repo add "$REPO_NAME" "$REPO_URL" --force-update
helm pull "$REPO_NAME/$CHART_NAME" --version "$OLD_VERSION" --untar --untardir /tmp/old
helm pull "$REPO_NAME/$CHART_NAME" --version "$NEW_VERSION" --untar --untardir /tmp/new

# 4. Render manifests with a consistent release name
echo "$VALUES_JSON" > /tmp/values.json
OLD_MANIFEST=$(helm template pr-preview "/tmp/old/$CHART_NAME" -f /tmp/values.json --namespace dummy)
NEW_MANIFEST=$(helm template pr-preview "/tmp/new/$CHART_NAME" -f /tmp/values.json --namespace dummy)

# Remove chart version labels that always change with the chart version
clean_manifest() {
  yq eval 'del(.metadata.labels."helm.sh/chart") | del(.metadata.labels."app.kubernetes.io/version")' -
}

echo "$OLD_MANIFEST" | clean_manifest > /tmp/old-manifests.yaml
echo "$NEW_MANIFEST" | clean_manifest > /tmp/new-manifests.yaml

diff_output=$(git diff --no-index -- /tmp/old-manifests.yaml /tmp/new-manifests.yaml) || true
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