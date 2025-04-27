#! /bin/bash

if [ -n "$DEBUG" ]; then set -x; fi

docker pull aerospike/aerospike-server-enterprise-rc:8.0.0.0-alpha4  --platform linux/arm64
docker pull aerospike/aerospike-server-enterprise-rc:8.0.0.0-alpha4  --platform linux/amd64

jf build-add aerospike-server-enterprise 8.0.0.0-alpha4 --project=ecosystem
jf docker tag  aerospike/aerospike-server-enterprise-rc:8.0.0.0-alpha4 artifact.aerospike.io/ecosystem-container-dev-local/aerospike-server-enterprise:8.0.0.0-alpha4-arm64
jf docker tag  aerospike/aerospike-server-enterprise-rc:8.0.0.0-alpha4 artifact.aerospike.io/ecosystem-container-dev-local/aerospike-server-enterprise:8.0.0.0-alpha4-amd64

jf docker push artifact.aerospike.io/ecosystem-container-dev-local/aerospike-server-enterprise:8.0.0.0-alpha4-amd64 --build-name aerospike-server-enterprise --build-number 8.0.0.0-alpha4 --project=ecosystem

jf docker push artifact.aerospike.io/ecosystem-container-dev-local/aerospike-server-enterprise:8.0.0.0-alpha4-arm64 --build-name aerospike-server-enterprise --build-number 8.0.0.0-alpha4 --project=ecosystem

jf docker manifest create artifact.aerospike.io/ecosystem-container-dev-local/aerospike-server-enterprise:8.0.0.0-alpha4 --amend artifact.aerospike.io/ecosystem-container-dev-local/aerospike-server-enterprise:8.0.0.0-alpha4-amd64 --amend artifact.aerospike.io/ecosystem-container-dev-local/aerospike-server-enterprise:8.0.0.0-alpha4-arm64 --build-name aerospike-server-enterprise --build-number 8.0.0.0-alpha4 --project=ecosystem 

jf docker manifest annotate  artifact.aerospike.io/ecosystem-container-dev-local/aerospike-server-enterprise:8.0.0.0-alpha4 artifact.aerospike.io/ecosystem-container-dev-local/aerospike-server-enterprise:8.0.0.0-alpha4-amd64 --os linux --arch amd64 --build-name aerospike-server-enterprise --build-number 8.0.0.0-alpha4 --project=ecosystem

jf docker manifest annotate  artifact.aerospike.io/ecosystem-container-dev-local/aerospike-server-enterprise:8.0.0.0-alpha4 artifact.aerospike.io/ecosystem-container-dev-local/aerospike-server-enterprise:8.0.0.0-alpha4-arm64 --os linux --arch arm64 --build-name aerospike-server-enterprise --build-number 8.0.0.0-alpha4 --project=ecosystem


# jf docker push artifact.aerospike.io/ecosystem-container-dev-local/aerospike-server-enterprise:8.0.0.0-alpha4-amd64 --build-name aerospike-server-enterprise --build-number 8.0.0.0-alpha4

# jf docker push artifact.aerospike.io/ecosystem-container-dev-local/aerospike-server-enterprise:8.0.0.0-alpha4-arm64 --build-name aerospike-server-enterprise --build-number 8.0.0.0-alpha4

jf docker manifest push  artifact.aerospike.io/ecosystem-container-dev-local/aerospike-server-enterprise:8.0.0.0-alpha4 --build-name aerospike-server-enterprise --build-number 8.0.0.0-alpha4 --project=ecosystem

jf rt build-publish  aerospike-server-enterprise 8.0.0.0-alpha4 --project=ecosystem 
jf rt build-promote  aerospike-server-enterprise 8.0.0.0-alpha4 ecosystem-container-dev-local --status="DEV" --comment="Promoted to daily snapshot to DEV environment" --project=ecosystem 
