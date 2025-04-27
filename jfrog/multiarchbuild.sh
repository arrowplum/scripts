#!/bin/bash

# Check if at least two arguments are passed
if [ "$#" -lt 2 ]; then
    echo "Usage: $0 <image_name> <long_version> [build_number]"
    exit 1
fi

IMAGE_NAME="$1"
LONG_VERSION="$2"
BUILD_NUMBER="${3:-$LONG_VERSION}"  # Default build number to long version if not provided

# Extract the short version from the long version
SHORT_VERSION=$(echo "$LONG_VERSION" | cut -d '.' -f 1-2)

# Function to push images for each architecture
push_image() {
    local arch=$1

    # Push each existing architecture-specific image to Artifactory
    jf docker push "${IMAGE_NAME}:${LONG_VERSION}-${arch}" --build-name=aerospike-server-enterprise --build-number="${BUILD_NUMBER}"
    jf docker push "${IMAGE_NAME}:${SHORT_VERSION}-${arch}" --build-name=aerospike-server-enterprise --build-number="${BUILD_NUMBER}"
}

# Push images for both amd64 and arm64
push_image "amd64"
push_image "arm64"

# Create and Annotate the Manifest List
echo "Creating and annotating the manifest list..."
docker manifest create "${IMAGE_NAME}:multiarch" \
  --amend "${IMAGE_NAME}:${LONG_VERSION}-amd64" \
  --amend "${IMAGE_NAME}:${LONG_VERSION}-arm64"

docker manifest annotate "${IMAGE_NAME}:multiarch" \
  "${IMAGE_NAME}:${LONG_VERSION}-amd64" --os linux --arch amd64

docker manifest annotate "${IMAGE_NAME}:multiarch" \
  "${IMAGE_NAME}:${LONG_VERSION}-arm64" --os linux --arch arm64

# Push the Multi-Platform Manifest List to Artifactory
echo "Pushing the multi-platform manifest list to Artifactory..."
docker manifest push "${IMAGE_NAME}:multiarch"

echo "Images have been pushed and the multi-platform manifest list has been created and pushed successfully."


docker tag  aerospike/aerospike-server-enterprise:7.1 artifact.aerospike.io/core-containers-dev-local/joe-aerospike-server-enterprise:7.1.0.5-amd64
docker tag  aerospike/aerospike-server-enterprise:7.1 artifact.aerospike.io/core-containers-dev-local/joe-aerospike-server-enterprise:7.1.0.5-arm64
jf docker push artifact.aerospike.io/core-containers-dev-local/joe-aerospike-server-enterprise:7.1.0.5-amd64 --build-name=joe-aerospike-server-enterprise --build-number=7.1
jf docker push artifact.aerospike.io/core-containers-dev-local/joe-aerospike-server-enterprise:7.1.0.5-arm64 --build-name=joe-aerospike-server-enterprise --build-number=7.1
docker manifest create artifact.aerospike.io/core-containers-dev-local/joe-aerospike-server-enterprise:7.1.0.5 --amend artifact.aerospike.io/core-containers-dev-local/joe-aerospike-server-enterprise:7.1.0.5-amd64  --amend artifact.aerospike.io/core-containers-dev-local/joe-aerospike-server-enterprise:7.1.0.5-arm64
docker manifest annotate artifact.aerospike.io/core-containers-dev-local/joe-aerospike-server-enterprise:7.1.0.5 artifact.aerospike.io/core-containers-dev-local/joe-aerospike-server-enterprise:7.1.0.5-amd64 --os linux --arch amd64
docker manifest annotate artifact.aerospike.io/core-containers-dev-local/joe-aerospike-server-enterprise:7.1.0.5 artifact.aerospike.io/core-containers-dev-local/joe-aerospike-server-enterprise:7.1.0.5-arm64 --os linux --arch arm64
jf docker manifest push artifact.aerospike.io/core-containers-dev-local/joe-aerospike-server-enterprise:7.1.0.5
jf rt build-publish joe-aerospike-server-enterprise 7.1
jf rt build-promote joe-aerospike-server-enterprise 7.1 core-containers-dev-local --status="DEV" --comment="Promoted to DEV environment"