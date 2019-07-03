#!/bin/sh -e

DEBUG="${DEBUG:-0}"
INSTALL_FROM_CPAN="${INSTALL_FROM_CPAN:-0}"
UPGRADE_FROM_ZYPPER="${UPGRADE_FROM_ZYPPER:-0}"

export LANG="en_US.UTF-8"
export LC_ALL="en_US.UTF-8"
[ "$DEBUG" -eq 1 ] && set -x

# First, try to upgrade all container dependencies (or we won't catch bugs until a new docker image is built)
[ "$UPGRADE_FROM_ZYPPER" -eq 1 ] && \
  sudo zypper --gpg-auto-import-keys -n ref --force && \
  sudo zypper up -l -y

cp -rd /opt/openqa /opt/testing_area
cd /opt/testing_area/openqa

create_db() {
    set -e
    PGDATA=$(mktemp -d)
    export PGDATA
    echo ">> Creating fake database in ${PGDATA}"
    initdb --auth=trust -N "$PGDATA"

cat >> "$PGDATA"/postgresql.conf <<HEREDOC
listen_addresses='localhost'
unix_socket_directories='$PGDATA'
fsync=off
full_page_writes=off
HEREDOC

    pg_ctl -D "$PGDATA" start -w
    createdb -h "$PGDATA" openqa_test

    export TEST_PG="DBI:Pg:dbname=openqa_test;host=localhost;port=5432"
}


run_as_normal_user() {
    if [ "$INSTALL_FROM_CPAN" -eq 1 ]; then
       echo ">> Trying to get dependencies from CPAN"
           cpanm --local-lib=~/perl5 local::lib && cpanm -n --installdeps .
    else
           cpanm -n --mirror http://no.where/ --installdeps .
    fi
    create_db
    MOJO_TMPDIR=$(mktemp -d)
    export MOJO_TMPDIR
    export OPENQA_LOGFILE=/tmp/openqa-debug.log

    ([ "$INSTALL_FROM_CPAN" -eq 1 ] && eval "$(perl -I ~/perl5/lib/perl5/ -Mlocal::lib)") || true
}

run_as_normal_user
echo ">> Running tests"
sh -c "$*"
