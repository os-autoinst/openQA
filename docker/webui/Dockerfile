FROM opensuse:13.2
MAINTAINER Jan Sedlak <jsedlak@redhat.com>, Josef Skladanka <jskladan@redhat.com>

RUN useradd -m geekotest && \
    zypper --non-interactive --gpg-auto-import-keys in ca-certificates-mozilla curl && \
    zypper ar -f http://download.opensuse.org/repositories/devel:openQA:stable/openSUSE_13.2/devel:openQA:stable.repo && \
    zypper ar -f obs://devel:openQA/openSUSE_13.2 openQA && \
    zypper ar -f obs://devel:openQA:13.2/openSUSE_13.2 openQA-perl-modules && \
    curl https://build.opensuse.org/source/devel:openQA/_pubkey > /tmp/openQA-pubkey && rpm --import /tmp/openQA-pubkey && \
    zypper --non-interactive in --from devel_openQA_stable openQA

# setup apache
RUN gensslcert && \
    a2enmod headers && \
    a2enmod proxy && \
    a2enmod proxy_http && \
    a2enmod proxy_wstunnel && \
    a2enmod ssl && \
    a2enflag SSL
ADD openqa-ssl.conf /etc/apache2/vhosts.d/openqa-ssl.conf
ADD openqa.conf /etc/apache2/vhosts.d/openqa.conf

# set-up shared data and configuration
RUN rm -rf /etc/openqa/openqa.ini /etc/openqa/client.conf \
      /var/lib/openqa/share/factory /var/lib/openqa/share/tests \
      /var/lib/openqa/db/db.sqlite /var/lib/openqa/testresults && \
    mkdir -p /var/lib/openqa/pool && \
    ln -s /data/conf/openqa.ini /etc/openqa/openqa.ini && \
    ln -s /data/conf/client.conf /etc/openqa/client.conf && \
    ln -s /data/factory /var/lib/openqa/share/factory && \
    ln -s /data/tests /var/lib/openqa/share/tests && \
    ln -s /data/testresults /var/lib/openqa/testresults && \
    ln -s /data/db/db.sqlite /var/lib/openqa/db/db.sqlite && \
    chmod -R 777 /var/lib/openqa/pool

VOLUME ["/var/lib/openqa/pool"]

EXPOSE 80 443
CMD rcapache2 start && /usr/share/openqa/script/openqa daemon -m production --proxy
