#!/bin/bash
thisdir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

matrixfile="${1}"
testcase="${matrixfile%.*}.sh"

[ -n "$matrixfile" ] || (echo No maxtrix file provided; exit 1) >&2
[ -n "$testcase" ] || (echo No testcase; exit 1) >&2
[ -f "$matrixfile" ] || (echo Cannot find file "$matrixfile"; exit 1 ) >&2
[ -f "$testcase" ] || (echo Cannot find file "$testcase"; exit 1 ) >&2

# shellcheck source=/dev/null
source "$thisdir/osht.sh"
SKIP test "$(docker info)" == "" # Docker doesn't seem to be running
export TEST_MATRIX_CONTAINER=1
PLAN "$(grep '=' "$matrixfile" | grep -c -v '#')"
while read -r l; do
    eval "$l ""$thisdir""/test-in-container.sh $testcase"
    IS $? == 0 
done < <(grep '=' "$matrixfile" | grep -v '#')
