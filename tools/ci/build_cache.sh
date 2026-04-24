#!/bin/bash
#
# Copyright 2019-2023 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

set -ex

sudo zypper ar -f -p 90 https://download.opensuse.org/repositories/devel:/openQA:/Leap:/16.0/16.0 openQA
sudo zypper ar -f -p 95 http://download.opensuse.org/repositories/devel:openQA/16.0 devel
sudo zypper mr --keep-packages --all
tools/retry sudo zypper --gpg-auto-import-keys ref
sudo zypper -n install $(sed -e 's/\r//' < tools/ci/ci-packages.txt)
if [[ "$(find /var/cache/zypp/packages/ | wc -l)" == 0 ]]; then
    echo "no packages cached"
    exit 1
fi
echo "build_cache.sh done"
