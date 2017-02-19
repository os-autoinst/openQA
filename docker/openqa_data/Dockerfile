FROM opensuse:42.2
MAINTAINER Jan Sedlak <jsedlak@redhat.com>, Josef Skladanka <jskladan@redhat.com>, wnereiz<wnereiz@eienteiland.org>

RUN zypper --non-interactive in ca-certificates-mozilla git wget

ADD data.template /data
ADD scripts /scripts
RUN chmod -R 777 /data /scripts
VOLUME ["/data"]

CMD /usr/bin/tail -f /dev/null
