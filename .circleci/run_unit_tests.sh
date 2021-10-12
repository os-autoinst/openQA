#!/bin/bash
set -ex
# downgrade chromedriver from problematic version to last good version, see https://progress.opensuse.org/issues/100850
rpm -q chromedriver | grep -v 94.0.4606.71 || sudo zypper -n in --oldpackage chromedriver-93.0.4577.82-bp153.2.28.1 chromium-93.0.4577.82-bp153.2.28.1
export COVERAGE=1
export COVERDB_SUFFIX="_${CIRCLE_JOB}"
# circleCI can be particularly slow sometimes since some time around 2021-06
export OPENQA_TEST_TIMEOUT_SCALE_CI=3
export EXTRA_PROVE_ARGS="-v"
make test-$CIRCLE_JOB
