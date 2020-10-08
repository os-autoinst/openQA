#!/bin/bash
#
# Copyright (C) 2019-2020 SUSE LLC
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along
# with this program; if not, see <http://www.gnu.org/licenses/>.

set -ex

sudo zypper ar -f -p 90 https://download.opensuse.org/repositories/devel:/openQA:/Leap:/15.1/openSUSE_Leap_15.1 openQA
sudo zypper ar -f -p 95 http://download.opensuse.org/repositories/devel:openQA/openSUSE_Leap_15.1 devel
tools/retry sudo zypper --gpg-auto-import-keys ref
sudo zypper -n install --download-only $(cat .circleci/ci-packages.txt | sed -e 's/\r//' )
sudo rpm -i -f $(find /var/cache/zypp/packages/ | grep '.rpm$')
echo build_cache.sh done
