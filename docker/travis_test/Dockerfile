# Use an official SUSE runtime as a parent image
FROM opensuse:42.3

# Define environment variable
ENV NAME openQA test environment

# Set the working directory to /opt/prepare
WORKDIR /opt/prepare
# Copy the current directory contents into the container /opt/prepare
ADD . /opt/prepare

RUN zypper install -y dbus-1 systemd-sysvinit
RUN cp /usr/lib/systemd/system/dbus.service /etc/systemd/system/; \
    sed -i 's/OOMScoreAdjust=-900//' /etc/systemd/system/dbus.service
VOLUME ["/sys/fs/cgroup", "/run"]

CMD ["/sbin/init"]

ENV PGDATA /var/lib/pgsql/data
ENV OPENQA_DIR /opt/openqa

# explicitly set user/group IDs

RUN ["chmod","+x","./prepare.sh"]
RUN ["./prepare.sh"]
EXPOSE 5432
# VOLUME ["/var/run/postgresql"]


VOLUME ["/opt/openqa"]

COPY entrypoint.sh /usr/bin/entrypoint
RUN ["chmod","+x","/usr/bin/entrypoint"]
ENTRYPOINT ["entrypoint"]
WORKDIR $OPENQA_DIR
