#!/bin/bash
set -ex
target="${1:?"Specify a makefile target"}"
export COVERAGE=1
export COVERDB_SUFFIX="_${target}"
# Enable JUnit-compatible test results
export JUNIT_PACKAGE=openQA
export JUNIT_NAME_MANGLE=perl
export JUNIT_OUTPUT_FILE=test-results/junit/$target.xml
# Be aware that this option saves all verbose output caught by "prove"
# into test artifact files whereas the error output is still shows up
# where prove is executed to show initial context in case of failed
# tests or other problems. The "--merge" option of prove would loose
# that context in the prove calling context.
export PERL_TEST_HARNESS_DUMP_TAP=test-results
export HARNESS='--harness TAP::Harness::JUnit --timer'
mkdir -p test-results/junit
sudo chown -R $USER test-results
# circleCI can be particularly slow sometimes since some time around 2021-06
export OPENQA_TEST_TIMEOUT_SCALE_CI=3
export EXTRA_PROVE_ARGS="-v"
export OPENQA_FULLSTACK_TEMP_DIR=$PWD/test-results/fullstack
make test-$target
