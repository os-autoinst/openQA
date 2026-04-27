#!/bin/bash
set -ex
cache=/var/cache/zypp/packages
if [ -z "$CIRCLE_WORKFLOW_ID" ]; then
    bash "$(dirname "$0")"/build_cache.sh
elif [[ -f $cache/.keep_packages ]] && [[ "$(find "$cache" -name '*.rpm' | wc -l)" -gt 0 ]]; then
    sudo zypper ms --no-refresh --all
    sudo zypper mr --no-refresh --all
    sudo zypper -n in $(sed -e 's/\r//' < tools/ci/ci-packages.txt)
else
    echo "Zypper cache is not populated. Please trigger a cache.fullstack job manually to ensure a cache is available for the latest version."
    exit 1
fi
