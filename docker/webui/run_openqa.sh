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
  # run services
  su geekotest -c /usr/share/openqa/script/openqa-scheduler-daemon &
  su geekotest -c /usr/share/openqa/script/openqa-websockets-daemon &
  su geekotest -c /usr/share/openqa/script/openqa-gru &
  su geekotest -c /usr/share/openqa/script/openqa-livehandler-daemon &
  apache2ctl start
  su geekotest -c /usr/share/openqa/script/openqa-webui-daemon
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
