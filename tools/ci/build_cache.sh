#!/bin/bash
#
# Copyright 2019-2020 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

set -ex

sudo zypper ar -f -p 90 https://download.opensuse.org/repositories/devel:/openQA:/Leap:/15.3/openSUSE_Leap_15.3 openQA
sudo zypper ar -f -p 95 http://download.opensuse.org/repositories/devel:openQA/openSUSE_Leap_15.3 devel
tools/retry sudo zypper --gpg-auto-import-keys ref
sudo zypper -n install --download-only $(cat tools/ci/ci-packages.txt | sed -e 's/\r//' )
sudo rpm -i -f $(find /var/cache/zypp/packages/ | grep '.rpm$')
echo build_cache.sh done
