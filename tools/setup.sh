#!/bin/bash

dst="$1"
if [ -z "$dst" ]; then
	echo "please specify where you want to run openqa from" >&2
	exit 1
fi

run()
{
	set -- "$@"
	echo "   running $@"
	"$@"
}

echo "1. setting up directory structure ..."

for i in perl testresults pool/1 factory/iso backlog; do
	run mkdir -p "$dst/$i"
done
run ln -s $PWD/tools $dst/tools

cat <<EOF
2. please run:

sudo tools/initdb

sudo mkdir /usr/share/openqa
sudo ln -s $PWD/www/* /usr/share/openqa

3. copy and adjust etc/apache2 to /etc/apache2

4. setup os-autoinst

git clone git://gitorious.org/os-autoinst/os-autoinst.git $dst/perl/autoinst

git clone git@github.com:openSUSE-Team/os-autoinst-needles.git
ln -s os-autoinst-needles/distri/opensuse $dst/perl/autoinst/distri/opensuse/needles
sudo chown -R wwwrun os-autoinst-needles

EOF
