#!/bin/bash
#
# Copyright 2019-2020 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

set -ex

destdir=${1:-../os-autoinst}
sha=${2:-$(cat tools/ci/autoinst.sha)}

echo Building os-autoinst $destdir $sha
git clone https://github.com/os-autoinst/os-autoinst.git "$destdir"
( cd "$destdir"
git checkout $sha
cmake -G Ninja -DCMAKE_BUILD_TYPE=Release .
ninja symlinks
)
