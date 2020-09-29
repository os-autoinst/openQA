#!/bin/bash
set -e

function wait_for_db_creation() {
  echo "Waiting for DB creation"
  while ! $(su geekotest -c 'PGPASSWORD=openqa psql -h db -U openqa --list | grep -qe openqa'); do sleep .1; done
}

function scheduler() {
  su geekotest -c /usr/share/openqa/script/openqa-scheduler-daemon
}

function websockets() {
  su geekotest -c /usr/share/openqa/script/openqa-websockets-daemon
}

function gru() {
  wait_for_db_creation
  su geekotest -c /usr/share/openqa/script/openqa-gru -m production run
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
  # run services
  start_daemon -u geekotest /usr/share/openqa/script/openqa-scheduler &
  start_daemon -u geekotest /usr/share/openqa/script/openqa-websockets &
  start_daemon -u geekotest /usr/share/openqa/script/openqa-livehandler &
  start_daemon -u geekotest /usr/share/openqa/script/openqa gru -m production run &
  apache2ctl start
  start_daemon -u geekotest /usr/share/openqa/script/openqa prefork -m production --proxy
}

# run services
case "$MODE" in
  scheduler ) scheduler;;
  websockets ) websockets;;
  gru ) gru;;
  livehandler ) livehandler;;
  webui ) webui;;
  * ) all_together_apache;;
esac
