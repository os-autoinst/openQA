# SPDX-License-Identifier: MIT
#!BuildTag: openqa-single-instance:latest opensuse/openqa-single-instance:latest opensuse/openqa-single-instance:%PKG_VERSION% opensuse/openqa-single-instance:%PKG_VERSION%.%RELEASE%

# hadolint ignore=DL3006
FROM opensuse/leap:15.5

# labelprefix=org.opensuse.openqa-single-instance
LABEL org.opencontainers.image.title="openQA single-instance container"
LABEL org.opencontainers.image.description="A complete openQA instance composed of all necessary components to execute openQA tests including an openQA worker"
LABEL org.opencontainers.image.version="%PKG_VERSION%.%RELEASE%"
LABEL org.opensuse.reference="registry.opensuse.org/opensuse/openqa-single-instance:%PKG_VERSION%.%RELEASE%"
LABEL org.openbuildservice.disturl="%DISTURL%"
LABEL org.opencontainers.image.created="%BUILDTIME%"
# endlabelprefix

# installing more of packages that are selected in openqa-bootstrap.  Combining here saves installation time
# hadolint ignore=DL3037
RUN zypper ar -f -p 95 http://download.opensuse.org/repositories/devel:openQA/15.5 devel_openQA && \
    zypper --gpg-auto-import-keys ref && \
    zypper in -y openQA-single-instance openQA-bootstrap \
    qemu-arm qemu-ppc qemu-x86 qemu-tools sudo iputils os-autoinst-distri-opensuse-deps && \
    zypper clean -a
EXPOSE 80 443 9526
ENV skip_suse_specifics=1
ENV skip_suse_tests=1
ENV OPENQA_SERVICE_PORT_DELTA=0

ENTRYPOINT ["/usr/share/openqa/script/openqa-bootstrap"]
HEALTHCHECK CMD curl -f http://localhost || exit 1
