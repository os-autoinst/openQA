#!/bin/bash

mkdir -p /var/run/postgresql && chown -R postgres:postgres /var/run/postgresql
chown -R postgres:postgres "$OPENQA_DIR" "$PGDATA" && chmod 777 "$OPENQA_DIR" "$PGDATA"

su postgres <<EOF
initdb --auth-local=peer -N $PGDATA -U postgres
echo "listen_addresses=''" >> $PGDATA/postgresql.conf
echo "fsync=off" >> $PGDATA/postgresql.conf
echo "full_page_writes=off" >> $PGDATA/postgresql.conf

pg_ctl -D $PGDATA start -w
createdb openqa_test

export TEST_PG="DBI:Pg:dbname=openqa_test"

sh -c "$*"
EOF
