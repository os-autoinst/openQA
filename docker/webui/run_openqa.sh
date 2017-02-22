#!/bin/bash

# prepare environment
rm -f /run/dbus/pid
if [ ! -f /data/db/db.sqlite ]; then
  /usr/share/openqa/script/initdb --user geekotest --init_database
else
  /usr/share/openqa/script/upgradedb --user geekotest --upgrade_database
fi

# run services
dbus-daemon --system --fork
start_daemon -u geekotest /usr/share/openqa/script/openqa-scheduler &
start_daemon -u geekotest /usr/share/openqa/script/openqa-websockets &
start_daemon -u geekotest /usr/share/openqa/script/openqa gru -m production run &
apache2ctl start
start_daemon -u geekotest /usr/share/openqa/script/openqa prefork -m production --proxy
