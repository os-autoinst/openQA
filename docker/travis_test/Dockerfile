# Use an official SUSE runtime as a parent image
FROM opensuse:42.3

# Define environment variable
ENV NAME openQA test environment
ENV LANG en_US.UTF-8
RUN zypper in -y glibc-i18ndata glibc-locale

# Set the working directory to /opt/prepare
WORKDIR /opt/prepare
# Copy the current directory contents into the container /opt/prepare
ADD . /opt/prepare

RUN zypper install -y dbus-1 systemd-sysvinit
RUN cp /usr/lib/systemd/system/dbus.service /etc/systemd/system/; \
    sed -i 's/OOMScoreAdjust=-900//' /etc/systemd/system/dbus.service
VOLUME ["/sys/fs/cgroup", "/run"]

CMD ["/sbin/init"]

ENV OPENQA_DIR /opt/openqa
ENV NORMAL_USER squamata
RUN mkdir -p /home/$NORMAL_USER
RUN useradd -r -d /home/$NORMAL_USER -g users --uid=1000 $NORMAL_USER
RUN chown $NORMAL_USER:users /home/$NORMAL_USER 
VOLUME [ "/opt/openqa" ]


# explicitly set user/group IDs

RUN ["chmod","+x","./prepare.sh"]
RUN ["./prepare.sh"]

RUN mkdir -p /opt/testing_area
RUN chown -R $NORMAL_USER:users /opt/testing_area

COPY entrypoint.sh /usr/bin/entrypoint
RUN ["chmod","+x","/usr/bin/entrypoint"]
USER ${NORMAL_USER}
ENTRYPOINT ["entrypoint"]
WORKDIR $OPENQA_DIR
