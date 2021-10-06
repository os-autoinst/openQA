#!/bin/bash
#
# Copyright 2019-2021 SUSE LLC
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
cre="${cre:-"podman"}"
$cre build -t localtest -f- "$thisdir"<<EOF
FROM registry.opensuse.org/devel/openqa/ci/containers/base:latest

RUN sudo zypper ar -f -p 90 https://download.opensuse.org/repositories/devel:/openQA:/Leap:/15.3/openSUSE_Leap_15.3 openQA
RUN sudo zypper ar -f -p 95 http://download.opensuse.org/repositories/devel:openQA/openSUSE_Leap_15.3 devel
RUN sudo zypper --gpg-auto-import-keys ref

RUN sudo zypper -n install $(echo $(cat $thisdir/ci-packages.txt | sed -e 's/\r//' |sort))

COPY build_autoinst.sh .
RUN sudo mkdir '../os-autoinst'
RUN sudo chown 1000 '../os-autoinst'
RUN pwd && ls -la
RUN ./build_autoinst.sh '../os-autoinst' $(cat $thisdir/autoinst.sha)
RUN sudo chown -R 1000 '/opt/testing_area'
WORKDIR /opt/testing_area
USER squamata
EOF
