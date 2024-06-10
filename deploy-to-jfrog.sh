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
if [ -d "${BASE_DIR}/${RELEASE_NAME}/${RELEASE_NUMBER}" ]; then
    echo "Error: Release ${RELEASE_NUMBER} already exists for ${RELEASE_NAME}. Cannot create a new release with the same version."
    exit 1
fi

mkdir "${BASE_DIR}/${RELEASE_NAME}/${RELEASE_NUMBER}"
cp -r ${BASE_DIR}/${RELEASE_NAME}/current/* ${BASE_DIR}/${RELEASE_NAME}/${RELEASE_NUMBER}


# Define artifact names
DOCKER_IMAGE_NAME="aerospike/aerospike-proximus:${ARTIFACT_VERSION}"
DOCKER_TAR_NAME="aerospike-vector-search-${ARTIFACT_VERSION}.tar"
HELM_CHART_NAME="aerospike-vector-search-${HELM_CHART_VERSION}.tgz"
RPM_PACKAGE_NAME="aerospike-proximus-${ARTIFACT_VERSION}-1.noarch.rpm"
DEB_PACKAGE_NAME="aerospike-proximus-${ARTIFACT_VERSION}.all.deb"
SBOM_FILE_NAME="${RELEASE_NAME}-${ARTIFACT_VERSION}-sbom.json"
SNYK_REPORT_NAME="snyk-report-${RELEASE_NAME}-${ARTIFACT_VERSION}.sarif"
SPEC_FILE_NAME="spec-${RELEASE_NAME}.json"
RELEASE_BUNDLE_SPEC_NAME="release-bundle-${RELEASE_NAME}.json"
DISTRIBUTION_RULES_NAME="distribution-rules-${RELEASE_NAME}.json"
SNYK_FILE_NAME="$(basename ${SNYK_FILE})"

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
SNYK_FILE_DEST="${BASE_DIR}/${RELEASE_NAME}/${RELEASE_NUMBER}/metadata/snyk-config"
SNYK_FILE_DOCKER_DIR="${BASE_DIR}/${RELEASE_NAME}/${RELEASE_NUMBER}/docker/.snyk"
RELEASE_BUNDLE_NAME="${RELEASE_NAME}-${ARTIFACT_VERSION}"

# Ensure required tools are installed
for cmd in docker jf syft jq snyk; do
if ! command -v $cmd &> /dev/null; then
    echo "Error: $cmd is not installed." >&2
    exit 1
fi
done

# Pull Docker image and save to tar file
docker pull ${DOCKER_IMAGE_NAME}
docker save -o ${DOCKER_TAR} ${DOCKER_IMAGE_NAME}


# Copy the Snyk file to the metadata directory and Docker tar directory
if [ -n "$SNYK_FILE" ]; then
    cp ${SNYK_FILE} ${SNYK_FILE_DEST}
    cp ${SNYK_FILE} ${SNYK_FILE_DOCKER_DIR}
fi

# Run Snyk test and generate SARIF report
# snyk container test docker-archive:${DOCKER_TAR} --sarif-file-output=${SNYK_REPORT} --file=${SNYK_FILE_DOCKER_DIR}

# Generate SBOM using Syft
syft ${DOCKER_TAR} -o json > ${SBOM_FILE}
touch ${DOCKER_TAR} ${HELM_CHART} ${RPM_PACKAGE} ${DEB_PACKAGE} ${SBOM_FILE} ${SNYK_REPORT} ${SNYK_FILE_DEST} ${SPEC_FILE} ${RELEASE_BUNDLE_SPEC} ${DISTRIBUTION_RULES}
# Create spec file dynamically after all files are created
# and add any needed properties and coordinates (both in props)

cat <<EOF > ${SPEC_FILE}
{
    "files": [
        {
            "pattern": "${DOCKER_TAR}",
            "target": "ecosystem-container-dev-local/${RELEASE_NAME}/${ARTIFACT_VERSION}/",
            "props": "docker.repo=${DOCKER_IMAGE_NAME}"
        },
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
            "target": "ecosystem-meta-dev-local/${RELEASE_NAME}/${ARTIFACT_VERSION}/"
        },
        {
            "pattern": "${SNYK_REPORT}",
            "target": "ecosystem-meta-dev-local/${RELEASE_NAME}/${ARTIFACT_VERSION}/"
        },
        {
            "pattern": "${SNYK_FILE_DEST}",
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
jf rt upload --spec=${SPEC_FILE} --project=ecosystem

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
--spec=${RELEASE_BUNDLE_SPEC} --signing-key=${SIGNING_KEY} --project=ecosystem

