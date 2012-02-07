#!/bin/bash
# sudo zypper -n in gcc python-devel python-pip mercurial curlftpfs
# sudo pip install mozmill mercurial
# needed for mozmill-automation:
sudo perl -i.bak -pe 's{^BuildID}{SourceRepository=http://hg.mozilla.org/mozilla-central\n$&}' /usr/lib*/firefox/application.ini
sudo dd if=/dev/zero of=$(echo /usr/lib*/firefox/defaults/preferences/kde.js) count=0 # truncate because it interferes with mozmill
hg clone http://hg.mozilla.org/qa/mozmill-tests
hg clone http://hg.mozilla.org/qa/mozmill-automation

mkdir ffmnt
curlftpfs ftp://ftp.mozilla.org/pub/firefox/nightly/latest-mozilla-central/ ffmnt
(
	cp -a $(ls ffmnt/firefox-*`uname -m`.tar.bz2|tail -1) .
	fusermount -u ffmnt
	tar xjf firefox-*.tar.bz2
	rm -f firefox-*.tar.bz2
)

cd
echo "qa_mozmill_setup.sh done" > /dev/ttyS0

