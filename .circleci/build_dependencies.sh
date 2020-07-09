#!/bin/bash
#
# Copyright (C) 2020 SUSE LLC
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

set -e

thisdir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

CI_PACKAGES=$thisdir/ci-packages.txt
DEPS_BEFORE=$thisdir/gendep_before.txt
DEPS_AFTER=$thisdir/gendep_after.txt

listdeps() {
    rpm -qa --qf "%{NAME}-%{VERSION}\n" | grep -v gpg-pubkey | grep -v openQA | grep -v os-autoinst | sort
}

listdeps > $DEPS_BEFORE

sudo zypper ar -f https://download.opensuse.org/repositories/devel:openQA/openSUSE_Leap_15.1 devel_openQA
sudo zypper ar -f https://download.opensuse.org/repositories/devel:/openQA:/Leap:/15.1/openSUSE_Leap_15.1 devel_openQA_Leap
sudo zypper --gpg-auto-import-keys ref
sudo zypper -n install openQA-devel
sudo zypper -n install perl-TAP-Harness-JUnit

listdeps > $DEPS_AFTER

comm -13 $DEPS_BEFORE $DEPS_AFTER > $CI_PACKAGES

# let's tidy if Tidy version changes
newtidyver="$(git diff $CI_PACKAGES | grep perl-Perl-Tidy | grep '^+' | grep -o '[0-9]*' || :)"
[ -z "$newtidyver" ] || {
    sed -i -e "s/\(Perl::Tidy):\s\+'==\s\)\([0-9]\+\)\(.*\)/\1$newtidyver\3/g" dependencies.yaml
    make update-deps
    tools/tidy
}
