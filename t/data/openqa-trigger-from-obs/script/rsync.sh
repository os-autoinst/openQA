#!/bin/bash

thisdir="$(cd "$(dirname "${BASH_SOURCE[0]}")" > /dev/null 2>&1 && pwd)"

function sleep_until_file_created {
    for ((i = 0; i < 20; i += 1)); do
        [ ! -f "$thisdir/.$1-ready" ] || return 0
        sleep 1
    done
    return 1
}

[[ "$1" =~ MockProjectLongProcessing* ]] && { sleep_until_file_created "$1" || exit 1; }
[ "$1" != MockProjectError ] || {
    echo >&2 "Mock Error"
    exit 1
}
echo MOCK OK $1
