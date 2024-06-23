#!/bin/bash

set -eo pipefail
if [ -n "$DEBUG" ]; then set -x; fi
trap 'echo "Error: $? at line $LINENO" >&2' ERR

# Usage function to display help
usage() {
    echo "Usage: $0 [OPTIONS]"
    echo "Options:"
    echo "  -b, --bundle-version <bundle-version>   Specify the bundle version"
    echo "  -l, --local-path <local-path>           Specify the local path to download files"
    echo "  -n, --release-name <release-name>       Specify the release name"
    echo "  -v, --artifact-version <artifact-version>    Specify the artifact version"
    echo "  -h, --help                              Display this help message"
    exit 1
}

# Parse command-line arguments
while [[ "$#" -gt 0 ]]; do
    case $1 in
        -n|--release-name)
            RELEASE_NAME="$2"
            shift 2
            ;;
        -v|--artifact-version)
            ARTIFACT_VERSION="$2"
            shift 2
            ;;
        -l|--local-path)
            LOCAL_PATH="$2"
            shift 2
            ;;
        -b|--bundle-version)
            BUNDLE_VERSION="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            usage
            ;;
    esac
done

# Verify that all required variables are set
if [ -z "$RELEASE_NAME" ] || [ -z "$ARTIFACT_VERSION" ] || [ -z "$LOCAL_PATH" ] || [ -z "$BUNDLE_VERSION" ]; then
    usage
fi

# Hardcoded server ID could possibly be omitted but jfrog apis give it.
SERVER_ID="aerospike"

# Check if we have a bundle with the given name.
if jf rt curl -X GET "/api/v2/release_bundle/names?project=ecosystem" --server-id "$SERVER_ID" | jq 'any(.release_bundles[]; .release_bundle_name == "$RELEASE_NAME")'; then
    echo "Release bundle '$RELEASE_NAME' found."
else
    echo "Error: Release bundle '$RELEASE_NAME' not found." >&2
    exit 1
fi

# List artifacts in the repository for the given bundle version
echo "Listing artifacts in the repository for bundle ${RELEASE_NAME}-${ARTIFACT_VERSION}/${BUNDLE_VERSION}..."
echo "fail if no artifacts are found."

JFROG_CLI_FAIL_NO_OP=true jf rt search --server-id "$SERVER_ID" --spec <(cat <<EOF
{
  "files": [
    {
      "aql": {
        "items.find": {
          "repo": {"\$eq": "ecosystem-release-bundles-v2"},
          "path": {"\$match": "${RELEASE_NAME}-${ARTIFACT_VERSION}/${BUNDLE_VERSION}**"}
        }
      }
    }
  ]
}
EOF
)

# Download artifacts using the spec
echo "Downloading artifacts..."
jf rt dl --server-id="$SERVER_ID" --flat=false \
    "ecosystem-release-bundles-v2/${RELEASE_NAME}-${ARTIFACT_VERSION}/${BUNDLE_VERSION}/**" \
    "$LOCAL_PATH/"

echo "Download completed."
