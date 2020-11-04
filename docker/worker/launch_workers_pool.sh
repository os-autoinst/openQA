#!/bin/bash
set -e

size=1

usage() {
    cat << EOF
Usage: $0
To launch a pool of workers with the desired number of workers in individual
containers.
Options:
 -h, --help            display this help
 -s, --size=NUM        number of workers (by default is 1)
EOF
    exit "$1"
}

opts=$(getopt -o hs: --long help,size: -n 'parse-options' -- "$@") || usage 1
eval set -- "$opts"

while true; do
  case "$1" in
    -h | --help ) usage 0; shift ;;
    -s | --size ) size=$2; shift ;;
    -- ) shift; break ;;
    * ) break ;;
  esac
done

echo "Creating workers"

for i in $(seq "$size"); do
  docker run -d -h "openqa_worker_$i" --name "openqa_worker_$i" \
  --volumes-from webui_data_1 \
  --network webui_default \
  -e OPENQA_WORKER_INSTANCE="$i" \
  --privileged openqa_worker
done
