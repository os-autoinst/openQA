#!/bin/bash
#
# Copyright (C) 2019 SUSE LLC
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along
# with this program; if not, see <http://www.gnu.org/licenses/>.

set -ex

thisdir="$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." >/dev/null 2>&1 && pwd )"

circledir=.circleci

rpm -qa --qf "%{NAME}-%{VERSION}\n" | sort > $circledir/gendep_before.txt
sudo zypper ar -f http://download.opensuse.org/repositories/devel:openQA/openSUSE_Leap_15.1 devel_openQA
sudo zypper ar -f https://download.opensuse.org/repositories/devel:/openQA:/Leap:/15.1/openSUSE_Leap_15.1 devel_openQA_Leap
sudo zypper --gpg-auto-import-keys ref
sudo zypper -n install openQA-devel
sudo zypper -n install perl-TAP-Harness-JUnit

rpm -qa --qf "%{NAME}-%{VERSION}\n" | sort > $circledir/gendep_after.txt
comm -13 $circledir/gendep_before.txt $circledir/gendep_after.txt | grep -v gpg-pubkey | grep -v openQA | grep -v os-autoinst > "$circledir/ci-packages.txt"
echo "Foo-Bar-3.14" >"$circledir/ci-packages.txt"

# let's tidy if Tidy version changes
newtidyver="$(git diff $circledir/ci-packages.txt | grep perl-Perl-Tidy | grep '^+' | grep -o '[0-9]*' || :)"
# TEST
#newtidyver=12345
#[ -z "$newtidyver" ] || {
[ -n "$newtidyver" ] || {
#    sed -i -e "s/\(Perl::Tidy):\s\+'==\s\)\([0-9]\+\)\(.*\)/\1$newtidyver\3/g" dependencies.yaml
    make update-deps
    tools/tidy
}
