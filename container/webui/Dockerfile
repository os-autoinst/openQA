# SPDX-License-Identifier: MIT
#!BuildTag: openqa_webui:latest opensuse/openqa-webui:latest opensuse/openqa-webui:%PKG_VERSION% opensuse/openqa-webui:%PKG_VERSION%.%RELEASE%
FROM opensuse/leap:15.6

# labelprefix=org.opensuse.openqa-webui
LABEL org.opencontainers.image.title="openQA webui container"
LABEL org.opencontainers.image.description="An openQA webui instance including Apache webserver"
LABEL org.opencontainers.image.version="%PKG_VERSION%.%RELEASE%"
LABEL org.opensuse.reference="registry.opensuse.org/opensuse/openqa-webui:%PKG_VERSION%.%RELEASE%"
LABEL org.openbuildservice.disturl="%DISTURL%"
LABEL org.opencontainers.image.created="%BUILDTIME%"
# endlabelprefix

# hadolint ignore=DL3037
RUN zypper ar -p 95 -f http://download.opensuse.org/repositories/devel:openQA/15.6 devel_openQA && \
    zypper ar -p 90 -f http://download.opensuse.org/repositories/devel:openQA:Leap:15.6/15.6 devel_openQA_Leap && \
    zypper --gpg-auto-import-keys ref && \
    # openQA might need rubygem:sass to compile assets in this context due to
    # unknown reasons even though the package should use the precompiled
    # assets from cache.tar
    zypper in -y ca-certificates-mozilla curl openQA-local-db apache2 apache2-utils hostname which w3m 'rubygem(sass)>=3.7.4' && \
    zypper clean && \
    gensslcert && \
    a2enmod headers && \
    a2enmod proxy && \
    a2enmod proxy_http && \
    a2enmod proxy_wstunnel && \
    a2enmod ssl && \
    a2enmod rewrite && \
    a2enflag SSL

COPY openqa-ssl.conf openqa.conf /etc/apache2/vhosts.d/
COPY run_openqa.sh /root/

# set-up shared data and configuration
RUN rm -rf /etc/openqa/openqa.ini /etc/openqa/client.conf \
      /etc/openqa/database.ini \
      /var/lib/openqa/share/factory /var/lib/openqa/share/tests \
      /var/lib/openqa/testresults /var/lib/openqa/images && \
    chmod +x /root/run_openqa.sh && \
    mkdir -p /var/lib/openqa/pool && \
    ln -s /data/conf/openqa.ini /etc/openqa/openqa.ini && \
    ln -s /data/conf/database.ini /etc/openqa/database.ini && \
    ln -s /data/conf/client.conf /etc/openqa/client.conf && \
    ln -s /data/factory /var/lib/openqa/share/factory && \
    ln -s /data/tests /var/lib/openqa/share/tests && \
    ln -s /data/testresults /var/lib/openqa/testresults && \
    ln -s /data/images /var/lib/openqa/images && \
    chown -R geekotest /usr/share/openqa /var/lib/openqa /var/log/openqa && \
    chmod ug+rw /usr/share/openqa /var/lib/openqa /var/log/openqa && \
    find /usr/share/openqa /var/lib/openqa /var/log/openqa -type d -exec chmod ug+x {} \;

EXPOSE 80 443 9526 9527 9528 9529
CMD ["/root/run_openqa.sh"]
