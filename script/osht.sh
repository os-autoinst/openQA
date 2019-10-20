###############################################################################
#  Copyright 2016 Cory Bennett
#
#     Licensed under the Apache License, Version 2.0 (the "License");
#     you may not use this file except in compliance with the License.
#     You may obtain a copy of the License at
#
#         http://www.apache.org/licenses/LICENSE-2.0
#
#     Unless required by applicable law or agreed to in writing, software
#     distributed under the License is distributed on an "AS IS" BASIS,
#     WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#     See the License for the specific language governing permissions and
#     limitations under the License.
###############################################################################
: ${OSHT_MKTEMP=mktemp -t osht.XXXXXX}
: ${OSHT_ABORT=}
: ${OSHT_DIFF=diff -u}
: ${OSHT_JUNIT=}
: ${OSHT_JUNIT_OUTPUT="$(cd "$(dirname "$0")"; pwd)/$(basename "$0")-tests.xml"}
: ${OSHT_STDOUT=$($OSHT_MKTEMP)}
: ${OSHT_STDERR=$($OSHT_MKTEMP)}
: ${OSHT_STDIO=$($OSHT_MKTEMP)}
: ${OSHT_VERBOSE=}
: ${OSHT_WATCH=}

: ${_OSHT_CURRENT_TEST_FILE=$($OSHT_MKTEMP)}
: ${_OSHT_CURRENT_TEST=0}
: ${_OSHT_DEPTH=2}
: ${_OSHT_RUNNER=$($OSHT_MKTEMP)}
: ${_OSHT_DIFFOUT=$($OSHT_MKTEMP)}
: ${_OSHT_FAILED_FILE=$($OSHT_MKTEMP)}
: ${_OSHT_INITPATH=$(pwd)}
: ${_OSHT_JUNIT=$($OSHT_MKTEMP)}
: ${_OSHT_LAPSE=}
: ${_OSHT_PLANNED_TESTS=}
: ${_OSHT_SKIP=}
: ${_OSHT_START=}
: ${_OSHT_TESTING=}
: ${_OSHT_TODO=}

export OSHT_VERSION=1.0.0

declare -a _OSHT_ARGS

function _osht_usage {
    [ -n "${1:-}" ] && echo -e "Error: $1\n" >&2
    cat <<EOF
Usage: $(basename $0) [--output <junit-output-file>] [--junit] [--verbose] [--abort]
Options:
-a|--abort         On the first error abort the test execution
-h|--help          This help message
-j|--junit         Enable JUnit xml writing
-o|--output=<file> Location to write JUnit xml file [default: $OSHT_JUNIT_OUTPUT]
-v|--verbose       Print extra output for debugging tests
-w|--watch         Print output to stdout to allow watching progress on long-running tests
EOF
    exit 0
}


while true; do
    [[ $# == 0 ]] && break
    case $1 in
        -a | --abort) OSHT_ABORT=1; shift;;
        -h | --help) _osht_usage;;
        -j | --junit)  OSHT_JUNIT=1; shift ;;
        -o | --output) OSHT_JUNIT_OUTPUT=$2; shift 2 ;;
        -v | --verbose) OSHT_VERBOSE=1; shift ;;
        -w | --watch) OSHT_WATCH=1; shift ;;
        -- ) shift; break ;;
        -* ) (_osht_usage "Invalid argument $1") >&2 && exit 1;;
        * ) break ;;
    esac
done


function _osht_cleanup {
    local rv=$?
    if [ -z "$_OSHT_PLANNED_TESTS" ]; then
        _OSHT_PLANNED_TESTS=$_OSHT_CURRENT_TEST
        echo "1..$_OSHT_PLANNED_TESTS"
    fi
    if [[ -n $OSHT_JUNIT ]]; then
        _osht_init_junit > $OSHT_JUNIT_OUTPUT
        cat $_OSHT_JUNIT >> $OSHT_JUNIT_OUTPUT
        _osht_end_junit >> $OSHT_JUNIT_OUTPUT
    fi
    local failed=$(_osht_failed)
    rm -f $OSHT_STDOUT $OSHT_STDERR $OSHT_STDIO $_OSHT_CURRENT_TEST_FILE $_OSHT_JUNIT $_OSHT_FAILED_FILE $_OSHT_DIFFOUT $_OSHT_RUNNER
    if [[ $_OSHT_PLANNED_TESTS != $_OSHT_CURRENT_TEST ]]; then
        echo "Looks like you planned $_OSHT_PLANNED_TESTS tests but ran $_OSHT_CURRENT_TEST." >&2
        rv=255
    fi
    if [[ $failed > 0 ]]; then
        echo "Looks like you failed $failed test of $_OSHT_CURRENT_TEST." >&2
        rv=$failed
    fi
          
    exit $rv
}

trap _osht_cleanup INT TERM EXIT

function _osht_xmlencode {
    sed -e 's/\&/\&amp;/g' -e 's/\"/\&quot;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' 
}

function _osht_strip_terminal_escape {
    sed -e $'s/\x1B\[[0-9]*;[0-9]*[m|K|G|A]//g' -e $'s/\x1B\[[0-9]*[m|K|G|A]//g'
}

function _osht_timestamp {
    if [ -n "$_OSHT_TESTING" ]; then
        echo "2016-01-01T08:00:00"
    else
        date "+%Y-%m-%dT%H:%M:%S"
    fi
}

function _osht_init_junit {
    cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuites failures="$(_osht_failed)" name="$0" tests="$_OSHT_PLANNED_TESTS" time="$SECONDS" timestamp="$(_osht_timestamp)" >
EOF
}

function _osht_add_junit {
    if [[ -z $OSHT_JUNIT ]]; then
        return
    fi
    failure=
    if [[ $# != 0 ]]; then
        failure="<failure message=\"test failed\"><![CDATA[$(_osht_debugmsg | _osht_strip_terminal_escape)]]></failure>
    "
    fi
    local stdout=$(cat $OSHT_STDOUT | _osht_strip_terminal_escape)
    local stderr=$(cat $OSHT_STDERR | _osht_strip_terminal_escape)
    local _OSHT_DEPTH=$(($_OSHT_DEPTH+1))
    cat <<EOF >> $_OSHT_JUNIT
  <testcase classname="$(_osht_source)" name="$(printf "%03i" $_OSHT_CURRENT_TEST) - $(_osht_get_line | _osht_xmlencode)" time="$_OSHT_LAPSE" timestamp="$(_osht_timestamp)">
    $failure<system-err><![CDATA[$stderr]]></system-err>
    <system-out><![CDATA[$stdout]]></system-out>
  </testcase>
EOF
}

function _osht_end_junit {
    cat <<EOF
</testsuites>
EOF
}

function _osht_source {
    local parts=($(caller $_OSHT_DEPTH))
    local fn=$(basename ${parts[2]})
    echo ${fn%.*}
}

function _osht_get_line {
    local parts=($(caller $_OSHT_DEPTH))
    (cd $_OSHT_INITPATH && sed "${parts[0]}q;d" ${parts[2]})
}

function _osht_source_file {
    local parts=($(caller $_OSHT_DEPTH))
    echo "${parts[2]}"
}

function _osht_source_linenum {
    local parts=($(caller $_OSHT_DEPTH))
    echo "${parts[0]}"
}

function _osht_increment_test {
    _OSHT_CURRENT_TEST=$(cat $_OSHT_CURRENT_TEST_FILE)
    let _OSHT_CURRENT_TEST=_OSHT_CURRENT_TEST+1
    echo $_OSHT_CURRENT_TEST > $_OSHT_CURRENT_TEST_FILE
    _osht_start
}

function _osht_increment_failed {
    local _FAILED=$(_osht_failed)
    let _FAILED=_FAILED+1
    echo $_FAILED > $_OSHT_FAILED_FILE
}

function _osht_failed {
    [[ -s $_OSHT_FAILED_FILE ]] && cat $_OSHT_FAILED_FILE || echo "0"
}

function _osht_start {
    _OSHT_START=$(date +%s)
}

function _osht_stop {
    local _now=$(date +%s)
    _OSHT_LAPSE=$(($_now - $_OSHT_START))
}

function _osht_ok {
    _osht_stop
    _osht_debug
    echo -n "ok $_OSHT_CURRENT_TEST - $(_osht_get_line)"
    if [ -n "$_OSHT_TODO" ]; then
        echo " # TODO Test Know to fail"
    else
        echo
    fi
    _osht_add_junit
}

function _osht_nok {
    _osht_stop
    if [ -z "$_OSHT_TODO" ]; then
        echo "# ERROR: $(_osht_source_file) at line $(_osht_source_linenum)"
    fi
    _osht_debug
    echo -n "not ok $_OSHT_CURRENT_TEST - $(_osht_get_line)"
    if [ -n "$_OSHT_TODO" ]; then
        echo " # TODO Test Know to fail"
    else
        _osht_increment_failed
        echo
    fi
    _osht_add_junit "${_OSHT_ARGS[@]}"
    if [ -n "$OSHT_ABORT" ]; then
        exit 1
    fi
}

function _osht_run {
    # reset STDIO files
    : >$OSHT_STDOUT
    : >$OSHT_STDERR
    : >$OSHT_STDIO

    cat <<EOF > $_OSHT_RUNNER
#!/bin/bash
set -o monitor
exec 1> >(tee -a -- $OSHT_STDOUT $OSHT_STDIO)
exec 2> >(tee -a -- $OSHT_STDERR $OSHT_STDIO >&2)
function cleanup {
    rv=\$?
    platform=\$(uname -s)
    if [[ \$platform == Darwin ]]; then
        PGRP=\$(ps -p \$\$ -o pgid=)
    else
        PGRP=\$(ps -p \$\$ --no-header -o pgrp)
    fi

    if [[ \$platform == Darwin ]]; then
        PIDS=\$(ps -o pgid=,ppid=,pid=,comm= | awk "\\\$1 == \$PGRP && \\\$4 == \"tee\" {print \\\$2\" \"\\\$3}")
    else
        PIDS=\$(ps --no-headers -o pgrp,ppid,pid,cmd | awk "\\\$1 == \$PGRP && \\\$4 == \"tee\" {print \\\$2\" \"\\\$3}")
    fi
    if [[ -n "\$PIDS" ]]; then
        kill \$PIDS >/dev/null 2>&1
    fi
    return \$rv
}
trap cleanup INT TERM EXIT
"\$@"
EOF
    chmod 755 $_OSHT_RUNNER

    set +e
    if [[ -n "$OSHT_WATCH" ]]; then
        SEDBUFOPT=-u
        if [ $(uname -s) == "Darwin" ]; then
            SEDBUFOPT=-l
        fi
        $_OSHT_RUNNER "$@" 2>&1 | sed $SEDBUFOPT 's/^/# /'
        OSHT_STATUS=${PIPESTATUS[0]}
    else
        $_OSHT_RUNNER "$@" >/dev/null 2>&1
        OSHT_STATUS=$?
    fi
    set -e
}

function _osht_qq {
    declare -a out
    local p
    for p in "$@"; do
        out+=($(printf %q "$p"))
    done
    local IFS=" "
    echo -n "${out[*]}"
}
        
function _osht_debug {
    if [[ -n $OSHT_VERBOSE ]]; then
        _osht_debugmsg | sed 's/^/# /g'
    fi
}

function _osht_debugmsg {
    local parts=($(caller $_OSHT_DEPTH))
    local op=${parts[1]}
    if [[ ${parts[1]} == "TODO" ]]; then
        parts=($(caller $(($_OSHT_DEPTH-1))))
        op=${parts[1]}
    fi
    case $op in
        IS)
            _osht_qq "${_OSHT_ARGS[@]}"; echo;;
        ISNT)
            _osht_qq \! "${_OSHT_ARGS[@]}"; echo;;
        OK)
            _osht_qq test "${_OSHT_ARGS[@]}"; echo;;
        NOK)
            _osht_qq test \! "${_OSHT_ARGS[@]}"; echo;;
        NRUNS|RUNS)
            echo "RUNNING: $(_osht_qq "${_OSHT_ARGS[@]}")"
            echo "STATUS: $OSHT_STATUS"
            echo "STDIO <<EOM"
            cat $OSHT_STDIO
            echo "EOM";;
        DIFF|ODIFF|EDIFF)
            cat $_OSHT_DIFFOUT;;
        GREP|EGREP|OGREP)
            _osht_qq grep -q "${_OSHT_ARGS[@]}"; echo;;
        NGREP|NEGREP|NOGREP)
            _osht_qq \! grep -q "${_OSHT_ARGS[@]}"; echo;;
   esac
}

function _osht_args {
    _OSHT_ARGS=("$@")
}

function SKIP {
    local _OSHT_DEPTH=$(($_OSHT_DEPTH-1))
    "$@" && _OSHT_SKIP=$(_osht_get_line)
    if [ -n "$_OSHT_SKIP" ]; then
        _OSHT_PLANNED_TESTS=0
        echo "1..0 # $_OSHT_SKIP"
        exit 0
    fi
}

function PLAN {
    echo "1..$1"
    _OSHT_PLANNED_TESTS=$1
}

function IS {
    _osht_args "$@"
    _osht_increment_test
    case "$2" in
        =~) [[ $1 =~ $3 ]] && _osht_ok || _osht_nok;;
        !=) [[ $1 != $3 ]] && _osht_ok || _osht_nok;;
        =|==) [[ $1 == $3 ]] && _osht_ok || _osht_nok;;
        *) [ "$1" $2 "$3" ] && _osht_ok || _osht_nok;;
    esac
}

function ISNT {
    _osht_args "$@"
    _osht_increment_test
    case "$2" in
        =~) [[ ! $1 =~ $3 ]] && _osht_ok || _osht_nok;;
        !=) [[ $1 == $3 ]] && _osht_ok || _osht_nok;;
        =|==) [[ $1 != $3 ]] && _osht_ok || _osht_nok;;
        *) [ ! "$1" $2 "$3" ] && _osht_ok || _osht_nok;;
    esac
}

function OK {
    _osht_args "$@"
    _osht_increment_test
    test "$@" && _osht_ok || _osht_nok
}

function NOK {
    _osht_args "$@"
    _osht_increment_test
    test ! "$@" && _osht_ok || _osht_nok
}

function RUNS {
    _osht_args "$@"
    _osht_increment_test
    _osht_run "$@"
    [[ $OSHT_STATUS == 0 ]] && _osht_ok || _osht_nok
}

function NRUNS {
    _osht_args "$@"
    _osht_increment_test
    _osht_run "$@"
    [[ $OSHT_STATUS != 0 ]] && _osht_ok || _osht_nok
}

function GREP {
    _osht_args "$@"
    _osht_increment_test
    grep -q "$@" $OSHT_STDIO && _osht_ok || _osht_nok
}

function EGREP {
    _osht_args "$@"
    _osht_increment_test
    grep -q "$@" $OSHT_STDERR && _osht_ok || _osht_nok
}

function OGREP {
    _osht_args "$@"
    _osht_increment_test
    grep -q "$@" $OSHT_STDOUT && _osht_ok || _osht_nok
}

function NGREP {
    _osht_args "$@"
    _osht_increment_test
    ! grep -q "$@" $OSHT_STDIO  && _osht_ok || _osht_nok
}

function NEGREP {
    _osht_args "$@"
    _osht_increment_test
    ! grep -q "$@" $OSHT_STDERR  && _osht_ok || _osht_nok
}

function NOGREP {
    _osht_args "$@"
    _osht_increment_test
    ! grep -q "$@" $OSHT_STDOUT  && _osht_ok || _osht_nok
}

function DIFF {
    _osht_args $OSHT_DIFF - $OSHT_STDIO
    _osht_increment_test
    tmpfile=$($OSHT_MKTEMP)
    cat - > $tmpfile
    $OSHT_DIFF $tmpfile $OSHT_STDIO | tee $_OSHT_DIFFOUT | sed 's/^/# /g'
    local status=${PIPESTATUS[0]}
    rm $tmpfile
    [[ $status == 0 ]] && _osht_ok || _osht_nok
}

function ODIFF {
    _osht_args $OSHT_DIFF - $OSHT_STDOUT
    _osht_increment_test
    tmpfile=$($OSHT_MKTEMP)
    cat - > $tmpfile
    $OSHT_DIFF $tmpfile $OSHT_STDOUT | tee $_OSHT_DIFFOUT | sed 's/^/# /g'
    local status=${PIPESTATUS[0]}
    rm $tmpfile
    [[ $status == 0 ]] && _osht_ok || _osht_nok
}

function EDIFF {
    _osht_args $OSHT_DIFF - $OSHT_STDERR
    _osht_increment_test
    tmpfile=$($OSHT_MKTEMP)
    cat - > $tmpfile
    $OSHT_DIFF $tmpfile $OSHT_STDERR | tee $_OSHT_DIFFOUT | sed 's/^/# /g'
    local status=${PIPESTATUS[0]}
    rm $tmpfile
    [[ $status == 0 ]] && _osht_ok || _osht_nok
}

function TODO {
    local _OSHT_TODO=1
    local _OSHT_DEPTH=$(($_OSHT_DEPTH+1))
    "$@"
}

