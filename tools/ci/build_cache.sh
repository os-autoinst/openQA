#!/bin/bash
#
# Copyright 2019-2023 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

set -ex

sudo zypper ar -f -p 90 https://download.opensuse.org/repositories/devel:/openQA:/Leap:/16.0/16.0 openQA
sudo zypper ar -f -p 95 http://download.opensuse.org/repositories/devel:openQA/16.0 devel
tools/retry sudo zypper --gpg-auto-import-keys ref
ci_packages=$(sed -e 's/\r//' < tools/ci/ci-packages.txt)
touch /var/cache/zypp/packages/.keep_packages
sudo zypper -n in $ci_packages
echo "build_cache.sh done"
