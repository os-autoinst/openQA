#!/bin/bash -e
set -euo pipefail

depid=$(date -I)
# more specific branch name if the same exists
! git ls-remote --exit-code -- origin "dependency_$depid" || depid=$(date +%Y-%m-%dT%H%M%S)
git checkout -b dependency_"$depid"
bash tools/ci/build_dependencies.sh

git status
git --no-pager diff tools/ci/ci-packages.txt
git diff --quiet tools/ci/ci-packages.txt || (
    set +o pipefail
    sudo zypper -n install git hub curl
    hub --version
    curl -s https://api.github.com/repos/os-autoinst/os-autoinst/commits | grep sha | head -n 1 | grep -o -E '[0-9a-f]{40}' > tools/ci/autoinst.sha
    git add tools/ci/ci-packages.txt tools/ci/autoinst.sha
    # these might have changed by tidy in tools/ci/build_dependencies.sh
    git add cpanfile dbicdh dependencies.yaml tools/* script/* lib/* t/*
    git commit -m "Dependency cron $depid"
    git push -q -f https://token@github.com/openqabot/openQA.git dependency_"$depid"
    hub pull-request -m "Dependency cron $depid" --base "$CIRCLE_PROJECT_USERNAME":"$CIRCLE_BRANCH" --head "openqabot:dependency_$depid"
)
