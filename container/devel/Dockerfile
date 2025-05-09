# Specify the license of the container build description (see also the LICENSE file)
# SPDX-License-Identifier: MIT
# Define the names/tags of the container
#!BuildTag: opensuse/openqa_devel:latest opensuse/openqa_devel:%PKG_VERSION% opensuse/openqa_devel:%PKG_VERSION%.%RELEASE%

# Match chromium architectures
#!ExclusiveArch:  x86_64 aarch64 riscv64

# hadolint ignore=DL3006
FROM opensuse/tumbleweed

# Define labels according to https://en.opensuse.org/Building_derived_containers
# labelprefix=org.opensuse.openqa_devel
LABEL org.opencontainers.image.title="openQA devel container"
LABEL org.opencontainers.image.description="openQA development container"
LABEL org.opencontainers.image.version="%PKG_VERSION%.%RELEASE%"
LABEL org.opensuse.reference="registry.opensuse.org/opensuse/openqa_devel:%PKG_VERSION%.%RELEASE%"
LABEL org.openbuildservice.disturl="%DISTURL%"
LABEL org.opencontainers.image.created="%BUILDTIME%"
# endlabelprefix

# hadolint ignore=DL3037
RUN zypper in -y os-autoinst-devel openQA-devel vim nodejs-default git mc perl-Devel-REPL perl-Term-ReadKey podman && \
    zypper clean -a

ENV OPENQA_DIR /opt/openqa
VOLUME $OPENQA_DIR
WORKDIR $OPENQA_DIR
