FROM opensuse:42.1
MAINTAINER Jan Sedlak <jsedlak@redhat.com>, Josef Skladanka <jskladan@redhat.com>, wnereiz(@github)

RUN zypper ar -f obs://devel:openQA/openSUSE_Leap_42.1 openQA && \
    zypper ar -f obs://devel:openQA:Leap:42.1/openSUSE_Leap_42.1 openQA-perl-modules && \
    zypper ar -f obs://Virtualization/openSUSE_Leap_42.1 Virtualization && \
    zypper --gpg-auto-import-keys ref && \
    zypper --non-interactive in ca-certificates-mozilla curl && \
    zypper --non-interactive in openQA-worker qemu-kvm && \
    zypper --non-interactive in kmod && \
    zypper --non-interactive in --from Virtualization qemu-ovmf-x86_64

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

ENTRYPOINT ["/usr/share/openqa/script/worker", "--verbose", "--instance"]
CMD ["1"]
