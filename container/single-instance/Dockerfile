# SPDX-License-Identifier: MIT
#!BuildTag: openqa-single-instance:latest opensuse/openqa-single-instance:latest opensuse/openqa-single-instance:%PKG_VERSION% opensuse/openqa-single-instance:%PKG_VERSION%.%RELEASE%

# hadolint ignore=DL3006
FROM opensuse/tumbleweed

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
RUN zypper in -y openQA-single-instance openQA-bootstrap \
    retry \
    qemu-arm qemu-ppc qemu-x86 qemu-tools sudo iputils os-autoinst-distri-opensuse-deps \
    qemu-hw-display-virtio-gpu qemu-hw-display-virtio-gpu-pci && \
    zypper clean -a
RUN cat > /etc/openqa/workers.ini <<EOF
[global]
HOST = http://localhost:9526
EOF

EXPOSE 80 443 9526
ENV skip_suse_specifics=1
ENV skip_suse_tests=1
ENV OPENQA_SERVICE_PORT_DELTA=0
ENV LC_ALL C.UTF-8

ENTRYPOINT ["/usr/share/openqa/script/openqa-bootstrap"]
HEALTHCHECK CMD curl -f http://localhost || exit 1
