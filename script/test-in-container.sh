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
set -e pipefail

[ -n "$testcase" ] || (echo No testcase provided; exit 1) >&2
[ -f "$testcase" ] || (echo Cannot find file "$testcase"; exit 1 ) >&2

thisdir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
basename=$(basename "$testcase")
containername="localtest.$basename"

if [ -z "$TEST_MATRIX_CONTAINER" ]; then
    # shellcheck source=/dev/null
    source "$thisdir/osht.sh"
    SKIP test "$(docker info 2>&1)" == "" # Docker doesn't seem to be running
    PLAN 1
fi

# do this from time to time:
# docker pull registry.opensuse.org/devel/openqa/ci/containers/base:latest

# let's use `docker build` here to untilize docker cache
( 
# shellcheck disable=SC2046 disable=SC2005
echo "FROM registry.opensuse.org/devel/openqa/ci/containers/base:latest
RUN sudo zypper ar -f -p 80 https://download.opensuse.org/repositories/devel:/openQA:/Leap:/15.1/openSUSE_Leap_15.1 openQA
RUN sudo zypper ar -f -p 81 http://download.opensuse.org/repositories/devel:openQA/openSUSE_Leap_15.1 devel
RUN sudo zypper --gpg-auto-import-keys ref
RUN sudo zypper -n install $( echo $( (cat "$thisdir"/../.circleci/dependencies.txt) | sed -e 's/\r//' |sort))
RUN sudo zypper -n install apparmor-profiles apparmor-utils"

# now we forward values from parameters from testcase which must be declared like `: ${VARIABLE1:=DEFAULT1} ${VARIABLE2:=DEVAULT2}
# shellcheck disable=SC2016
for l in $(head "$testcase"| grep ': ${'); do
    [[ "$l" == *:=* ]] || continue
    IFS=' }' read -ra VARS <<< "$l"
    for i in "${VARS[@]}"; do
        # echo i=$i
        i=${i#\$\{}
        variable_name=${i%:=*}
        [ -z "${!variable_name}" ] || echo "ENV $variable_name=${!variable_name}"
    done
done
) | docker build -t "$containername" -f- "$thisdir"


docker run --rm --name "$containername" -v "$thisdir/../":/opt/testing_area --entrypoint="/usr/bin/tail" -- "$containername" -f /dev/null &

function cleanup {
    docker stop -t 0 "$containername" >&/dev/null || :
    if [ "$TEST_MATRIX_CONTAINER" != 1 ]; then
        _osht_cleanup
    fi
}

trap cleanup INT TERM EXIT
counter=0

until [ $counter -gt 10 ]; do
  sleep 0.5
  docker exec "$containername" pwd >& /dev/null && break
  ((counter++))
done

if [ -n "$CIRCLECI" ]; then # circleci cannot mount volumes, so just copy current dir
    docker cp "$thisdir"/../. "$containername:/opt/testing_area/"
fi

set +e
docker exec -i "$containername" bash < "$testcase"
ret=$?
if [ "$TEST_MATRIX_CONTAINER" == 1 ]; then 
    ( exit $ret )
else
    IS $ret == 0
fi
