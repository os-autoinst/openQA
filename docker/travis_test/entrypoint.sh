#!/bin/bash                                                                                                                                                                                                        

set -e

mkdir -p /opt/testing_area
cp -rd /opt/openqa /opt/testing_area
chown -R $NORMAL_USER:users /opt/testing_area

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
    cpanm -n --mirror http://no.where/ --installdeps .
    if [ $? -eq 0 ]; then
        create_db
        export MOJO_LOG_LEVEL=debug
        export MOJO_TMPDIR=$(mktemp -d)
        export OPENQA_LOGFILE=/tmp/openqa-debug.log
        dbus-run-session -- sh -c "$*"
    else
        echo "Missing depdencies. Please check output above"
    fi
}

export -f create_db run_as_normal_user

su $NORMAL_USER -c "run_as_normal_user $*"
