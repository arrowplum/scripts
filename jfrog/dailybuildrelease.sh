#!/bin/bash
docker pull aerospike/aerospike-vector-search:0.10.0  --platform linux/arm64
docker pull aerospike/aerospike-vector-search:0.10.0  --platform linux/amd64

jf build-add aerospike-vector-search-container 0.10.0 --project=ecosystem
jf docker tag  aerospike/aerospike-vector-search:0.10.0 artifact.aerospike.io/ecosystem-container-dev-local/aerospike-vector-search:0.10.0-arm64
jf docker tag  aerospike/aerospike-vector-search:0.10.0 artifact.aerospike.io/ecosystem-container-dev-local/aerospike-vector-search:0.10.0-amd64

jf docker push artifact.aerospike.io/ecosystem-container-dev-local/aerospike-vector-search:0.10.0-amd64 --build-name aerospike-vector-search-container --build-number 0.10.0 --project=ecosystem

jf docker push artifact.aerospike.io/ecosystem-container-dev-local/aerospike-vector-search:0.10.0-arm64 --build-name aerospike-vector-search-container --build-number 0.10.0 --project=ecosystem

jf docker manifest create artifact.aerospike.io/ecosystem-container-dev-local/aerospike-vector-search:0.10.0 --amend artifact.aerospike.io/ecosystem-container-dev-local/aerospike-vector-search:0.10.0-amd64 --amend artifact.aerospike.io/ecosystem-container-dev-local/aerospike-vector-search:0.10.0-arm64 

jf docker manifest annotate  artifact.aerospike.io/ecosystem-container-dev-local/aerospike-vector-search:0.10.0 artifact.aerospike.io/ecosystem-container-dev-local/aerospike-vector-search:0.10.0-amd64 --os linux --arch amd64

jf docker manifest annotate  artifact.aerospike.io/ecosystem-container-dev-local/aerospike-vector-search:0.10.0 artifact.aerospike.io/ecosystem-container-dev-local/aerospike-vector-search:0.10.0-arm64 --os linux --arch arm64


# jf docker push artifact.aerospike.io/ecosystem-container-dev-local/aerospike-vector-search:0.10.0-amd64 --build-name aerospike-vector-search --build-number 0.10.0

# jf docker push artifact.aerospike.io/ecosystem-container-dev-local/aerospike-vector-search:0.10.0-arm64 --build-name aerospike-vector-search --build-number 0.10.0

jf docker manifest push  artifact.aerospike.io/ecosystem-container-dev-local/aerospike-vector-search:0.10.0

jf rt build-publish  aerospike-vector-search-container 0.10.0 --project=ecosystem
jf rt build-promote  aerospike-vector-search-container 0.10.0 ecosystem-container-dev-local --status="DEV" --comment="Promoted to daily snapshot to DEV environment" --project=ecosystem
jf rt build-promote  aerospike-vector-search-container 0.10.0 ecosystem-container-dev-local --status="DEV" --comment="Promoted to daily snapshot to DEV environment" --project=ecosystem
