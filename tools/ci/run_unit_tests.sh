#!/bin/bash
set -ex
export COVERAGE=1
export COVERDB_SUFFIX="_${CIRCLE_JOB}"
# circleCI can be particularly slow sometimes since some time around 2021-06
export OPENQA_TEST_TIMEOUT_SCALE_CI=3
export EXTRA_PROVE_ARGS="-v"
make test-$CIRCLE_JOB
