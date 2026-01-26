#!/bin/bash
#
# Copyright 2019-2023 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

set -ex

sudo zypper ar -f -p 90 https://download.opensuse.org/repositories/devel:/openQA:/Leap:/15.6/15.6 openQA
sudo zypper ar -f -p 95 http://download.opensuse.org/repositories/devel:openQA/15.6 devel
tools/retry sudo zypper --gpg-auto-import-keys ref
sudo zypper -n install --download-only $(sed -e 's/\r//' < tools/ci/ci-packages.txt)
#sudo rpm -i -f $(find /var/cache/zypp/packages/ | grep 'foo.rpm$')
sudo zypper -n install perl-App-cpanminus perl-XML-SAX perl-XML-SAX-Expat perl-Syntax-Keyword-Try
sudo cpanm TAP::Harness::JUnit

echo "build_cache.sh done"
