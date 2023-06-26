# SPDX-License-Identifier: MIT
#!BuildTag: tumbleweed:client opensuse/openqa-client:latest opensuse/openqa-client:%PKG_VERSION% opensuse/openqa-client:%PKG_VERSION%.%RELEASE%
# This container is built on https://build.opensuse.org/package/show/devel:openQA/openQA_container_client.
# hadolint ignore=DL3007
FROM opensuse/tumbleweed:latest

# labelprefix=org.opensuse.openqa-client
LABEL org.opencontainers.image.title="openQA client container"
LABEL org.opencontainers.image.description="A ready to use openQA client"
LABEL org.opencontainers.image.version="%PKG_VERSION%.%RELEASE%"
LABEL org.opensuse.reference="registry.opensuse.org/opensuse/openqa-client:%PKG_VERSION%.%RELEASE%"
LABEL org.openbuildservice.disturl="%DISTURL%"
LABEL org.opencontainers.image.created="%BUILDTIME%"
# endlabelprefix

# hadolint ignore=DL3037
RUN zypper ar -p 95 -f https://download.opensuse.org/repositories/devel:/openQA/openSUSE_Tumbleweed devel_openQA && \
    zypper --gpg-auto-import-keys ref && \
    zypper in -y openQA-client git && \
    zypper clean
