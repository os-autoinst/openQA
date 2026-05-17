# SPDX-License-Identifier: MIT
#!BuildTag: opensuse/openqa_ci:latest opensuse/openqa_ci:%PKG_VERSION% opensuse/openqa_ci:%PKG_VERSION%.%RELEASE%

# Match chromium architectures
#!ExclusiveArch:  x86_64 aarch64 riscv64

# hadolint ignore=DL3006
FROM opensuse/tumbleweed

# hadolint ignore=DL3037
RUN zypper ar -p 95 -f 'http://download.opensuse.org/repositories/devel:openQA/openSUSE_Tumbleweed' devel_openQA && \
    zypper --gpg-auto-import-keys ref && \
    zypper in -y os-autoinst-devel openQA-devel nodejs-default perl-TAP-Harness-JUnit && \
    zypper clean -a

ENV OPENQA_DIR=/opt/openqa
VOLUME $OPENQA_DIR
WORKDIR $OPENQA_DIR
