#!/usr/bin/env bats

setup() {
  export TEST_TEMP_DIR=$(mktemp -d)
  export SCRIPT_FILE="$TEST_TEMP_DIR/script.sh"
  export RESULTS_DIR="$TEST_TEMP_DIR/results"
  export MOCK_BIN="$TEST_TEMP_DIR/mock-bin"
  mkdir -p "$RESULTS_DIR" "$MOCK_BIN"
  export PATH="$MOCK_BIN:$PATH"

  # Create mock directories and files
  mkdir -p "$TEST_TEMP_DIR/mnt/advisory_secret" "$TEST_TEMP_DIR/mnt/errata_secret"
  echo "gitlab.com" > "$TEST_TEMP_DIR/mnt/advisory_secret/gitlab_host"
  echo "token" > "$TEST_TEMP_DIR/mnt/advisory_secret/gitlab_access_token"
  echo "Author" > "$TEST_TEMP_DIR/mnt/advisory_secret/git_author_name"
  echo "author@test.com" > "$TEST_TEMP_DIR/mnt/advisory_secret/git_author_email"
  echo "https://gitlab.com/repo.git" > "$TEST_TEMP_DIR/mnt/advisory_secret/git_repo"
  
  echo "https://errata.api" > "$TEST_TEMP_DIR/mnt/errata_secret/errata_api"
  echo "sa_name" > "$TEST_TEMP_DIR/mnt/errata_secret/name"
  echo "base64keytab" > "$TEST_TEMP_DIR/mnt/errata_secret/base64_keytab"

  mkdir -p "$TEST_TEMP_DIR/tmp"
  mkdir -p "$TEST_TEMP_DIR/home/utils" "$TEST_TEMP_DIR/home/templates"
  mkdir -p "$TEST_TEMP_DIR/etc"
  echo "[libdefaults]" > "$TEST_TEMP_DIR/etc/krb5.conf"

  cat << 'EOF' > "$TEST_TEMP_DIR/home/utils/gitlab-functions"
gitlab_init() { echo "gitlab_init called"; }
retry() {
  local retries=$1
  shift
  local count=0
  until "$@"; do
    exit=$?
    wait=$((2 ** count))
    count=$((count + 1))
    if [ $count -lt "$retries" ]; then
      echo "Retry $count/$retries exited $exit, retrying in $wait seconds..."
    else
      echo "Retry $count/$retries exited $exit, no more retries left."
      return $exit
    fi
  done
  return 0
}
EOF

  cat << 'EOF' > "$TEST_TEMP_DIR/home/utils/git-functions"
git_functions_init() { echo "git_functions_init called"; }
git_clone_and_checkout() { echo "git_clone_and_checkout $*"; mkdir -p data/advisories/test-origin schema; }
git_push_with_retries() { echo "git_push_with_retries $*"; }
EOF

  cat << 'EOF' > "$TEST_TEMP_DIR/home/utils/apply_template.py"
#!/usr/bin/env bash
echo "apply_template.py $*"
while [[ $# -gt 0 ]]; do
  case $1 in
    -o) touch "$2"; shift 2 ;;
    *) shift ;;
  esac
done
EOF
  chmod +x "$TEST_TEMP_DIR/home/utils/apply_template.py"

  # Mocks
  cat << 'EOF' > "$MOCK_BIN/check-jsonschema"
#!/usr/bin/env bash
echo "check-jsonschema $*"
if [[ "$MOCK_JSONSCHEMA_FAIL" == "true" ]]; then
  exit 1
fi
exit 0
EOF
  chmod +x "$MOCK_BIN/check-jsonschema"

  cat << 'EOF' > "$MOCK_BIN/kubectl"
#!/usr/bin/env bash
if [[ "$1" == "get" && "$2" == "configmap" ]]; then
  echo "mocked-signing-key"
else
  echo "" >&2
  exit 0
fi
EOF
  chmod +x "$MOCK_BIN/kubectl"

  cat << 'EOF' > "$MOCK_BIN/kinit"
#!/usr/bin/env bash
echo "kinit $*"
if [[ "$MOCK_KINIT_FAIL" == "true" ]]; then
  exit 1
fi
exit 0
EOF
  chmod +x "$MOCK_BIN/kinit"

  cat << 'EOF' > "$MOCK_BIN/curl"
#!/usr/bin/env bash
if [[ "$*" == *"/advisory/reserve_live_id"* ]]; then
  if [[ "$MOCK_CURL_FAIL" == "true" ]]; then
    exit 1
  fi
  echo '{"live_id": 5678}'
else
  echo "" >&2
  exit 0
fi
EOF
  chmod +x "$MOCK_BIN/curl"

  cat << 'EOF' > "$MOCK_BIN/git"
#!/usr/bin/env bash
if [[ "$1" == "ls-tree" ]]; then
  if [[ -n "$MOCK_GIT_LS_TREE" ]]; then
    echo "$MOCK_GIT_LS_TREE"
  else
    echo "some/other/file"
  fi
elif [[ "$1" == "add" ]]; then
  echo "git add $2"
elif [[ "$1" == "commit" ]]; then
  echo "git commit $*"
else
  echo "git $*"
fi
EOF
  chmod +x "$MOCK_BIN/git"

  cat << 'EOF' > "$MOCK_BIN/date"
#!/usr/bin/env bash
echo "2024-03-06T17:27:38Z"
EOF
  chmod +x "$MOCK_BIN/date"

  cat << 'EOF' > "$MOCK_BIN/yq"
#!/usr/bin/env bash
if [[ "$1" == "-o=json" ]]; then
  if [[ -f "$MOCK_YQ_EXISTING_CONTENT" ]]; then
    cat "$MOCK_YQ_EXISTING_CONTENT"
  else
    echo "[]"
  fi
elif [[ "$1" == "eval" && "$2" == "-o" && "$3" == "yaml" ]]; then
  cat "$4"
elif [[ "$1" == "-r" ]]; then
  if [[ "$2" == ".spec.type" ]]; then
    echo "RHSA"
  elif [[ "$2" == ".metadata.name" ]]; then
    echo "12345"
  fi
else
  echo ""
fi
EOF
  chmod +x "$MOCK_BIN/yq"

  cat << 'EOF' > "$MOCK_BIN/find"
#!/usr/bin/env bash
if [[ "$*" == *"-printf"* ]]; then
  if [ -d "$1" ]; then
    shopt -s nullglob
    for year in "$1"/*; do
      if [ -d "$year" ]; then
        for adv in "$year"/*; do
          if [ -d "$adv" ]; then
            echo "1700000000.0000000000 $adv"
          fi
        done
      fi
    done
  fi
else
  "$(which -a find | grep -v "$MOCK_BIN" | head -n 1)" "$@"
fi
EOF
  chmod +x "$MOCK_BIN/find"

  cat << 'EOF' > "$MOCK_BIN/base64"
#!/usr/bin/env bash
cat
EOF
  chmod +x "$MOCK_BIN/base64"

  cat << 'EOF' > "$MOCK_BIN/gunzip"
#!/usr/bin/env bash
cat
EOF
  chmod +x "$MOCK_BIN/gunzip"

  cat << 'SCRIPT_EOF' > "$SCRIPT_FILE"
#!/usr/bin/env bash
set -eo pipefail

GITLAB_HOST="$(cat /mnt/advisory_secret/gitlab_host)"

# This is a GitLab Project access token. Go to the settings/access_tokens page
# of your repository to create one. It should have the Developer role with read
# and write repository rights.
ACCESS_TOKEN="$(cat /mnt/advisory_secret/gitlab_access_token)"

GIT_AUTHOR_NAME="$(cat /mnt/advisory_secret/git_author_name)"
GIT_AUTHOR_EMAIL="$(cat /mnt/advisory_secret/git_author_email)"
GIT_REPO="$(cat /mnt/advisory_secret/git_repo)"
ERRATA_API="$(cat /mnt/errata_secret/errata_api)"
SERVICE_ACCOUNT_NAME="$(cat /mnt/errata_secret/name)"
SERVICE_ACCOUNT_KEYTAB="$(cat /mnt/errata_secret/base64_keytab)"

# export variables required by the called script "gitlab-functions" in release-service-utils
export GITLAB_HOST ACCESS_TOKEN GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL

STDERR_FILE=/tmp/stderr.txt
echo -n "$(params.internalRequestPipelineRunName)" > "$(results.internalRequestPipelineRunName.path)"
echo -n "$(context.taskRun.name)" > "$(results.internalRequestTaskRunName.path)"

exitfunc() {
    local err=$1
    local line=$2
    local command="$3"
    if [ "$err" -eq 0 ] ; then
        echo -n "Success" > "$(results.result.path)"
    else
        echo -n \
          "$0: ERROR '$command' failed at line $line - exited with status $err" > "$(results.result.path)"
        if [ -f "$STDERR_FILE" ] ; then
            tail -n 20 "$STDERR_FILE" >> "$(results.result.path)"
        fi
    fi
    echo -n "${ADVISORY_URL}" > "$(results.advisory_url.path)"
    echo -n "${ADVISORY_INTERNAL_URL}" > "$(results.advisory_internal_url.path)"
    exit 0 # exit the script cleanly as there is no point in proceeding past an error or exit call
}
# due to set -e, this catches all EXIT and ERR calls and the task should never fail with nonzero exit code
trap 'exitfunc $? $LINENO "$BASH_COMMAND"' EXIT

REPO_BRANCH=main
ADVISORY_URL=""
ADVISORY_INTERNAL_URL=""
ADVISORY_BASE_DIR="data/advisories/$(params.origin)"
if [[ "${GIT_REPO}" == *"/rhtap-release/"* ]]; then
  ADVISORY_URL_PREFIX="https://access.stage.redhat.com/errata"
else
  ADVISORY_URL_PREFIX="https://access.redhat.com/errata"
fi

# Switch to /tmp to avoid filesystem permission issues
cd /tmp

# loading git and gitlab functions
# shellcheck source=/dev/null
. /home/utils/gitlab-functions
# shellcheck source=/dev/null
. /home/utils/git-functions
gitlab_init
git_functions_init

# This also cds into the git repo
git_clone_and_checkout --repository "$GIT_REPO" --revision "$REPO_BRANCH" \
  --sparse-dir "$ADVISORY_BASE_DIR" --sparse-dir schema

if [ "$(params.contentType)" = "image" ]; then
  echo "Content type is image."
  spec_content_type=".content.images"
elif [ "$(params.contentType)" == "binary" ] || [ "$(params.contentType)" == "generic" ] \
|| [ "$(params.contentType)" == "rpm" ]; then
  echo "Content type is generic or rpm artifact."
  spec_content_type=".content.artifacts"
else
  echo "Unsupported contentType: $(params.contentType)"| tee -a "$STDERR_FILE"
  echo "Exiting." | tee -a "$STDERR_FILE"
  exit 1
fi
CONTENT_FILE=/tmp/content.json
# Write the advisory JSON parameter to a file to avoid argument length limits
printf '%s' "$ADVISORY_JSON" | base64 --decode | gunzip > /tmp/advisory_decoded.json
jq -c "${spec_content_type} // []" /tmp/advisory_decoded.json > "$CONTENT_FILE"

# Use ISO 8601 format in UTC/Zulu time, e.g. 2024-03-06T17:27:38Z
SHIP_DATE=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
YEAR=${SHIP_DATE%%-*} # derive the year from the ship date
# Define advisory directory
echo "Checking advisories in directory: ${ADVISORY_BASE_DIR}"

# Check existing advisories across ALL years
EXISTING_ADVISORIES=""
if [ -d "${ADVISORY_BASE_DIR}" ]; then
  EXISTING_ADVISORIES=$(
    # year/advisory dir with modified time
    find "${ADVISORY_BASE_DIR}" -mindepth 2 -type d -printf "%T@ %p\n" |
    sort -nr |                       # sort by latest modified first
    cut -d' ' -f2- |                 # remove the timestamp, keep only path
    sed "s|^${ADVISORY_BASE_DIR}/||" # keeping year/advisory format
  )
fi

if [[ -z "$EXISTING_ADVISORIES" ]]; then
    echo "No existing advisories found."
fi

# Track the latest advisory that contains matching content
# EXISTING_ADVISORIES is sorted by modification time (newest first)
LATEST_ADVISORY_FILE=""

EXISTING_CONTENT=/tmp/existing_content.json
for ADVISORY_SUBDIR in $EXISTING_ADVISORIES; do
    ADVISORY_FILE="${ADVISORY_BASE_DIR}/${ADVISORY_SUBDIR}/advisory.yaml"
    yq -o=json ".spec${spec_content_type} // []" "${ADVISORY_FILE}" > "$EXISTING_CONTENT"
    echo "Processing advisory: ${ADVISORY_FILE}"
    echo "Existing content in advisory: "
    cat "$EXISTING_CONTENT"

    # Check if this advisory contains any matching content before filtering
    CONTENT_BEFORE_FILTER=$(cat "$CONTENT_FILE")

    # Update CONTENT by removing entries that already exist in the advisory
    if [ "$(params.contentType)" == "generic" ] || [ "$(params.contentType)" == "binary" ]; then
      # Use purl as unique key, but strip checksum= for comparison
      # This allows re-releases (with new checksums from re-signing) to update existing advisories
      # The filename= param (if present) ensures we match the correct file
      jq --slurpfile existing "$EXISTING_CONTENT" '
        # Function to strip checksum param from purl for comparison
        def strip_checksum:
          gsub("&checksum=[^&]*"; "") | gsub("\\?checksum=[^&]*&"; "?") | gsub("\\?checksum=[^&]*$"; "");
        map(select(
          (.purl | strip_checksum) as $p |
          ($existing[0] | map(select((.purl | strip_checksum) == $p)) | length == 0)
        ))' "$CONTENT_FILE" > /tmp/content_filtered.json
    elif [ "$(params.contentType)" == "rpm" ] || [ "$(params.contentType)" == "disk-image" ]; then
      # Use exact purl matching for RPM and disk-image (checksums are stable, no re-signing)
      jq --slurpfile existing "$EXISTING_CONTENT" '
        map(select(
          .purl as $p |
          ($existing[0] | map(select(.purl == $p)) | length == 0)
        ))' "$CONTENT_FILE" > /tmp/content_filtered.json
    else
      jq --slurpfile existing "$EXISTING_CONTENT" '
        map(select(
          .containerImage as $ci |
          .tags as $tags |
          .repository as $repo |
          ($existing[0] | map(select(
            .containerImage == $ci and .tags == $tags and .repository == $repo
          )) | length == 0)
        ))' "$CONTENT_FILE" > /tmp/content_filtered.json
    fi

    mv /tmp/content_filtered.json "$CONTENT_FILE"

    echo "Remaining entries after filtering:"
    cat "$CONTENT_FILE"

    CONTENT_BEFORE_COUNT=$(jq 'length' <<< "$CONTENT_BEFORE_FILTER")
    CONTENT_AFTER_COUNT=$(jq 'length' "$CONTENT_FILE")
    if [[ $CONTENT_BEFORE_COUNT -gt $CONTENT_AFTER_COUNT ]]; then
      if [[ -z "$LATEST_ADVISORY_FILE" ]]; then
        LATEST_ADVISORY_FILE="$ADVISORY_FILE"
        FILTERED_COUNT=$((CONTENT_BEFORE_COUNT - CONTENT_AFTER_COUNT))
        echo "Tracked latest advisory: $LATEST_ADVISORY_FILE (filtered $FILTERED_COUNT items)"
      fi
    fi

    # If after filtering, no entries are left, then we can exit early
    if jq -e 'length == 0' "$CONTENT_FILE" >/dev/null; then
        echo "All content found in existing advisories. Skipping creation."
        echo "Returning advisory: $LATEST_ADVISORY_FILE"

        ADVISORY_INTERNAL_URL="${GIT_REPO//\.git/}/-/raw/main/${LATEST_ADVISORY_FILE}"
        ADVISORY_TYPE=$(yq -r '.spec.type' "${LATEST_ADVISORY_FILE}")
        ADVISORY_NAME=$(yq -r '.metadata.name' "${LATEST_ADVISORY_FILE}")
        ADVISORY_URL="${ADVISORY_URL_PREFIX}/${ADVISORY_TYPE}-${ADVISORY_NAME}"
        echo -n "Success" > "$(results.result.path)"
        echo -n "${ADVISORY_URL}" > "$(results.advisory_url.path)"
        echo -n "$ADVISORY_INTERNAL_URL" > "$(results.advisory_internal_url.path)"
        exit 0
    fi
done

NEW_ADVISORY_JSON=$(jq --slurpfile new_content "$CONTENT_FILE" \
  "${spec_content_type} = \$new_content[0]" /tmp/advisory_decoded.json)

signingKey=$(kubectl get configmap "$(params.config_map_name)" -o jsonpath="{.data.SIG_KEY_NAME}")
# Write to temp file to avoid argument length limits
echo "$NEW_ADVISORY_JSON" > /tmp/new_advisory.json
jq -c --arg key "$signingKey" \
  "${spec_content_type}[] += {\"signingKey\": \$key}" /tmp/new_advisory.json > /tmp/advisory_with_key.json

LIVE_ID=$(jq -r '.live_id' /tmp/advisory_decoded.json)
if [[ "$LIVE_ID" == null ]]; then
  # write keytab to file
  echo -n "${SERVICE_ACCOUNT_KEYTAB}" | base64 --decode > /tmp/keytab
  # workaround kinit: Invalid UID in persistent keyring name while getting default ccache
  KRB5CCNAME=$(mktemp)
  export KRB5CCNAME
  # see https://stackoverflow.com/a/12308187
  KRB5_CONFIG=$(mktemp)
  export KRB5_CONFIG
  export KRB5_TRACE=/dev/stderr
  sed '/\[libdefaults\]/a\    dns_canonicalize_hostname = false' /etc/krb5.conf > "${KRB5_CONFIG}"
  retry 5 kinit "${SERVICE_ACCOUNT_NAME}" -k -t /tmp/keytab
  REQUEST_URL="${ERRATA_API}/advisory/reserve_live_id"
  LIVE_ID=$(curl --retry 3 --negotiate -u : "${REQUEST_URL}" -XPOST | jq -r '.live_id')
fi
ADVISORY_NUM=$(printf "%04d" "$LIVE_ID")

# Check if the advisory number is already used
GIT_RESULT_FILE=$(mktemp)
git ls-tree -r --name-only origin/main > "$GIT_RESULT_FILE"
GREP_RESULT=$(grep "data/advisories/.*/${YEAR}/${ADVISORY_NUM}/" "$GIT_RESULT_FILE" || true)
if [[ -n "${GREP_RESULT}" ]]; then
  echo "An advisory with number ${ADVISORY_NUM} already exists:" | tee -a "$STDERR_FILE"
  echo "${GREP_RESULT}" | tee -a "$STDERR_FILE"
  echo "Exiting." | tee -a "$STDERR_FILE"
  exit 1
fi

# group advisories by <origin workspace>/year
ADVISORY_DIR="data/advisories/$(params.origin)/${YEAR}/${ADVISORY_NUM}"
mkdir -p "${ADVISORY_DIR}"
JSON_ADVISORY_FILEPATH="${ADVISORY_DIR}/advisory.json"
YAML_ADVISORY_FILEPATH="${ADVISORY_DIR}/advisory.yaml"
ADVISORY_NAME="${YEAR}:${ADVISORY_NUM}"

# Prepare variables for the advisory template
# Write to file to avoid argument length limits
jq -c '{"advisory":{"spec":.}}' /tmp/advisory_with_key.json > /tmp/template_data.json
jq -c --arg advisory_name "$ADVISORY_NAME" --arg advisory_ship_date "$SHIP_DATE" \
  '$ARGS.named + .' /tmp/template_data.json > /tmp/template_data_final.json

# Create advisory file using the apply_template.py script
/home/utils/apply_template.py -o "$JSON_ADVISORY_FILEPATH" --data-file /tmp/template_data_final.json \
--template /home/templates/advisory.yaml.jinja -v 2> "$STDERR_FILE"
 
# Convert to yaml for readability
yq eval -o yaml "$JSON_ADVISORY_FILEPATH" | tee "$YAML_ADVISORY_FILEPATH"

# Ensure the created advisory file passes the advisory schema
check-jsonschema --schemafile schema/advisory.json "$YAML_ADVISORY_FILEPATH" 2>&1 | tee "$STDERR_FILE"

git add "${YAML_ADVISORY_FILEPATH}"
git commit -m "[Konflux Release] new advisory for $(params.componentGroup)"
echo "Pushing to ${REPO_BRANCH}..."
git_push_with_retries --branch $REPO_BRANCH --retries 5 --url origin 2> "$STDERR_FILE"
# Construct the advisory url on customer portal to report back to the user as a result
ADVISORY_TYPE=$(jq -r '.type' /tmp/advisory_decoded.json)
ADVISORY_URL="${ADVISORY_URL_PREFIX}/${ADVISORY_TYPE}-${ADVISORY_NAME}"
ADVISORY_INTERNAL_URL="${GIT_REPO//\.git/}/-/raw/${REPO_BRANCH}/${YAML_ADVISORY_FILEPATH}"
SCRIPT_EOF

  # Replace parameters
  sed -i'' -e "s|\$(params.internalRequestPipelineRunName)|test-pipelinerun|g" "$SCRIPT_FILE"
  sed -i'' -e "s|\$(context.taskRun.name)|test-taskrun|g" "$SCRIPT_FILE"
  sed -i'' -e "s|\$(params.origin)|test-origin|g" "$SCRIPT_FILE"
  sed -i'' -e "s|\$(params.contentType)|\${CONTENT_TYPE:-image}|g" "$SCRIPT_FILE"
  sed -i'' -e "s|\$(params.config_map_name)|test-config-map|g" "$SCRIPT_FILE"
  sed -i'' -e "s|\$(params.componentGroup)|test-component-group|g" "$SCRIPT_FILE"

  # Replace results
  sed -i'' -e "s|\$(results.internalRequestPipelineRunName.path)|$RESULTS_DIR/internalRequestPipelineRunName|g" "$SCRIPT_FILE"
  sed -i'' -e "s|\$(results.internalRequestTaskRunName.path)|$RESULTS_DIR/internalRequestTaskRunName|g" "$SCRIPT_FILE"
  sed -i'' -e "s|\$(results.result.path)|$RESULTS_DIR/result|g" "$SCRIPT_FILE"
  sed -i'' -e "s|\$(results.advisory_url.path)|$RESULTS_DIR/advisory_url|g" "$SCRIPT_FILE"
  sed -i'' -e "s|\$(results.advisory_internal_url.path)|$RESULTS_DIR/advisory_internal_url|g" "$SCRIPT_FILE"

  # Replace paths
  sed -i'' -e "s|/mnt/advisory_secret|$TEST_TEMP_DIR/mnt/advisory_secret|g" "$SCRIPT_FILE"
  sed -i'' -e "s|/mnt/errata_secret|$TEST_TEMP_DIR/mnt/errata_secret|g" "$SCRIPT_FILE"
  sed -i'' -e "s|/home/utils|$TEST_TEMP_DIR/home/utils|g" "$SCRIPT_FILE"
  sed -i'' -e "s|/home/templates|$TEST_TEMP_DIR/home/templates|g" "$SCRIPT_FILE"
  sed -i'' -e "s|/etc/krb5.conf|$TEST_TEMP_DIR/etc/krb5.conf|g" "$SCRIPT_FILE"
  
  # Replace /tmp
  sed -i'' -e "s|cd /tmp|cd $TEST_TEMP_DIR/tmp|g" "$SCRIPT_FILE"
  sed -i'' -e "s|/tmp/|$TEST_TEMP_DIR/tmp/|g" "$SCRIPT_FILE"

  chmod +x "$SCRIPT_FILE"
}

teardown() {
  rm -rf "$TEST_TEMP_DIR"
}

@test "Unsupported content type" {
  export CONTENT_TYPE="unsupported"
  export ADVISORY_JSON='{"content":{"images":[]}}'
  run "$SCRIPT_FILE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Unsupported contentType: unsupported"* ]]
  [ -f "$RESULTS_DIR/result" ]
  [[ "$(cat "$RESULTS_DIR/result")" == *"ERROR 'exit 1' failed"* ]]
}

@test "Content type image, no existing advisories, reserves live_id" {
  export CONTENT_TYPE="image"
  export ADVISORY_JSON='{"type":"RHSA","content":{"images":[{"containerImage":"img","tags":["latest"],"repository":"repo"}]}}'
  run "$SCRIPT_FILE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Content type is image."* ]]
  [[ "$output" == *"No existing advisories found."* ]]
  [[ "$output" == *"Pushing to main..."* ]]
  [ -f "$RESULTS_DIR/result" ]
  [[ "$(cat "$RESULTS_DIR/result")" == "Success" ]]
  [ -f "$RESULTS_DIR/advisory_url" ]
  [[ "$(cat "$RESULTS_DIR/advisory_url")" == "https://access.redhat.com/errata/RHSA-2024:5678" ]]
}

@test "Content type generic, existing advisory with matching content, exits early" {
  export CONTENT_TYPE="generic"
  export ADVISORY_JSON='{"type":"RHSA","content":{"artifacts":[{"purl":"pkg:generic/test@1.0?checksum=123"}]}}'
  
  # Create existing advisory
  mkdir -p "$TEST_TEMP_DIR/tmp/data/advisories/test-origin/2024/1234"
  touch "$TEST_TEMP_DIR/tmp/data/advisories/test-origin/2024/1234/advisory.yaml"
  export MOCK_YQ_EXISTING_CONTENT="$TEST_TEMP_DIR/mock_existing.json"
  echo '[{"purl":"pkg:generic/test@1.0?checksum=456"}]' > "$MOCK_YQ_EXISTING_CONTENT"

  run "$SCRIPT_FILE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Content type is generic or rpm artifact."* ]]
  [[ "$output" == *"All content found in existing advisories. Skipping creation."* ]]
  [ -f "$RESULTS_DIR/result" ]
  [[ "$(cat "$RESULTS_DIR/result")" == "Success" ]]
  [ -f "$RESULTS_DIR/advisory_url" ]
  [[ "$(cat "$RESULTS_DIR/advisory_url")" == "https://access.redhat.com/errata/RHSA-12345" ]]
}

@test "Content type rpm, existing advisory with non-matching content, creates new advisory" {
  export CONTENT_TYPE="rpm"
  export ADVISORY_JSON='{"type":"RHSA","content":{"artifacts":[{"purl":"pkg:rpm/test@1.0"}]}}'
  
  # Create existing advisory
  mkdir -p "$TEST_TEMP_DIR/tmp/data/advisories/test-origin/2024/1234"
  touch "$TEST_TEMP_DIR/tmp/data/advisories/test-origin/2024/1234/advisory.yaml"
  export MOCK_YQ_EXISTING_CONTENT="$TEST_TEMP_DIR/mock_existing.json"
  echo '[{"purl":"pkg:rpm/other@1.0"}]' > "$MOCK_YQ_EXISTING_CONTENT"

  run "$SCRIPT_FILE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Content type is generic or rpm artifact."* ]]
  [[ "$output" == *"Pushing to main..."* ]]
  [ -f "$RESULTS_DIR/result" ]
  [[ "$(cat "$RESULTS_DIR/result")" == "Success" ]]
}

@test "Advisory number already exists in git ls-tree" {
  export CONTENT_TYPE="image"
  export ADVISORY_JSON='{"type":"RHSA","content":{"images":[{"containerImage":"img","tags":["latest"],"repository":"repo"}]}}'
  export MOCK_GIT_LS_TREE="data/advisories/test-origin/2024/5678/advisory.yaml"

  run "$SCRIPT_FILE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"An advisory with number 5678 already exists:"* ]]
  [ -f "$RESULTS_DIR/result" ]
  [[ "$(cat "$RESULTS_DIR/result")" == *"ERROR 'exit 1' failed"* ]]
}

@test "rhtap-release repo sets stage URL" {
  export CONTENT_TYPE="image"
  export ADVISORY_JSON='{"type":"RHSA","content":{"images":[{"containerImage":"img","tags":["latest"],"repository":"repo"}]}}'
  echo "https://gitlab.com/rhtap-release/repo.git" > "$TEST_TEMP_DIR/mnt/advisory_secret/git_repo"

  run "$SCRIPT_FILE"
  [ "$status" -eq 0 ]
  [ -f "$RESULTS_DIR/result" ]
  [[ "$(cat "$RESULTS_DIR/result")" == "Success" ]]
  [ -f "$RESULTS_DIR/advisory_url" ]
  [[ "$(cat "$RESULTS_DIR/advisory_url")" == "https://access.stage.redhat.com/errata/RHSA-2024:5678" ]]
}

@test "live_id is already present in ADVISORY_JSON" {
  export CONTENT_TYPE="image"
  export ADVISORY_JSON='{"type":"RHSA","live_id":9999,"content":{"images":[{"containerImage":"img","tags":["latest"],"repository":"repo"}]}}'

  run "$SCRIPT_FILE"
  [ "$status" -eq 0 ]
  [ -f "$RESULTS_DIR/result" ]
  [[ "$(cat "$RESULTS_DIR/result")" == "Success" ]]
  [ -f "$RESULTS_DIR/advisory_url" ]
  [[ "$(cat "$RESULTS_DIR/advisory_url")" == "https://access.redhat.com/errata/RHSA-2024:9999" ]]
}

@test "kinit fails" {
  export CONTENT_TYPE="image"
  export ADVISORY_JSON='{"type":"RHSA","content":{"images":[{"containerImage":"img","tags":["latest"],"repository":"repo"}]}}'
  export MOCK_KINIT_FAIL="true"

  run "$SCRIPT_FILE"
  [ "$status" -eq 0 ]
  [ -f "$RESULTS_DIR/result" ]
  [[ "$(cat "$RESULTS_DIR/result")" == *"ERROR"* ]]
}

@test "check-jsonschema fails" {
  export CONTENT_TYPE="image"
  export ADVISORY_JSON='{"type":"RHSA","content":{"images":[{"containerImage":"img","tags":["latest"],"repository":"repo"}]}}'
  export MOCK_JSONSCHEMA_FAIL="true"

  run "$SCRIPT_FILE"
  [ "$status" -eq 0 ]
  [ -f "$RESULTS_DIR/result" ]
  [[ "$(cat "$RESULTS_DIR/result")" == *"ERROR"* ]]
}

@test "Content type image, existing advisory with matching content, exits early" {
  export CONTENT_TYPE="image"
  export ADVISORY_JSON='{"type":"RHSA","content":{"images":[{"containerImage":"img","tags":["latest"],"repository":"repo"}]}}'
  
  # Create existing advisory
  mkdir -p "$TEST_TEMP_DIR/tmp/data/advisories/test-origin/2024/1234"
  touch "$TEST_TEMP_DIR/tmp/data/advisories/test-origin/2024/1234/advisory.yaml"
  export MOCK_YQ_EXISTING_CONTENT="$TEST_TEMP_DIR/mock_existing.json"
  echo '[{"containerImage":"img","tags":["latest"],"repository":"repo"}]' > "$MOCK_YQ_EXISTING_CONTENT"

  run "$SCRIPT_FILE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Content type is image."* ]]
  [[ "$output" == *"All content found in existing advisories. Skipping creation."* ]]
  [ -f "$RESULTS_DIR/result" ]
  [[ "$(cat "$RESULTS_DIR/result")" == "Success" ]]
}

@test "curl fails" {
  export CONTENT_TYPE="image"
  export ADVISORY_JSON='{"type":"RHSA","content":{"images":[{"containerImage":"img","tags":["latest"],"repository":"repo"}]}}'
  export MOCK_CURL_FAIL="true"

  run "$SCRIPT_FILE"
  [ "$status" -eq 0 ]
  [ -f "$RESULTS_DIR/result" ]
  [[ "$(cat "$RESULTS_DIR/result")" == *"ERROR"* ]]
}