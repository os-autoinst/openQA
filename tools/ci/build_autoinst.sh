#!/bin/bash
#
# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

set -ex
destdir=${1:-../os-autoinst}
sha=${2:-$(cat tools/ci/autoinst.sha)}

echo "Building os-autoinst $destdir $sha"
if [[ ! -d $destdir ]]; then
    git clone https://github.com/os-autoinst/os-autoinst.git "$destdir"
    git -C "$destdir" checkout "${sha##*-}"
    cmake -S "$destdir" -B "$destdir" -G Ninja -DCMAKE_BUILD_TYPE=Release
fi
cmake --build "$destdir" --target symlinks
chown -R 1000 "$destdir"
