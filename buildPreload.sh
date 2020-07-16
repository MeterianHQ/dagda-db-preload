#!/bin/bash 

set -e
set -u
set -o pipefail

DAGDA_REPO="3grander/dagda"
DAGDA_VERSION="0.8.0"
DAGDA_FULL_IMAGE="${DAGDA_REPO}:${DAGDA_VERSION}"
DAGDA_CONTAINER_NAME="dagda"

DB_FULL_IMAGE="mongo:latest"
DB_CONTAINER_NAME="vulndb"

DAGDA_NET_NAME="dagda_net"

METERIAN_DB_PRELOAD_FULL_IMAGE=${METERIAN_DB_PRELOAD_FULL_IMAGE:-"meterian/cs-dagda-db:latest"}

dagdaTeardown() {
    echo "Removing dagda docker containers and network..."
    docker rm -f ${DAGDA_CONTAINER_NAME} ${DB_CONTAINER_NAME} || true
    # dagda internally starts a container running falco which stays up despite dagda's container being stopped and removed
    docker rm -f $(docker ps --filter "ancestor=falcosecurity/falco:0.18.0" -q) || true
    # removing dagda docker network
    docker network rm ${DAGDA_NET_NAME} || true
}

onExit() {
    dagdaTeardown > /dev/null 2>&1
}
trap onExit EXIT

checkIfDagdaApiReachable() {
    curlResponse="$(curl -sS -I "localhost:5000/v1/docker/images" 2> /dev/null)"
    reg='200'
    if [[ ! "${curlResponse}" =~ $reg ]]; then
        echo "Error: Dagda API is not reachable, respose was:"
	echo "${curlResponse}" 
        return 1
    fi

    return 0
}

dagdaApi() {
    method=${1:-"GET"}
    curlResponse="$(curl -sS -X ${method} "localhost:5000/v1/${2}" 2> /dev/null)"
    echo "${curlResponse}"
}

#set -x
# Create db folder if not already present
mkdir -p db

# Pulling required images
echo "~~~ Pulling required images for dagda"
docker pull ${DAGDA_FULL_IMAGE}
docker pull ${DB_FULL_IMAGE}

# Creating dagda network 
echo "~~~ Creating dagda network '${DAGDA_NET_NAME}'"
docker network create ${DAGDA_NET_NAME}

# Startup dagda and begin updating db
echo "~~~ Starting up dagda vulnerability db"
docker run -d \
           -p 27017:27017 \
           --user $(id -u):$(id -g) \
           -v $(pwd)/db:/data/db \
           --name ${DB_CONTAINER_NAME}  \
	       --network ${DAGDA_NET_NAME} \
           ${DB_FULL_IMAGE}
sleep 3
echo "Done."
echo "~~~ Starting up dagda server" 
docker run -d \
           -p 5000:5000 \
           -v /var/run/docker.sock:/var/run/docker.sock:ro \
           -v /tmp:/tmp \
           --name ${DAGDA_CONTAINER_NAME} \
           --network ${DAGDA_NET_NAME} \
           ${DAGDA_FULL_IMAGE} \
           "start -s 0.0.0.0 -p 5000 -m ${DB_CONTAINER_NAME} -mp 27017"
sleep 10
echo "Done."
echo

# Initialise db update
checkIfDagdaApiReachable
echo "Updating db..."
dagdaApi "POST" "vuln/init"

# periodic check to see if the db is done updating
echo "Checking status..."
retryCount=0
initStatusResponse="$(dagdaApi "GET" "vuln/init-status")"
while [[ -z "$(echo "${initStatusResponse}" | grep "Updated")" ]]; do
    echo -ne "Retry count: ${retryCount}\r"
    if [[ ${retryCount} -eq  720 ]];then
        echo "Database update process out of time, aborting now"
        exit 1
    fi

    if [[ -n "$(echo "${initStatusResponse}" | grep "TerminatedWorkerError")" ]]; then
        echo "Unexpected exception of type TerminatedWorkerError occurred"
        echo "Restarting db update..."
        dagdaApi "POST" "vuln/init"
    fi

    if [[ -n "$(echo "${initStatusResponse}" | grep -E "Internal Server Error")" ]]; then
        echo "Db update returned: Internal Server Error"
        echo "Check that dagda and related containers are appropriately set up"
        exit 1
    fi

    sleep 10
    retryCount=$((retryCount + 1))
    initStatusResponse="$(dagdaApi "GET" "vuln/init-status")"
done
echo "Database updated!"
echo

echo "~~~ Making a copy of the updated db files from container '${DB_CONTAINER_NAME}'..."
docker cp ${DB_CONTAINER_NAME}:/data/db ./db_new
echo "Done."
echo

echo "Tearing down dagda..."
dagdaTeardown
echo "Done."
echo

echo "Updating local db files with newly copied data..."
rm -rf "db"
mv "db_new" "db"
echo "Done."
echo

# Building docker image with updated db
echo "~~~ Building '${METERIAN_DB_PRELOAD_FULL_IMAGE}'"
docker build -t "${METERIAN_DB_PRELOAD_FULL_IMAGE}" .