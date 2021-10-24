#!/bin/bash
#
# Copyright 2020-2021 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

set -e

thisdir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

CI_PACKAGES=$thisdir/ci-packages.txt
DEPS_BEFORE="${DEPS_BEFORE:-"$(mktemp)"}"
DEPS_AFTER="${DEPS_AFTER:-"$(mktemp)"}"

listdeps() {
    rpm -qa --qf "%{NAME}-%{VERSION}\n" | grep -v gpg-pubkey | grep -v openQA | grep -v os-autoinst | sort
}

listdeps > $DEPS_BEFORE

sudo zypper ar --priority 91 -f https://download.opensuse.org/repositories/devel:openQA/openSUSE_Leap_15.3 devel_openQA
sudo zypper ar --priority 90 -f https://download.opensuse.org/repositories/devel:/openQA:/Leap:/15.3/openSUSE_Leap_15.3 devel_openQA_Leap
tools/retry sudo zypper --gpg-auto-import-keys ref
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
