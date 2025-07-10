# SPDX-License-Identifier: MIT
#!BuildTag: openqa-single-instance-devel:latest opensuse/openqa-single-instance-devel:latest opensuse/openqa-single-instance-devel:%PKG_VERSION% opensuse/openqa-single-instance-devel:%PKG_VERSION%.%RELEASE%

# hadolint ignore=DL3006
FROM opensuse/openqa_devel

# labelprefix=org.opensuse.openqa-single-instance-devel
LABEL org.opencontainers.image.title="openQA developer single-instance container"
LABEL org.opencontainers.image.description="A complete openQA developer instance composed of all necessary components to execute openQA tests including an openQA worker"
LABEL org.opencontainers.image.version="%PKG_VERSION%.%RELEASE%"
LABEL org.opensuse.reference="registry.opensuse.org/opensuse/openqa-single-instance-devel:%PKG_VERSION%.%RELEASE%"
LABEL org.openbuildservice.disturl="%DISTURL%"
LABEL org.opencontainers.image.created="%BUILDTIME%"
# endlabelprefix

COPY . /opt/openqa
WORKDIR /opt/openqa

RUN make node_modules

EXPOSE 80 443 9526
ENV skip_suse_specifics=1
ENV skip_suse_tests=1
ENV OPENQA_SERVICE_PORT_DELTA=0
ENV LC_ALL C.UTF-8

ENTRYPOINT ["/opt/openqa/script/openqa-bootstrap"]
