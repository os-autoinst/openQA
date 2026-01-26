#!/bin/bash
set -ex
if [ -z "$CIRCLE_WORKFLOW_ID" ]; then
    bash "$(dirname "$0")"/build_cache.sh
else
    packages=$(find /var/cache/zypp/packages/ | grep '.rpm$') || { echo "No RPM packages found. The cache is empty. Please trigger a cache.fullstack job manually to ensure a cache is available for the latest version." && exit 0; }
    sudo rpm -i -f $packages
fi
