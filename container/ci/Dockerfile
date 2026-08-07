# SPDX-License-Identifier: MIT
#!BuildTag: opensuse/openqa_ci:latest opensuse/openqa_ci:%PKG_VERSION% opensuse/openqa_ci:%PKG_VERSION%.%RELEASE%

# Match chromium architectures
#!ExclusiveArch:  x86_64 aarch64 riscv64

# hadolint ignore=DL3006
FROM opensuse/tumbleweed

# t/33-developer_mode.t exposes a real bug in the isotovideo <-> backend IPC
# (poo#205206): a reply is lost, so the test keeps waiting for something that
# never happens and runs into the runtime limit. Downgrading chromedriver and
# chromium to 150 empirically avoids it; why it makes a difference is not
# understood, so this is only a stopgap to keep CI usable, not a fix and not a
# claim that chromedriver is at fault. Remove once the IPC bug is fixed.
# x86_64-only: the history mirror publishes no other architecture.
# hadolint ignore=DL3037
RUN zypper ar -p 95 -f 'https://download.opensuse.org/repositories/devel:openQA/openSUSE_Tumbleweed' devel_openQA && \
    zypper --gpg-auto-import-keys ref && \
    zypper in -y os-autoinst-devel openQA-devel nodejs-default perl-TAP-Harness-JUnit && \
    if [ "$(uname -m)" = "x86_64" ]; then \
        zypper in -y --oldpackage \
            'https://download.opensuse.org/history/20260731/tumbleweed/repo/oss/x86_64/chromedriver-150.0.7871.186-1.1.x86_64.rpm' \
            'https://download.opensuse.org/history/20260731/tumbleweed/repo/oss/x86_64/chromium-150.0.7871.186-1.1.x86_64.rpm' && \
        zypper al chromedriver chromium; \
    fi && \
    zypper clean -a

ENV OPENQA_DIR=/opt/openqa
VOLUME $OPENQA_DIR
WORKDIR $OPENQA_DIR
