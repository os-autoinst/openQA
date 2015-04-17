FROM opensuse:13.2
MAINTAINER Jan Sedlak <jsedlak@redhat.com> Josef Skladanka <jskladan@redhat.com>

RUN zypper --non-interactive --gpg-auto-import-keys in ca-certificates git wget

ADD data.template /data
ADD scripts /scripts
RUN chmod -R 777 /data /scripts
VOLUME ["/data"]

CMD /usr/bin/tail -f /dev/null
