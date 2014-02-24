#!/bin/bash
# script to prepare a development environment for openqa

dst=/var/lib/openqa

run()
{
	set -- "$@"
	echo "   running $@"
	"$@"
}

for i in perl testresults pool/1 factory/iso backlog; do
	run sudo install -d -m 755 "$dst/$i"
done
run sudo ln -s $PWD/tools $dst/tools
run sudo install -d -m 755 -o $USER /var/lib/openqa/db
run tools/initdb

run git clone git://gitorious.org/os-autoinst/os-autoinst.git $dst/perl/autoinst

run $dst/perl/autoinst/tools/fetchneedles

echo "+++ done. now start the web ui:"
echo "morbo script/openqa"
