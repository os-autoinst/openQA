#!/bin/bash
#
# Copyright (C) 2019 SUSE LLC
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

set -e

thisdir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

docker pull registry.opensuse.org/devel/openqa/ci/containers/base:latest
docker run --rm --name gendep --entrypoint="/usr/bin/tail" registry.opensuse.org/devel/openqa/ci/containers/base:latest -f /dev/null &

function cleanup {
  docker stop -t 0 gendep || :
}

trap cleanup EXIT

while :; do
  sleep 0.5
  docker exec gendep ls 2>/dev/null && break
done
 
docker exec gendep rpm -qa --qf "%{NAME}-%{VERSION}\n" |sort > gendep_before.txt
docker exec gendep sudo zypper ar -f https://download.opensuse.org/repositories/devel:/openQA:/Leap:/15.1/openSUSE_Leap_15.1 openQA
docker exec gendep sudo zypper ar -f http://download.opensuse.org/repositories/devel:openQA/openSUSE_Leap_15.1 devel
docker exec gendep sudo zypper --gpg-auto-import-keys ref
docker exec gendep sudo zypper -n install openQA-devel

docker exec gendep rpm -qa --qf "%{NAME}-%{VERSION}\n" |sort > gendep_after.txt
comm -13 gendep_before.txt gendep_after.txt | grep -v gpg-pubkey | grep -v openQA | grep -v os-autoinst > "$thisdir/dependencies.txt"
