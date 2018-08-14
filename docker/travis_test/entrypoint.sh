#!/bin/bash                                                                                                                                                                                                        

set -e

INSTALL_FROM_CPAN="${INSTALL_FROM_CPAN:-0}"

# First, try to upgrade all container dependencies (or we won't catch bugs until a new docker image is built)
sudo zypper --gpg-auto-import-keys -n ref --force && sudo zypper up -l -y

cp -rd /opt/openqa /opt/testing_area

cd /opt/testing_area/openqa

function create_db {
    set -e
    export PGDATA=$(mktemp -d)
    initdb --auth=trust -N $PGDATA

cat >> $PGDATA/postgresql.conf <<HEREDOC
listen_addresses='localhost'                                                                                                                                                                                       
unix_socket_directories='$PGDATA'                                                                                                                                                                                  
fsync=off                                                                                                                                                                                                          
full_page_writes=off                                                                                                                                                                                               
HEREDOC

    pg_ctl -D $PGDATA start -w
    createdb -h $PGDATA openqa_test

    export TEST_PG="DBI:Pg:dbname=openqa_test;host=localhost;port=5432"
}


function run_as_normal_user {
    [ "$INSTALL_FROM_CPAN" -eq 1 ] && \
	      (cpanm --local-lib=~/perl5 local::lib && cpanm -n --installdeps . ) || \
	      cpanm -n --mirror http://no.where/ --installdeps .

    if [ $? -eq 0 ]; then
        create_db
        export MOJO_LOG_LEVEL=debug
        export MOJO_TMPDIR=$(mktemp -d)
        export OPENQA_LOGFILE=/tmp/openqa-debug.log
    else
        echo "Missing depdencies. Please check output above"
    fi

    [ "$INSTALL_FROM_CPAN" -eq 1 ] && eval $(perl -I ~/perl5/lib/perl5/ -Mlocal::lib)
}

export -f create_db run_as_normal_user



run_as_normal_user;

dbus-run-session -- sh -c "$*"
