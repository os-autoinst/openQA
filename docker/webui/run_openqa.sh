#!/bin/bash

# prepare environment
rm -f /run/dbus/pid
/usr/share/openqa/script/upgradedb --user geekotest --upgrade_database

# run services
dbus-daemon --system --fork
start_daemon -u geekotest /usr/share/openqa/script/openqa-scheduler &
start_daemon -u geekotest /usr/share/openqa/script/openqa-websockets &
start_daemon -u geekotest /usr/share/openqa/script/openqa gru -m production run &
rcapache2 start
start_daemon -u geekotest /usr/share/openqa/script/openqa prefork -m production --proxy
