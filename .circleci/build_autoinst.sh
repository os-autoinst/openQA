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

destdir=${1:-../os-autoinst}
sha=${2:-$(cat .circleci/autoinst.sha)}

echo Building os-autoinst $destdir $sha
git clone https://github.com/os-autoinst/os-autoinst.git "$destdir"
( cd "$destdir"
git checkout $sha
cmake -G Ninja -DCMAKE_BUILD_TYPE=Release .
ninja symlinks
)
