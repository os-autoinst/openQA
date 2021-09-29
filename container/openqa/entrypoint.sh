#!/bin/sh -e

DEBUG="${DEBUG:-0}"
INSTALL_FROM_CPAN="${INSTALL_FROM_CPAN:-0}"
UPGRADE_FROM_ZYPPER="${UPGRADE_FROM_ZYPPER:-0}"

export LANG="en_US.UTF-8"
export LC_ALL="en_US.UTF-8"
[ "$DEBUG" -eq 1 ] && set -x

# First, try to upgrade all container dependencies (or we won't catch bugs
# until a new container image is built)
[ "$UPGRADE_FROM_ZYPPER" -eq 1 ] && \
  sudo zypper --gpg-auto-import-keys -n ref --force && \
  sudo zypper up -l -y

cp -rd /opt/openqa /opt/testing_area
cd /opt/testing_area/openqa

run_as_normal_user() {
    if [ "$INSTALL_FROM_CPAN" -eq 1 ]; then
       echo ">> Trying to get dependencies from CPAN"
           cpanm --local-lib=~/perl5 local::lib && cpanm -n --installdeps .
    else
           cpanm -n --mirror http://no.where/ --installdeps .
    fi
    MOJO_TMPDIR=$(mktemp -d)
    export MOJO_TMPDIR
    export OPENQA_LOGFILE=/tmp/openqa-debug.log
    ([ "$INSTALL_FROM_CPAN" -eq 1 ] && eval "$(perl -I ~/perl5/lib/perl5/ -Mlocal::lib)") || true
}

run_as_normal_user
export USER="${NORMAL_USER}"
eval "$(t/test_postgresql | grep TEST_PG=)"
echo ">> Running tests"
sh -c "$*"
