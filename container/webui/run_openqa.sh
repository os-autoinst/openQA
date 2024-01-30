#!/bin/bash
set -e

function wait_for_db_creation() {
    echo "Waiting for DB creation"
    while ! su geekotest -c 'PGPASSWORD=openqa psql -h db -U openqa --list | grep -qe openqa'; do sleep .1; done
}

function upgradedb() {
    wait_for_db_creation
    su geekotest -c '/usr/share/openqa/script/upgradedb --upgrade_database'
}

function scheduler() {
    su geekotest -c /usr/share/openqa/script/openqa-scheduler-daemon
}

function websockets() {
    su geekotest -c /usr/share/openqa/script/openqa-websockets-daemon
}

function gru() {
    wait_for_db_creation
    su geekotest -c /usr/share/openqa/script/openqa-gru
}

function livehandler() {
    wait_for_db_creation
    su geekotest -c /usr/share/openqa/script/openqa-livehandler-daemon
}

function webui() {
    wait_for_db_creation
    su geekotest -c /usr/share/openqa/script/openqa-webui-daemon
}

function all_together_apache() {
    # use certificate that comes with Mojolicious if none configured by the user (by making one available via `-v`)
    local mojo_resources=$(perl -e 'use Mojolicious; print(Mojolicious->new->home->child("Mojo/IOLoop/resources"))')
    cp --no-clobber "$mojo_resources"/server.crt /etc/apache2/ssl.crt/server.crt || :
    cp --no-clobber "$mojo_resources"/server.key /etc/apache2/ssl.key/server.key || :
    cp --no-clobber "$mojo_resources"/server.crt /etc/apache2/ssl.crt/ca.crt || :

    # run the database within the container if no database is configured by the user (by making one available via `-v`)
    if [[ ! -e /data/conf/database.ini ]]; then
        mkdir -p /data/conf
        echo -e "[production]\ndsn = DBI:Pg:dbname=openqa" > /data/conf/database.ini
        chown -R postgres:postgres /var/lib/pgsql # ensure right ownership in case `/var/lib/pgsql` is from host via `-v`
        su postgres -c '/usr/share/postgresql/postgresql-script start'
        su postgres -c '/usr/bin/openqa-setup-db'
    fi

    # run services and apache2
    su geekotest -c /usr/share/openqa/script/openqa-scheduler-daemon &
    su geekotest -c /usr/share/openqa/script/openqa-websockets-daemon &
    su geekotest -c /usr/share/openqa/script/openqa-gru &
    su geekotest -c /usr/share/openqa/script/openqa-livehandler-daemon &
    apache2ctl start
    su geekotest -c /usr/share/openqa/script/openqa-webui-daemon
}

usermod --shell /bin/sh geekotest

# run services
case "$MODE" in
    upgradedb) upgradedb ;;
    scheduler) scheduler ;;
    websockets) websockets ;;
    gru) gru ;;
    livehandler) livehandler ;;
    webui) webui ;;
    *) all_together_apache ;;
esac
