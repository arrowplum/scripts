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

# Usage function
usage() {
  echo "Usage: $0 [-r release_number] [-a artifact_version] [-c helm_chart_version] [-b base_directory] [--release-number release_number] [--artifact-version artifact_version] [--helm-chart-version helm_chart_version] [--base-directory base_directory] [--site-name site_name] [-h|--help]"
  exit 1
}

# Parse command-line options using getopt
OPTIONS=$(getopt -o r:a:c:b:s:h --long release-number:,artifact-version:,helm-chart-version:,base-directory:,site-name:,help -- "$@")
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
DEB_PACKAGE_NAME="aerospike-proximus-${ARTIFACT_VERSION}.deb"
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

# Pull Docker image from Docker Hub
docker pull ${DOCKER_IMAGE_NAME}

# Save Docker image to tar file
docker save -o ${DOCKER_TAR} ${DOCKER_IMAGE_NAME}

# FIXME we are having permissions issues with snyk
# # Run Snyk test and generate SARIF report
# snyk container test ${DOCKER_TAR} --file=${SNYK_REPORT} --sarif

# Generate SBOM using Syft
syft ${DOCKER_TAR} -o json > ${SBOM_FILE}

# Upload all artifacts using JF CLI
jf rt upload --spec=${SPEC_FILE}

# Create the release bundle
jf release-bundle-create ${RELEASE_BUNDLE_NAME}/${RELEASE_NUMBER} \
  --release-notes-syntax markdown \
  --release-notes "Release notes for ${RELEASE_BUNDLE_NAME} version ${ARTIFACT_VERSION}" \
  --repository ecosystem-container-dev-local \
  --repository ecosystem-helm-dev-local \
  --repository ecosystem-rpm-dev-local \
  --repository ecosystem-deb-dev-local \
  --repository ecosystem-pkg-dev-local \
  --sign-immediately=false

# If sites are configured, create distribution rules and promote the release bundle to stage
if [ "$DISTRIBUTE" = true ]; then
  # Promote the release bundle to stage
  jf release-bundle-promote ${RELEASE_BUNDLE_NAME}/${RELEASE_NUMBER} --site=${SITE_NAME} --target-repos ecosystem-container-stage-local,ecosystem-helm-stage-local,ecosystem-rpm-stage-local,ecosystem-deb-stage-local,ecosystem-pkg-dev-local
else
  echo "Skipping distribution as no sites are configured."
fi