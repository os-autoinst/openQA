#!/bin/bash -e
set -euo pipefail

depid=$(date -I)
# more specific branch name if the same exists
! git ls-remote --exit-code -- origin "dependency_$depid" || depid=$(date +%Y-%m-%dT%H%M%S)
git checkout -b dependency_"$depid"

msg="chore(deps): Dependency cron $depid"
git status

set +o pipefail

sha_file=tools/ci/autoinst.sha
perl_version=$(perl -e 'print $]')
new_sha=$(curl -s https://api.github.com/repos/os-autoinst/os-autoinst/commits | grep sha | head -n 1 | grep -o -E '[0-9a-f]{40}')
new_ver=$perl_version-$new_sha
current_ver=$(cat "$sha_file")
[[ $current_ver == "$new_ver" ]] && exit 0

echo -n "$new_ver" > "$sha_file"

sudo zypper -n --gpg-auto-import-keys install git hub curl
hub --version
git add "$sha_file"
git commit -m "$msg"
git push -q -f https://token@github.com/os-autoinst-bot/openQA.git dependency_"$depid"
hub pull-request -m "$msg" --base "$CIRCLE_PROJECT_USERNAME":"$CIRCLE_BRANCH" --head "os-autoinst-bot:dependency_$depid"
