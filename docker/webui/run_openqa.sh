#!/bin/bash

# prepare environment
rm -f /run/dbus/pid
/usr/share/openqa/script/upgradedb --user geekotest --upgrade_database

# run services
dbus-daemon --system --fork
su geekotest -c '/usr/share/openqa/script/openqa-scheduler &'
su geekotest -c '/usr/share/openqa/script/openqa-websockets &'
su geekotest -c '/usr/share/openqa/script/openqa gru -m production run &'
rcapache2 start && su geekotest -c '/usr/share/openqa/script/openqa prefork -m production --proxy'
