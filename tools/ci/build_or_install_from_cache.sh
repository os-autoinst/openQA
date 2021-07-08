#!/bin/bash
set -ex
if [ -z "$CIRCLE_WORKFLOW_ID" ]; then
    bash "$(dirname "$0")"/build_cache.sh
else
    packages=$(find /var/cache/zypp/packages/ | grep '.rpm$') || { echo "No RPM packages found, cache is empty, aborting" && exit 1; }
    sudo rpm -i -f $packages
fi
