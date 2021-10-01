FROM opensuse/leap:15.3
LABEL maintainer Jan Sedlak <jsedlak@redhat.com>, Josef Skladanka <jskladan@redhat.com>, wnereiz <wnereiz@eienteiland.org>, Sergio Lindo Mansilla <slindomansilla@suse.com>
LABEL version="0.3"

# hadolint ignore=DL3037
RUN zypper in -y ca-certificates-mozilla git wget && zypper clean

COPY data.template /data
COPY scripts /scripts
RUN chmod -R 777 /data /scripts
VOLUME ["/data"]

CMD ["/usr/bin/tail", "-f", "dev/null"]
