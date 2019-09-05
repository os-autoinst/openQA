#!BuildTag: openqa_dev
FROM opensuse:42.3

# Define environment variable
ENV NAME openQA test environment
ENV LANG en_US.UTF-8

RUN zypper ar -f -G "http://download.opensuse.org/repositories/devel:/openQA/openSUSE_Leap_42.3" devel_openqa
RUN zypper in -y openQA-devel

VOLUME ["/sys/fs/cgroup", "/run"]

CMD ["/sbin/init"]

ENV OPENQA_DIR /opt/openqa
ENV NORMAL_USER squamata

RUN echo "$NORMAL_USER ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers
RUN mkdir -p /home/$NORMAL_USER
RUN useradd -r -d /home/$NORMAL_USER -g users --uid=1000 $NORMAL_USER
RUN chown $NORMAL_USER:users /home/$NORMAL_USER
VOLUME [ "/opt/openqa" ]

# explicitly set user/group IDs

RUN mkdir -p /opt/testing_area
RUN chown -R $NORMAL_USER:users /opt/testing_area

ENTRYPOINT ["/bin/bash"]
WORKDIR $OPENQA_DIR
