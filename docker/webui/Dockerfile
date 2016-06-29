FROM opensuse:42.1
MAINTAINER Jan Sedlak <jsedlak@redhat.com>, Josef Skladanka <jskladan@redhat.com>, wnereiz(@github)

# Add 'hostname' as the dependence for apache2
# Add 'which' and 'w3m' to suppress the error message
RUN zypper ar -f obs://devel:openQA/openSUSE_Leap_42.1 openQA && \
    zypper ar -f obs://devel:openQA:Leap:42.1/openSUSE_Leap_42.1 openQA-perl-modules && \
    zypper --gpg-auto-import-keys ref && \
    zypper --non-interactive in ca-certificates-mozilla curl && \
    zypper --non-interactive in openQA apache2 hostname which w3m


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
ADD run_openqa.sh /root/

# set-up shared data and configuration
RUN rm -rf /etc/openqa/openqa.ini /etc/openqa/client.conf \
      /var/lib/openqa/share/factory /var/lib/openqa/share/tests \
      /var/lib/openqa/db/db.sqlite /var/lib/openqa/testresults && \
    chmod +x /root/run_openqa.sh && \
    mkdir -p /var/lib/openqa/pool && \
    mkdir -p /run/dbus && \
    ln -s /data/conf/openqa.ini /etc/openqa/openqa.ini && \
    ln -s /data/conf/client.conf /etc/openqa/client.conf && \
    ln -s /data/factory /var/lib/openqa/share/factory && \
    ln -s /data/tests /var/lib/openqa/share/tests && \
    ln -s /data/testresults /var/lib/openqa/testresults && \
    ln -s /data/db/db.sqlite /var/lib/openqa/db/db.sqlite && \
    chmod -R 777 /var/lib/openqa/pool

VOLUME ["/var/lib/openqa/pool"]

EXPOSE 80 443
CMD ["/root/run_openqa.sh"]
