#!/bin/bash
set -euo pipefail

echo "dummy isotovideo started with arguments: $*"
if [[ "$*" =~ --version ]]; then
    echo "dummy isotovideo interface v0"
    exit 0
fi

echo "arguments: $*" > autoinst-log.txt

# create fake test results so the web UI thinks we ran at least one test module successfully and considers
# the test as passed
mkdir -p testresults
echo '[{"category":"dummy","name":"fake","script":"none","flags":{}}]' > testresults/test_order.json
echo '{"dents":0,"details":[],"result":"ok"}' > testresults/result-fake.json
echo '{"current_test":"fake","status":"finished","test_execution_paused":0}' > autoinst-status.json.tmp
mv autoinst-status.json{.tmp,}

# also add a vars.json file for less distracting error messages in the test log
echo '{"ARCH":"x86_64","NAME":"fake-test"}' > vars.json

exit 0
