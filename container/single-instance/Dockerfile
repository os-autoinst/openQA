#!BuildTag: openQA:single-instance

# hadolint ignore=DL3007
FROM opensuse/tumbleweed:latest
# installing more of packages that are selected in openqa-bootstrap.  Combining here saves installation time
# hadolint ignore=DL3037
RUN zypper in -y openQA-single-instance openQA-bootstrap \
    qemu-arm qemu-ppc qemu-x86 qemu-tools sudo iputils os-autoinst-distri-opensuse-deps && \
    zypper clean -a
EXPOSE 80 443 9526
ENV BYPASS_SYSTEMD_CHECK=1
ENV skip_suse_specifics=1
ENV skip_suse_tests=1

ENTRYPOINT ["/usr/share/openqa/script/openqa-bootstrap"]
