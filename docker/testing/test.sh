#! /bin/sh

set -ex

cd /os-autoinst
git pull
make
cd ppmclibs
# perl makefiles are special
make || make || make
cd /openQA
git remote add test $1
git fetch test
git reset --hard test/$2
eval $(dbus-launch --sh-syntax)
export FULLSTACK=1
export MOJO_LOG_LEVEL=debug
if test -n "$3"; then
  /root/bin/perlw "perl $3"
else
  /root/bin/perlw "prove -r"
fi

