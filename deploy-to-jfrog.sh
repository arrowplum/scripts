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
SITE_NAME="your-site-name"
SIGNING_KEY="~/.gnupg/private-keys-v1.d/E1C8F4013F91B73E9DD455762BF009A57D65148D.key"

# Usage function
usage() {
  echo "Usage: $0 [-r release_number] [-a artifact_version] [-c helm_chart_version] [-b base_directory] [--release-number release_number] [--artifact-version artifact_version] [--helm-chart-version helm_chart_version] [--base-directory base_directory] [--site-name site_name] [--signing-key signing_key] [-h|--help]"
  exit 1
}

# Parse command-line options using getopt
OPTIONS=$(getopt -o r:a:c:b:s:k:h --long release-number:,artifact-version:,helm-chart-version:,base-directory:,site-name:,signing-key:,help -- "$@")
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
    -s|--site-name)
      SITE_NAME="$2"; shift 2;;
    -k|--signing-key)
      SIGNING_KEY="$2"; shift 2;;
    -h|--help)
      usage; shift;;
    --)
      shift; break;;
    *)
      usage;;
  esac
done

# Define artifact names
DOCKER_IMAGE_NAME="aerospike/aerospike-proximus:${ARTIFACT_VERSION}"
DOCKER_TAR_NAME="aerospike-vector-search-${ARTIFACT_VERSION}.tar"
HELM_CHART_NAME="aerospike-vector-search-${HELM_CHART_VERSION}.tgz"
RPM_PACKAGE_NAME="aerospike-proximus-${ARTIFACT_VERSION}-1.noarch.rpm"
DEB_PACKAGE_NAME="aerospike-proximus-${ARTIFACT_VERSION}.all.deb"
SBOM_FILE_NAME="${RELEASE_NAME}-${ARTIFACT_VERSION}-sbom.json"
SNYK_REPORT_NAME="snyk-report-${RELEASE_NAME}-${ARTIFACT_VERSION}.sarif"
SPEC_FILE_NAME="spec-${RELEASE_NAME}-${RELEASE_NUMBER}.json"
RELEASE_BUNDLE_SPEC_NAME="release-bundle-${RELEASE_NAME}-${RELEASE_NUMBER}.json"
DISTRIBUTION_RULES_NAME="distribution-rules-${RELEASE_NAME}-${RELEASE_NUMBER}.json"

# Compute paths based on release name, release number, and artifact names
DOCKER_TAR="${BASE_DIR}/${RELEASE_NAME}/${RELEASE_NUMBER}/docker/${DOCKER_TAR_NAME}"
HELM_CHART="${BASE_DIR}/${RELEASE_NAME}/${RELEASE_NUMBER}/helm/${HELM_CHART_NAME}"
RPM_PACKAGE="${BASE_DIR}/${RELEASE_NAME}/${RELEASE_NUMBER}/rpm/${RPM_PACKAGE_NAME}"
DEB_PACKAGE="${BASE_DIR}/${RELEASE_NAME}/${RELEASE_NUMBER}/deb/${DEB_PACKAGE_NAME}"
SBOM_FILE="${BASE_DIR}/${RELEASE_NAME}/${RELEASE_NUMBER}/metadata/${SBOM_FILE_NAME}"
SNYK_REPORT="${BASE_DIR}/${RELEASE_NAME}/${RELEASE_NUMBER}/metadata/${SNYK_REPORT_NAME}"
SPEC_FILE="${BASE_DIR}/${RELEASE_NAME}/${RELEASE_NUMBER}/metadata/${SPEC_FILE_NAME}"
RELEASE_BUNDLE_SPEC="${BASE_DIR}/${RELEASE_NAME}/${RELEASE_NUMBER}/metadata/${RELEASE_BUNDLE_SPEC_NAME}"
DISTRIBUTION_RULES="${BASE_DIR}/${RELEASE_NAME}/${RELEASE_NUMBER}/metadata/${DISTRIBUTION_RULES_NAME}"
RELEASE_BUNDLE_NAME="${RELEASE_NAME}-${ARTIFACT_VERSION}"

# Ensure required tools are installed
for cmd in docker jf syft jq; do
  if ! command -v $cmd &> /dev/null; then
    echo "Error: $cmd is not installed." >&2
    exit 1
  fi
done

# Pull Docker image and save to tar file
docker pull ${DOCKER_IMAGE_NAME}
docker save -o ${DOCKER_TAR} ${DOCKER_IMAGE_NAME}

# Function to get site ID with error handling
get_site_id() {
  local site_name="$1"
  local response
  local http_status
  local site_id

  # Make the curl call and capture the HTTP status code
  response=$(jf rt curl -X GET /distribution/api/v1/sites -o - -w "%{http_code}")
  http_status=$(echo "${response: -3}")
  response=$(echo "${response%???}")

  # Check if the HTTP status code is 200 (OK)
  if [ "$http_status" -eq 200 ]; then
    site_id=$(echo "$response" | jq -r --arg name "$site_name" '.[] | select(.name == $name) | .id')
    if [ -z "$site_id" ]; then
      echo "Site ID for '$site_name' not found in response."
    else
      echo "$site_id"
    fi
  else
    echo "Error: Received HTTP status $http_status. Response: $response"
  fi
}

# Retrieve the site ID for the given site name
SITE_ID=$(get_site_id "$SITE_NAME")

# Check if SITE_ID is empty
if [ -z "$SITE_ID" ]; then
  echo "No sites configured or site ID for '$SITE_NAME' not found. Skipping distribution."
  DISTRIBUTE=false
else
  echo "Site ID for '$SITE_NAME' is $SITE_ID"
  DISTRIBUTE=true
fi

# # Run Snyk test and generate SARIF report
snyk container test docker-archive:${DOCKER_TAR} --file=${DOCKER_TAR} --sarif-file-output=${SNYK_REPORT} ----sarif

# Generate SBOM using Syft
syft ${DOCKER_TAR} -o json > ${SBOM_FILE}

# Create spec file dynamically after all files are created
cat <<EOF > ${SPEC_FILE}
{
  "files": [
    {
      "pattern": "${DOCKER_TAR}",
      "target": "ecosystem-container-dev-local/${RELEASE_NAME}/${ARTIFACT_VERSION}/"
    },
    {
      "pattern": "${HELM_CHART}",
      "target": "ecosystem-helm-dev-local/${RELEASE_NAME}/${HELM_CHART_VERSION}/"
    },
    {
      "pattern": "${RPM_PACKAGE}",
      "target": "ecosystem-rpm-dev-local/${RELEASE_NAME}/${ARTIFACT_VERSION}/"
    },
    {
      "pattern": "${DEB_PACKAGE}",
      "target": "ecosystem-deb-dev-local/${RELEASE_NAME}/${ARTIFACT_VERSION}/"
    },
    {
      "pattern": "${SBOM_FILE}",
      "target": "ecosystem-pkg-dev-local/${RELEASE_NAME}/${ARTIFACT_VERSION}/"
    },
    {
      "pattern": "${SNYK_REPORT}",
      "target": "ecosystem-pkg-dev-local/${RELEASE_NAME}/${ARTIFACT_VERSION}/"
    },
    {
      "pattern": "${SPEC_FILE}",
      "target": "ecosystem-pkg-dev-local/${RELEASE_NAME}/${ARTIFACT_VERSION}/"
    },
    {
      "pattern": "${RELEASE_BUNDLE_SPEC}",
      "target": "ecosystem-pkg-dev-local/${RELEASE_NAME}/${ARTIFACT_VERSION}/"
    },
    {
      "pattern": "${DISTRIBUTION_RULES}",
      "target": "ecosystem-pkg-dev-local/${RELEASE_NAME}/${ARTIFACT_VERSION}/"
    }
  ]
}
EOF

# Upload all artifacts using JF CLI
jf rt upload --spec=${SPEC_FILE}

# Create release bundle specification dynamically with supported fields
cat <<EOF > ${RELEASE_BUNDLE_SPEC}
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
      "pattern": "ecosystem-container-dev-local/${RELEASE_NAME}/${ARTIFACT_VERSION}/*"
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
      "pattern": "ecosystem-pkg-dev-local/${RELEASE_NAME}/${ARTIFACT_VERSION}/*"
    }
  ]
}
EOF

# Create the release bundle
jf release-bundle-create ${RELEASE_BUNDLE_NAME} ${RELEASE_NUMBER} \
  --spec=${RELEASE_BUNDLE_SPEC} --signing-key=${SIGNING_KEY}

# If sites are configured, create distribution rules and promote the release bundle to stage
if [ "$DISTRIBUTE" = true ]; then
  # Create distribution rules dynamically
  cat <<EOF > ${DISTRIBUTION_RULES}
{
  "version": "${RELEASE_NUMBER}",
  "rules": [
    {
      "name": "Promote to Stage",
      "repositories": [
        "ecosystem-container-stage-local",
        "ecosystem-helm-stage-local",
        "ecosystem-rpm-stage-local",
        "ecosystem-deb-stage-local",
        "ecosystem-pkg-dev-local"
      ],
      "site": "${SITE_NAME}"
    }
  ]
}
EOF

  # Promote the release bundle to stage
  jf  release-bundle-promote ${RELEASE_BUNDLE_NAME} ${RELEASE_NUMBER} --site=${SITE_NAME} --dist-rules=${DISTRIBUTION_RULES}
else
  echo "Skipping distribution as no sites are configured."
fi
