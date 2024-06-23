#!/bin/bash

set -eo pipefail
if [ -n "$DEBUG" ]; then set -x; fi
trap 'echo "Error: $? at line $LINENO" >&2' ERR

# Default values
RELEASE_NAME=aerospike-vector-search
DEFAULT_RELEASE_NUMBER=1
DEFAULT_ARTIFACT_VERSION="0.4.0"
DEFAULT_HELM_CHART_VERSION="0.2.0"
DEFAULT_BASE_DIR="/build"
SIGNING_KEY="aerospike"
SNYK_FILE=""

# Usage function
usage() {
echo "Usage: $0 [-r release_number] [-a artifact_version] [-c helm_chart_version] [-b base_directory] [--release-number release_number] [--artifact-version artifact_version] [--helm-chart-version helm_chart_version] [--base-directory base_directory] [--signing-key signing_key] [--snyk-file snyk_file] [-h|--help]"
exit 1
}

# Parse command-line options using getopt
OPTIONS=$(getopt -o r:a:c:b:k:f:h --long release-number:,artifact-version:,helm-chart-version:,base-directory:,signing-key:,snyk-file:,help -- "$@")
if [ $? -ne 0 ]; then
usage
fi

eval set -- "$OPTIONS"

# Initialize variables with default values
RELEASE_NUMBER=$DEFAULT_RELEASE_NUMBER
ARTIFACT_VERSION=$DEFAULT_ARTIFACT_VERSION
HELM_CHART_VERSION=$DEFAULT_HELM_CHART_VERSION
BASE_DIR=$DEFAULT_BASE_DIR

while true; do
case "$1" in
    -r|--release-number)
    RELEASE_NUMBER="$2"; shift 2;;
    -a|--artifact-version)
    ARTIFACT_VERSION="$2"; shift 2;;
    -c|--helm-chart-version)
    HELM_CHART_VERSION="$2"; shift 2;;
    -b|--base-directory)
    BASE_DIR="$2"; shift 2;;
    -k|--signing-key)
    SIGNING_KEY="$2"; shift 2;;
    -f|--snyk-file)
    SNYK_FILE="$2"; shift 2;;
    -h|--help)
    usage; shift;;
    --)
    shift; break;;
    *)
    usage;;
esac
done
BUILD_DIR="${BASE_DIR}/${RELEASE_NAME}/${ARTIFACT_VERSION}/${RELEASE_NUMBER}"

if [ -d "${BUILD_DIR}" ]; then
  echo "Error: Release ${RELEASE_NUMBER} already exists for ${RELEASE_NAME}. Cannot create a new release with the same version."
  exit 1
fi

mkdir -p "${BUILD_DIR}"
cp -r "${BUILD_DIR}/../current/"* "${BUILD_DIR}"

# Define artifact names
DOCKER_IMAGE_NAME="aerospike/aerospike-proximus:${ARTIFACT_VERSION}"
DOCKER_REPO="ecosystem-container-dev-local"
HELM_CHART="${BUILD_DIR}/helm/aerospike-vector-search-${HELM_CHART_VERSION}.tgz"
RPM_PACKAGE="${BUILD_DIR}/rpm/aerospike-proximus-${ARTIFACT_VERSION}-1.noarch.rpm"
DEB_PACKAGE="${BUILD_DIR}/deb/aerospike-proximus-${ARTIFACT_VERSION}.all.deb"
SBOM_FILE="${BUILD_DIR}/metadata/${RELEASE_NAME}-${ARTIFACT_VERSION}-sbom.json"
SNYK_REPORT="${BUILD_DIR}/metadata/snyk-report-${RELEASE_NAME}-${ARTIFACT_VERSION}.sarif"
SPEC_FILE="${BUILD_DIR}/metadata/spec-${RELEASE_NAME}.json"
RELEASE_BUNDLE_SPEC="${BUILD_DIR}/metadata/release-bundle-${RELEASE_NAME}.json"

# Compute paths based on release name, release number, and artifact names
SNYK_FILE_DEST="$BUILD_DIR/metadata/snyk-config"
SNYK_FILE_DOCKER_DIR="${BUILD_DIR}/.snyk"
RELEASE_BUNDLE_NAME="${RELEASE_NAME}-${ARTIFACT_VERSION}"

# Ensure required tools are installed
for cmd in docker jf syft jq snyk; do
  if ! command -v $cmd &> /dev/null; then
    echo "Error: $cmd is not installed." >&2
    exit 1
  fi
done

# Copy the Snyk file to the metadata directory and Docker tar directory
if [ -n "$SNYK_FILE" ]; then
  cp "${SNYK_FILE}" "${SNYK_FILE_DEST}"
  cp "${SNYK_FILE}" "${SNYK_FILE_DOCKER_DIR}"
fi

set +e
( 
cd "${BUILD_DIR}"
# Run Snyk test and generate SARIF report
snyk container test "${DOCKER_IMAGE_NAME}" --file="${SNYK_FILE_DEST}" --sarif-file-output="${SNYK_REPORT}" --policy-path="${SNYK_FILE_DOCKER_DIR}"
)
set -e
# Generate SBOM using Syft
syft "${DOCKER_IMAGE_NAME}" -o json > "${SBOM_FILE}"
touch "${HELM_CHART}" "${RPM_PACKAGE}" "${DEB_PACKAGE}" "${SBOM_FILE}" "${SNYK_REPORT}" "${SNYK_FILE_DEST}" "${SPEC_FILE}" "${RELEASE_BUNDLE_SPEC}"

# Push Docker image to Artifactory
docker tag "${DOCKER_IMAGE_NAME}" "aerospike.jfrog.io/${DOCKER_REPO}/${DOCKER_IMAGE_NAME#aerospike/}"
jf docker push "aerospike.jfrog.io/${DOCKER_REPO}/${DOCKER_IMAGE_NAME#aerospike/}" --build-name="${RELEASE_NAME}" --build-number="${ARTIFACT_VERSION}"
# Create spec file dynamically after all files are created
# and add any needed properties and coordinates (both in props)
# FIXME: These specs should all be templated and generated
cat <<EOF > "${SPEC_FILE}"
{
  "files": [
    {
      "pattern": "${HELM_CHART}",
      "target": "ecosystem-helm-dev-local/${RELEASE_NAME}/${HELM_CHART_VERSION}/",
      "props": "helm.chart=${RELEASE_NAME};helm.version=${HELM_CHART_VERSION}"
    },
    {
      "pattern": "${RPM_PACKAGE}",
      "target": "ecosystem-rpm-dev-local/${RELEASE_NAME}/${ARTIFACT_VERSION}/",
      "props": "rpm.name=${RELEASE_NAME};rpm.version=${ARTIFACT_VERSION}"
    },
    {
      "pattern": "${DEB_PACKAGE}",
      "target": "ecosystem-deb-dev-local/${RELEASE_NAME}/${ARTIFACT_VERSION}/",
      "props": "deb.name=${RELEASE_NAME};deb.version=${ARTIFACT_VERSION};deb.distribution=stable;deb.component=main;deb.architecture=all"
    },
    {
      "pattern": "${SBOM_FILE}",
      "target": "ecosystem-meta-dev-local/${RELEASE_NAME}/${RELEASE_NUMBER}/${ARTIFACT_VERSION}/"
    },
    {
      "pattern": "${SNYK_REPORT}",
      "target": "ecosystem-meta-dev-local/${RELEASE_NAME}/${RELEASE_NUMBER}/${ARTIFACT_VERSION}/"
    },
    {
      "pattern": "${SNYK_FILE_DEST}",
      "target": "ecosystem-meta-dev-local/${RELEASE_NAME}/${RELEASE_NUMBER}/${ARTIFACT_VERSION}/"
    },
    {
      "pattern": "${SPEC_FILE}",
      "target": "ecosystem-meta-dev-local/${RELEASE_NAME}/${RELEASE_NUMBER}/${ARTIFACT_VERSION}/"
    },
    {
      "pattern": "${RELEASE_BUNDLE_SPEC}",
      "target": "ecosystem-meta-dev-local/${RELEASE_NAME}/${RELEASE_NUMBER}/${ARTIFACT_VERSION}/"
    }
  ]
}
EOF

# Upload all artifacts using JF CLI
jf rt upload --spec="${SPEC_FILE}" --project=ecosystem

# Create release bundle specification dynamically with supported fields
cat <<EOF > "${RELEASE_BUNDLE_SPEC}"
{
  "version": "${RELEASE_NUMBER}",
  "release_notes": {
    "syntax": "markdown",
    "content": "Release notes for ${RELEASE_BUNDLE_NAME} version ${ARTIFACT_VERSION}"
  },
  "dry_run": false,
  "sign_immediately": false,
  "files": [
    {
      "pattern": "ecosystem-container-dev-local/aerospike-proximus/${ARTIFACT_VERSION}/*"
    },
    {
      "pattern": "ecosystem-helm-dev-local/${RELEASE_NAME}/${HELM_CHART_VERSION}/*"
    },
    {
      "pattern": "ecosystem-rpm-dev-local/${RELEASE_NAME}/${ARTIFACT_VERSION}/*"
    },
    {
      "pattern": "ecosystem-deb-dev-local/${RELEASE_NAME}/${ARTIFACT_VERSION}/*"
    },
    {
      "pattern": "ecosystem-meta-dev-local/${RELEASE_NAME}/${RELEASE_NUMBER}/${ARTIFACT_VERSION}/*"
    }
  ]
}
EOF

echo "Create the release bundle"
jf release-bundle-create "${RELEASE_BUNDLE_NAME}" "${RELEASE_NUMBER}" \
  --spec="${RELEASE_BUNDLE_SPEC}" --signing-key="${SIGNING_KEY}" --project=ecosystem

# Wait for the release bundle to be ready
echo "Waiting for the release bundle to be ready"

ii=0

while [ $ii -lt 6 ]; do
  STATUS=$(jf rt curl -X GET "/api/v2/release_bundle/statuses/${RELEASE_BUNDLE_NAME}/${RELEASE_NUMBER}?project=ecosystem" | jq -r '.status')
  if [ "$STATUS" == "COMPLETED" ]; then
    echo "Release bundle is ready for promotion"
    break
  fi
  echo "Current status: $STATUS. Waiting..."
  sleep 1
  ii=$((ii + 1))
done

# Promote the release bundle
echo "Promoting release to DEV"
jf release-bundle-promote "${RELEASE_BUNDLE_NAME}" "${RELEASE_NUMBER}" DEV --signing-key="${SIGNING_KEY}" --project=ecosystem \
  --include-repos='ecosystem-container-dev-local;ecosystem-helm-dev-local;ecosystem-rpm-dev-local;ecosystem-deb-dev-local;ecosystem-meta-dev-local'
