#!/bin/bash

set -eo pipefail
if [ -n "$DEBUG" ]; then set -x; fi
trap 'echo "Error: $? at line $LINENO" >&2' ERR

# Default values
IMAGE_NAME="aerospike/aerospike-vector-search-private"
VERSION="0.10.1-SNAPSHOT"
JFROG_PROJECT="ecosystem"
JFROG_REPO="artifact.aerospike.io/ecosystem-container-dev-local"
BUILD_NAME="aerospike-vector-search"

# Function to show usage
usage() {
  echo "Usage: $0 [-i image_name] [-v version] [-p project] [-r repo] [-b build_name]"
  exit 1
}

# Parse named arguments
while getopts ":i:v:p:r:b:" opt; do
  case ${opt} in
    i )
      IMAGE_NAME=$OPTARG
      ;;
    v )
      VERSION=$OPTARG
      ;;
    p )
      JFROG_PROJECT=$OPTARG
      ;;
    r )
      JFROG_REPO=$OPTARG
      ;;
    b )
      BUILD_NAME=$OPTARG
      ;;
    \? )
      echo "Invalid option: $OPTARG" 1>&2
      usage
      ;;
    : )
      echo "Invalid option: $OPTARG requires an argument" 1>&2
      usage
      ;;
  esac
done

# Pull images
docker pull ${IMAGE_NAME}:${VERSION} --platform linux/arm64
docker pull ${IMAGE_NAME}:${VERSION} --platform linux/amd64

# # Add build
# jf build-add ${BUILD_NAME} ${VERSION} --project=${JFROG_PROJECT}

# Tag images
jf docker tag ${IMAGE_NAME}:${VERSION} ${JFROG_REPO}/${BUILD_NAME}:${VERSION}-arm64
jf docker tag ${IMAGE_NAME}:${VERSION} ${JFROG_REPO}/${BUILD_NAME}:${VERSION}-amd64

# Push images
jf docker push ${JFROG_REPO}/${BUILD_NAME}:${VERSION}-amd64 --build-name ${BUILD_NAME} --build-number ${VERSION} --project=${JFROG_PROJECT}
jf docker push ${JFROG_REPO}/${BUILD_NAME}:${VERSION}-arm64 --build-name ${BUILD_NAME} --build-number ${VERSION} --project=${JFROG_PROJECT}

# Create and annotate manifest
jf docker manifest create ${JFROG_REPO}/${BUILD_NAME}:${VERSION} \
    --amend ${JFROG_REPO}/${BUILD_NAME}:${VERSION}-amd64 \
    --amend ${JFROG_REPO}/${BUILD_NAME}:${VERSION}-arm64

jf docker manifest annotate ${JFROG_REPO}/${BUILD_NAME}:${VERSION} \
    ${JFROG_REPO}/${BUILD_NAME}:${VERSION}-amd64 --os linux --arch amd64

jf docker manifest annotate ${JFROG_REPO}/${BUILD_NAME}:${VERSION} \
    ${JFROG_REPO}/${BUILD_NAME}:${VERSION}-arm64 --os linux --arch arm64

# Push manifest
jf docker manifest push ${JFROG_REPO}/${BUILD_NAME}:${VERSION}

# Publish and promote build
jf rt build-publish "${BUILD_NAME}" ${VERSION} --project=${JFROG_PROJECT}
jf rt build-promote ${BUILD_NAME} ${VERSION} ${JFROG_REPO} --status="DEV" --comment="Promoted to daily snapshot to DEV environment" --project=${JFROG_PROJECT}



