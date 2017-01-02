#! /bin/sh

cd /home/travis/openQA
git fetch origin
git reset --hard origin/try_full_stack
eval $(dbus-launch --sh-syntax)
export FULLSTACK=1
export MOJO_LOG_LEVEL=debug
perl t/full-stack.t
