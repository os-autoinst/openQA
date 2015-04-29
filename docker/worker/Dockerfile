FROM opensuse:13.2
MAINTAINER Jan Sedlak <jsedlak@redhat.com>, Josef Skladanka <jskladan@redhat.com>

RUN useradd -m geekotest && \
    zypper --non-interactive --gpg-auto-import-keys in ca-certificates-mozilla curl && \
    zypper ar -f http://download.opensuse.org/repositories/devel:openQA:stable/openSUSE_13.2/devel:openQA:stable.repo && \
    zypper ar -f obs://devel:openQA/openSUSE_13.2 openQA && \
    zypper ar -f obs://devel:openQA:13.2/openSUSE_13.2 openQA-perl-modules && \
    curl https://build.opensuse.org/source/devel:openQA/_pubkey > /tmp/pubkey && rpm --import /tmp/pubkey && \
    zypper --non-interactive in --from devel_openQA_stable openQA-worker qemu-kvm

# set-up qemu
RUN mkdir -p /root/qemu
ADD kvm-mknod.sh /root/qemu/kvm-mknod.sh
RUN chmod +x /root/qemu/*.sh && /root/qemu/kvm-mknod.sh && \
    # set-up shared data and configuration
    rm -rf /etc/openqa/client.conf /etc/openqa/workers.ini \
      /var/lib/openqa/pool && \
    mkdir -p /var/lib/openqa/share && \
    ln -s /data/conf/client.conf /etc/openqa/client.conf && \
    ln -s /data/conf/workers.ini /etc/openqa/workers.ini && \
    ln -s /data/factory /var/lib/openqa/share/factory && \
    ln -s /data/tests /var/lib/openqa/share/tests

ENTRYPOINT ["/usr/share/openqa/script/worker", "--instance"]
CMD ["1"]
