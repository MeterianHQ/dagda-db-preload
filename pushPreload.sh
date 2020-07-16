#!/bin/bash

set -e
set -u
set -o pipefail

METERIAN_DB_PRELOAD_FULL_IMAGE=${METERIAN_DB_PRELOAD_FULL_IMAGE:-"meterian/cs-dagda-db:latest"}

# Login to Meterian DockerHub
echo "~~~ Signing in to Meterian DockerHub"
if [[ -n "${DOCKER_USER_NAME:-}" && -n "${DOCKER_PASSWORD:-}" ]]; then
    docker login --username=${DOCKER_USER_NAME:-} --password=${DOCKER_PASSWORD:-}
else
    echo "Error: Credentials not specified in DOCKER_USER_NAME and DOCKER_PASSWORD environment variables"
    exit 1
fi
echo

# Push newly built images to update them
echo "~~~ Now uploading '${METERIAN_DB_PRELOAD_FULL_IMAGE}' to DockerHub"
docker push "${METERIAN_DB_PRELOAD_FULL_IMAGE}"