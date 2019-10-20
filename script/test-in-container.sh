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

testcase=$1
set -eo pipefail

[ -n "$testcase" ] || (echo No testcase provided; exit 1) >&2
[ -f "$testcase" ] || (echo Cannot find file "$testcase"; exit 1 ) >&2
[ -n "$OSHT_LOCATION" ] || OSHT_LOCATION=/usr/share/osht.sh
[ -f "$OSHT_LOCATION" ] || { echo "1..0 # osht.sh not found, skipped"; exit 0; }
# shellcheck source=/dev/null
source "$OSHT_LOCATION"

thisdir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
circlecidir="$thisdir"/../.circleci
[ -d "$circlecidir" ] || circlecidir="$thisdir"/../../../.circleci
[ -d "$circlecidir" ] || (echo Cannot find .circleci directory; exit 1 ) >&2
basename=$(basename "$testcase")
containername="localtest.$basename"

[[ ${BASH_SOURCE[0]} != *privileged.sh ]] || SKIP test "${PRIVILEGED_TESTS}" != 1 # PRIVILEGED_TESTS is not set to 1
SKIP test "$(docker info 2>&1)" == "" # Docker doesn't seem to be running
PLAN 1

# let's use `docker build` here to utilize docker cache
( 
# shellcheck disable=SC2046 disable=SC2005
echo "FROM registry.opensuse.org/devel/openqa/ci/containers/base:latest
RUN sudo zypper ar -f -p 80 https://download.opensuse.org/repositories/devel:/openQA:/Leap:/15.1/openSUSE_Leap_15.1 openQA
RUN sudo zypper ar -f -p 81 https://download.opensuse.org/repositories/devel:openQA/openSUSE_Leap_15.1 devel
RUN sudo zypper --gpg-auto-import-keys ref
# strip out version information with sed here
RUN sudo zypper -n install $( echo $( (cat "$circlecidir"/dependencies.txt) | sed -e 's/\r//' | sed 's/-[0-9.]*$//' | sort))
RUN sudo zypper -n install apparmor-profiles apparmor-utils"
) | docker build -t "$containername" -f- "$thisdir"

privileged_option=""
[[ ${BASH_SOURCE[0]} != *privileged.sh ]] || privileged_option=--privileged
docker run $privileged_option --rm --name "$containername" -v "$circlecidir/../":/opt/testing_area --entrypoint="/usr/bin/tail" -- "$containername" -f /dev/null &

function cleanup {
    docker stop -t 0 "$containername" >&/dev/null || :
    _osht_cleanup
}

trap cleanup INT TERM EXIT
counter=0

# wait container start
until [ $counter -gt 10 ]; do
  sleep 0.5
  docker exec "$containername" pwd >& /dev/null && break
  ((counter++))
done

docker exec "$containername" pwd >& /dev/null || (echo Cannot start container; exit 1 ) >&2

if [ -n "$CIRCLECI" ]; then # circleci cannot mount volumes, so just copy current dir
    docker cp "$thisdir"/../. "$containername:/opt/testing_area/"
fi

set +e
docker exec -i "$containername" bash < "$testcase"
ret=$?
if [ "$TEST_MATRIX_CONTAINER" != 1 ]; then 
    IS $ret == 0
fi
