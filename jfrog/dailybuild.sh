#! /bin/bash

set -eo pipefail
if [ -n "$DEBUG" ]; then set -x; fi
trap 'echo "Error: $? at line $LINENO" >&2' ERR

jf docker buildx imagetools create --tag artifact.aerospike.io/ecosystem-container-dev-local/aerospike-vector-search:0.10.1-SNAPSHOT --build-name aerospike-vector-search --build-number 0.10.1-SNAPSHOT --project=ecosystem aerospike/aerospike-vector-search-private:0.10.1-SNAPSHOT --progress plain

# docker pull aerospike/aerospike-vector-search-private:0.10.1-SNAPSHOT  --platform linux/arm64
# docker pull aerospike/aerospike-vector-search-private:0.10.1-SNAPSHOT  --platform linux/amd64

# # jf build-add aerospike-vector-search 0.10.1-SNAPSHOT --project=ecosystem
# jf docker tag  aerospike/aerospike-vector-search-private:0.10.1-SNAPSHOT artifact.aerospike.io/ecosystem-container-dev-local/aerospike-vector-search:0.10.1-SNAPSHOT-arm64
# jf docker tag  aerospike/aerospike-vector-search-private:0.10.1-SNAPSHOT artifact.aerospike.io/ecosystem-container-dev-local/aerospike-vector-search:0.10.1-SNAPSHOT-amd64

# jf docker push artifact.aerospike.io/ecosystem-container-dev-local/aerospike-vector-search:0.10.1-SNAPSHOT-amd64 --build-name aerospike-vector-search --build-number 0.10.1-SNAPSHOT --project=ecosystem

# jf docker push artifact.aerospike.io/ecosystem-container-dev-local/aerospike-vector-search:0.10.1-SNAPSHOT-arm64 --build-name aerospike-vector-search --build-number 0.10.1-SNAPSHOT --project=ecosystem

# jf docker manifest create artifact.aerospike.io/ecosystem-container-dev-local/aerospike-vector-search:0.10.1-SNAPSHOT --amend artifact.aerospike.io/ecosystem-container-dev-local/aerospike-vector-search:0.10.1-SNAPSHOT-amd64 --amend artifact.aerospike.io/ecosystem-container-dev-local/aerospike-vector-search:0.10.1-SNAPSHOT-arm64 

# jf docker manifest annotate  artifact.aerospike.io/ecosystem-container-dev-local/aerospike-vector-search:0.10.1-SNAPSHOT artifact.aerospike.io/ecosystem-container-dev-local/aerospike-vector-search:0.10.1-SNAPSHOT-amd64 --os linux --arch amd64

# jf docker manifest annotate  artifact.aerospike.io/ecosystem-container-dev-local/aerospike-vector-search:0.10.1-SNAPSHOT artifact.aerospike.io/ecosystem-container-dev-local/aerospike-vector-search:0.10.1-SNAPSHOT-arm64 --os linux --arch arm64


# # jf docker push artifact.aerospike.io/ecosystem-container-dev-local/aerospike-vector-search:0.10.1-SNAPSHOT-amd64 --build-name aerospike-vector-search --build-number 0.10.1-SNAPSHOT

# # jf docker push artifact.aerospike.io/ecosystem-container-dev-local/aerospike-vector-search:0.10.1-SNAPSHOT-arm64 --build-name aerospike-vector-search --build-number 0.10.1-SNAPSHOT

# jf docker manifest push  artifact.aerospike.io/ecosystem-container-dev-local/aerospike-vector-search:0.10.1-SNAPSHOT

# jf rt build-publish  aerospike-vector-search 0.10.1-SNAPSHOT --project=ecosystem
# jf rt build-promote  aerospike-vector-search 0.10.1-SNAPSHOT ecosystem-container-dev-local --status="DEV" --comment="Promoted to daily snapshot to DEV environment" --project=ecosystem
