# SPDX-License-Identifier: MIT
#!BuildTag: openqa-single-instance-codespaces:latest opensuse/openqa-single-instance-codespaces:latest opensuse/openqa-single-instance-codespaces:%PKG_VERSION% opensuse/openqa-single-instance-codespaces:%PKG_VERSION%.%RELEASE%

# hadolint ignore=DL3006
FROM openqa-single-instance

# labelprefix=org.opensuse.openqa-single-instance-codespaces
LABEL org.opencontainers.image.title="openQA single-instance container for Codespaces"
LABEL org.opencontainers.image.description="A complete openQA instance composed of all necessary components to execute openQA tests including an openQA worker"
LABEL org.opencontainers.image.version="%PKG_VERSION%.%RELEASE%"
LABEL org.opensuse.reference="registry.opensuse.org/opensuse/openqa-single-instance-codespaces:%PKG_VERSION%.%RELEASE%"
LABEL org.openbuildservice.disturl="%DISTURL%"
LABEL org.opencontainers.image.created="%BUILDTIME%"
# endlabelprefix

# install Codespaces requirements
# hadolint ignore=DL3037
RUN zypper in -y awk tar && \
    zypper clean -a
