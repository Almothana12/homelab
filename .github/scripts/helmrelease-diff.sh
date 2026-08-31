#!/usr/bin/env bash
set -euo pipefail

HELMRELEASE_PATH="$1"
PR_NUMBER="${PR_NUMBER:-}"
if [[ -z "$PR_NUMBER" ]]; then
  echo "PR_NUMBER not set" >&2
  exit 1
fi

BASE_REF="${GITHUB_BASE_REF:-master}"

# 1. Extract the base and head HelmRelease state independently. Rendering both
# charts with the head values would hide values-only changes such as image tags.
BASE_HELMRELEASE=$(git show "origin/${BASE_REF}:$HELMRELEASE_PATH")
CHART_NAME=$(yq -r '.spec.chart.spec.chart' "$HELMRELEASE_PATH")
CHART_PATH="${CHART_NAME#./}"
SOURCE_KIND=$(yq -r '.spec.chart.spec.sourceRef.kind' "$HELMRELEASE_PATH")
SOURCE_NAME=$(yq -r '.spec.chart.spec.sourceRef.name' "$HELMRELEASE_PATH")

WORK_DIR=$(mktemp -d)
trap 'rm -rf -- "$WORK_DIR"' EXIT

OLD_VALUES_FILE="$WORK_DIR/old-values.json"
NEW_VALUES_FILE="$WORK_DIR/new-values.json"
printf '%s\n' "$BASE_HELMRELEASE" | yq -o json '.spec.values // {}' > "$OLD_VALUES_FILE"
yq -o json '.spec.values // {}' "$HELMRELEASE_PATH" > "$NEW_VALUES_FILE"

find_source_file() {
  local source_kind="$1"
  local source_name="$2"

  {
    find infrastructure/ apps/ -name "*.yaml" \
      -not -path "*/templates/*" \
      -not -path "*/charts/*" \
      -print0 \
      | SOURCE_KIND="$source_kind" SOURCE_NAME="$source_name" \
        xargs -0 -r yq e \
          'select(.kind == strenv(SOURCE_KIND) and .metadata.name == strenv(SOURCE_NAME)) | filename' \
      | head -n 1
  } || true
}

pull_chart() {
  local chart_ref="$1"
  local chart_version="$2"
  local destination="$3"
  local -a pull_args=(pull "$chart_ref" --untar --untardir "$destination")

  if [[ -n "$chart_version" ]]; then
    pull_args+=(--version "$chart_version")
  fi

  helm "${pull_args[@]}"
}

find_pulled_chart() {
  local destination="$1"
  local chart_file

  chart_file=$(find "$destination" -mindepth 2 -maxdepth 2 -type f -name Chart.yaml -print -quit)
  if [[ -z "$chart_file" ]]; then
    echo "ERROR: Helm did not extract a chart under '$destination'" >&2
    exit 1
  fi

  dirname "$chart_file"
}

prepare_chart_dependencies() {
  local chart_path="$1"

  if [[ "$(yq -r '.dependencies | length' "$chart_path/Chart.yaml")" -gt 0 ]]; then
    helm dependency build "$chart_path"
  fi
}

# 2. Resolve the old and new chart directories according to the Flux source
# kind. GitRepository charts are paths inside a Git artifact; chart versions
# only apply to HelmRepository sources.
case "$SOURCE_KIND" in
  HelmRepository)
    SOURCE_FILE=$(find_source_file "$SOURCE_KIND" "$SOURCE_NAME")
    if [[ -z "$SOURCE_FILE" ]]; then
      echo "ERROR: Could not find $SOURCE_KIND '$SOURCE_NAME' under infrastructure/ or apps/" >&2
      exit 1
    fi

    OLD_VERSION=$(printf '%s\n' "$BASE_HELMRELEASE" | yq -r '.spec.chart.spec.version // ""')
    NEW_VERSION=$(yq -r '.spec.chart.spec.version // ""' "$HELMRELEASE_PATH")
    REPO_URL=$(yq -r '.spec.url' "$SOURCE_FILE")
    REPO_TYPE=$(yq -r '.spec.type // "default"' "$SOURCE_FILE")
    OLD_CHART_DIR="$WORK_DIR/old-chart"
    NEW_CHART_DIR="$WORK_DIR/new-chart"
    mkdir -p "$OLD_CHART_DIR" "$NEW_CHART_DIR"

    if [[ "${REPO_TYPE,,}" == "oci" ]]; then
      CHART_REF="${REPO_URL%/}/${CHART_NAME}"
      echo "Pulling OCI chart: $CHART_REF"
    elif [[ "$REPO_TYPE" == "default" || -z "$REPO_TYPE" ]]; then
      helm repo add "$SOURCE_NAME" "$REPO_URL" --force-update
      CHART_REF="$SOURCE_NAME/$CHART_NAME"
    else
      echo "ERROR: Unsupported HelmRepository type '$REPO_TYPE' for '$SOURCE_NAME'" >&2
      exit 1
    fi

    pull_chart "$CHART_REF" "$OLD_VERSION" "$OLD_CHART_DIR"
    pull_chart "$CHART_REF" "$NEW_VERSION" "$NEW_CHART_DIR"
    OLD_CHART_PATH=$(find_pulled_chart "$OLD_CHART_DIR")
    NEW_CHART_PATH=$(find_pulled_chart "$NEW_CHART_DIR")
    ;;

  GitRepository)
    SOURCE_FILE=$(find_source_file "$SOURCE_KIND" "$SOURCE_NAME")
    if [[ -z "$SOURCE_FILE" ]]; then
      echo "ERROR: Could not find $SOURCE_KIND '$SOURCE_NAME' under infrastructure/ or apps/" >&2
      exit 1
    fi

    BASE_CHART_TREE="$WORK_DIR/base-tree"
    HEAD_CHART_TREE="$WORK_DIR/head-tree"
    mkdir -p "$BASE_CHART_TREE" "$HEAD_CHART_TREE"

    # A chart present in this checkout belongs to this repository. Preserve the
    # base and PR chart revisions so chart-template changes are also previewed.
    if [[ -f "$CHART_PATH/Chart.yaml" ]] \
      && git cat-file -e "origin/${BASE_REF}:$CHART_PATH/Chart.yaml" 2>/dev/null; then
      git archive "origin/${BASE_REF}" "$CHART_PATH" | tar -x -C "$BASE_CHART_TREE"
      git archive HEAD "$CHART_PATH" | tar -x -C "$HEAD_CHART_TREE"
      OLD_CHART_PATH="$BASE_CHART_TREE/$CHART_PATH"
      NEW_CHART_PATH="$HEAD_CHART_TREE/$CHART_PATH"
    else
      GIT_URL=$(yq -r '.spec.url' "$SOURCE_FILE")
      GIT_BRANCH=$(yq -r '.spec.ref.branch // ""' "$SOURCE_FILE")
      GIT_TAG=$(yq -r '.spec.ref.tag // ""' "$SOURCE_FILE")
      GIT_COMMIT=$(yq -r '.spec.ref.commit // ""' "$SOURCE_FILE")
      GIT_SEMVER=$(yq -r '.spec.ref.semver // ""' "$SOURCE_FILE")
      GIT_SOURCE_DIR="$WORK_DIR/git-source"

      if [[ -n "$GIT_SEMVER" ]]; then
        echo "ERROR: GitRepository semver refs are not supported for '$SOURCE_NAME'" >&2
        exit 1
      elif [[ -n "$GIT_COMMIT" ]]; then
        git clone --filter=blob:none --no-checkout "$GIT_URL" "$GIT_SOURCE_DIR"
        git -C "$GIT_SOURCE_DIR" fetch --depth 1 origin "$GIT_COMMIT"
        git -C "$GIT_SOURCE_DIR" checkout --detach FETCH_HEAD
      elif [[ -n "$GIT_TAG" ]]; then
        git clone --depth 1 --branch "$GIT_TAG" "$GIT_URL" "$GIT_SOURCE_DIR"
      elif [[ -n "$GIT_BRANCH" ]]; then
        git clone --depth 1 --branch "$GIT_BRANCH" "$GIT_URL" "$GIT_SOURCE_DIR"
      else
        git clone --depth 1 "$GIT_URL" "$GIT_SOURCE_DIR"
      fi

      OLD_CHART_PATH="$GIT_SOURCE_DIR/$CHART_PATH"
      NEW_CHART_PATH="$GIT_SOURCE_DIR/$CHART_PATH"
    fi

    if [[ ! -f "$OLD_CHART_PATH/Chart.yaml" || ! -f "$NEW_CHART_PATH/Chart.yaml" ]]; then
      echo "ERROR: Chart path '$CHART_PATH' was not found in GitRepository '$SOURCE_NAME'" >&2
      exit 1
    fi

    prepare_chart_dependencies "$OLD_CHART_PATH"
    if [[ "$NEW_CHART_PATH" != "$OLD_CHART_PATH" ]]; then
      prepare_chart_dependencies "$NEW_CHART_PATH"
    fi
    ;;

  *)
    echo "ERROR: Unsupported HelmRelease source kind '$SOURCE_KIND' for '$SOURCE_NAME'" >&2
    exit 1
    ;;
esac

# Remove chart version labels that always change with the chart version
clean_manifest() {
  yq eval '
    del(.. | select(has("metadata")) .metadata.labels."helm.sh/chart") |
    del(.. | select(has("metadata")) .metadata.labels."chart") |
    del(.. | select(has("metadata")) .metadata.labels."app.kubernetes.io/version")
  ' -
}

# Render twice so fields generated randomly by a chart can be identified. A
# field is ignored only when it changes between identical renders on both the
# base and head sides; a generated-to-explicit value change remains visible.
render_manifest() {
  local chart_path="$1"
  local values_file="$2"
  local output_file="$3"

  helm template pr-preview "$chart_path" -f "$values_file" --namespace dummy \
    | clean_manifest > "$output_file"
}

find_nondeterministic_paths() {
  local old_first="$1"
  local old_second="$2"
  local new_first="$3"
  local new_second="$4"
  local output_file="$5"

  jq -n \
    --slurpfile old_first "$old_first" \
    --slurpfile old_second "$old_second" \
    --slurpfile new_first "$new_first" \
    --slurpfile new_second "$new_second" '
      def differing_paths($left; $right):
        (([$left | paths(scalars)] + [$right | paths(scalars)]) | unique) as $all_paths
        | [$all_paths[] as $path
            | select(($left | getpath($path)) != ($right | getpath($path)))
            | $path];

      differing_paths($old_first[0]; $old_second[0]) as $old_random
      | differing_paths($new_first[0]; $new_second[0]) as $new_random
      | [$old_random[] as $path
          | select(any($new_random[]; . == $path))
          | $path]
      | unique
    ' > "$output_file"
}

OLD_MANIFEST_FILE="$WORK_DIR/old-manifests.yaml"
OLD_CONTROL_FILE="$WORK_DIR/old-manifests-control.yaml"
NEW_MANIFEST_FILE="$WORK_DIR/new-manifests.yaml"
NEW_CONTROL_FILE="$WORK_DIR/new-manifests-control.yaml"
render_manifest "$OLD_CHART_PATH" "$OLD_VALUES_FILE" "$OLD_MANIFEST_FILE"
render_manifest "$OLD_CHART_PATH" "$OLD_VALUES_FILE" "$OLD_CONTROL_FILE"
render_manifest "$NEW_CHART_PATH" "$NEW_VALUES_FILE" "$NEW_MANIFEST_FILE"
render_manifest "$NEW_CHART_PATH" "$NEW_VALUES_FILE" "$NEW_CONTROL_FILE"

OLD_MANIFEST_JSON="$WORK_DIR/old-manifests.json"
OLD_CONTROL_JSON="$WORK_DIR/old-manifests-control.json"
NEW_MANIFEST_JSON="$WORK_DIR/new-manifests.json"
NEW_CONTROL_JSON="$WORK_DIR/new-manifests-control.json"
yq eval-all -o json -I=0 '[.]' "$OLD_MANIFEST_FILE" > "$OLD_MANIFEST_JSON"
yq eval-all -o json -I=0 '[.]' "$OLD_CONTROL_FILE" > "$OLD_CONTROL_JSON"
yq eval-all -o json -I=0 '[.]' "$NEW_MANIFEST_FILE" > "$NEW_MANIFEST_JSON"
yq eval-all -o json -I=0 '[.]' "$NEW_CONTROL_FILE" > "$NEW_CONTROL_JSON"

NONDETERMINISTIC_PATHS="$WORK_DIR/nondeterministic-paths.json"
find_nondeterministic_paths \
  "$OLD_MANIFEST_JSON" "$OLD_CONTROL_JSON" \
  "$NEW_MANIFEST_JSON" "$NEW_CONTROL_JSON" \
  "$NONDETERMINISTIC_PATHS"

if [[ "$(jq 'length' "$NONDETERMINISTIC_PATHS")" -gt 0 ]]; then
  OLD_NORMALIZED_JSON="$WORK_DIR/old-manifests-normalized.json"
  NEW_NORMALIZED_JSON="$WORK_DIR/new-manifests-normalized.json"
  jq --slurpfile paths "$NONDETERMINISTIC_PATHS" 'delpaths($paths[0])' \
    "$OLD_MANIFEST_JSON" > "$OLD_NORMALIZED_JSON"
  jq --slurpfile paths "$NONDETERMINISTIC_PATHS" 'delpaths($paths[0])' \
    "$NEW_MANIFEST_JSON" > "$NEW_NORMALIZED_JSON"
  yq -P '.[] | split_doc' "$OLD_NORMALIZED_JSON" > "$OLD_MANIFEST_FILE"
  yq -P '.[] | split_doc' "$NEW_NORMALIZED_JSON" > "$NEW_MANIFEST_FILE"
fi

diff_output=$(git diff --no-index -- "$OLD_MANIFEST_FILE" "$NEW_MANIFEST_FILE") || true

# 4. Post PR comment
MAX_COMMENT_SIZE=65536

if [[ -n "$diff_output" ]]; then
  # Add a diff header
  header="## :eyes: HelmRelease Diff for \`$HELMRELEASE_PATH\`"
  full_body="${header}"$'\n'$'```diff\n'"${diff_output}"$'\n''```'

  if [[ ${#full_body} -le $MAX_COMMENT_SIZE ]]; then
    echo "$full_body" | gh pr comment "$PR_NUMBER" --body-file -
  else
    echo "Diff too large (${#full_body} chars) – creating Gist..."
    
    GIST_URL=$(GH_TOKEN="$GH_GIST_TOKEN" gh gist create \
      --public \
      --desc "Helm diff for ${HELMRELEASE_PATH} (PR #${PR_NUMBER})" \
      --filename "diff.md" \
      <<< "$full_body")

    comment_body="## :eyes: HelmRelease Diff for \`$HELMRELEASE_PATH\`"
    comment_body+=$'\n\n'"⚠️ The diff is too large to display inline."
    comment_body+=$'\n\n'"🔗 **[View full diff in Gist](${GIST_URL})**"

    echo "$comment_body" | gh pr comment "$PR_NUMBER" --body-file -
  fi
else
  echo "No changes detected." | gh pr comment "$PR_NUMBER" --body-file -
fi
